// SPDX-License-Identifier: GPL-3.0-or-later
#include "macframe/macframe.h"
#include "macframe/mf_ipc.h"
#include "mf_governor.hpp"
#include "mf_metal_context.hpp"
#include "mf_timeline.hpp"

#include <unistd.h>

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <unordered_map>
#include <vector>

using namespace macframe;

namespace {

static constexpr int kMaxPyrLevels = 6;
static constexpr int kPyrPoolSize  = 12;

struct MFColorSpec {
    float kr = 0.2126f;
    float kb = 0.0722f;
    float y_offset = 16.0f / 255.0f;
    float y_scale  = 255.0f / 219.0f;
    float c_offset = 128.0f / 255.0f;
    float c_scale  = 255.0f / 224.0f;
    float overlay_hi = 0.88f;
    float overlay_lo = 0.16f;
    int   is_hdr = 0; // 0=SDR, 1=PQ, 2=HLG
};

struct FramePlanes {
    CVMetalTextureRef cv_tex0 = nullptr;
    CVMetalTextureRef cv_tex1 = nullptr;
    id<MTLTexture> tex0 = nil;
    id<MTLTexture> tex1 = nil;
    bool is_biplanar = true;
    bool is_10bit = false;
    bool is_video_range = true;

    ~FramePlanes() {
        tex0 = nil;
        tex1 = nil;
        if (cv_tex0) CFRelease(cv_tex0);
        if (cv_tex1) CFRelease(cv_tex1);
    }
};

struct PyramidSlot {
    id<MTLTexture> pyr[kMaxPyrLevels];
};

struct CachedSourceFrame {
    uint64_t frame_id = 0;
    double pts = 0.0;
    CVPixelBufferRef buf = nullptr;
    int pool_slot = -1;
    std::vector<int> *free_list = nullptr;
    PyramidSlot *slot_ptr = nullptr;
    id<MTLTexture> fallback_pyr[kMaxPyrLevels];

    id<MTLTexture> pyr_level(int l) const {
        return slot_ptr ? slot_ptr->pyr[l] : fallback_pyr[l];
    }

    ~CachedSourceFrame() {
        for (int i = 0; i < kMaxPyrLevels; ++i) fallback_pyr[i] = nil;
        if (pool_slot >= 0 && free_list) {
            free_list->push_back(pool_slot);
        }
        if (buf) CVPixelBufferRelease(buf);
    }
};

static MFColorSpec detect_color_spec(CVPixelBufferRef buf, bool is_10bit, bool is_video_range) {
    MFColorSpec cs{};

    CFStringRef matrix = (CFStringRef)CVBufferCopyAttachment(buf, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (matrix) {
        if (CFStringCompare(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020, 0) == kCFCompareEqualTo) {
            cs.kr = 0.2627f;
            cs.kb = 0.0593f;
        } else if (CFStringCompare(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo ||
                   CFStringCompare(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, 0) == kCFCompareEqualTo) {
            cs.kr = 0.2990f;
            cs.kb = 0.1140f;
        }
        CFRelease(matrix);
    }

    CFStringRef transfer = (CFStringRef)CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nullptr);
    if (transfer) {
        if (CFStringCompare(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo) {
            cs.is_hdr = 1;
            cs.overlay_hi = 0.58f; // ~203 nits reference diffuse white in PQ
            cs.overlay_lo = 0.12f;
        } else if (CFStringCompare(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo) {
            cs.is_hdr = 2;
            cs.overlay_hi = 0.72f;
            cs.overlay_lo = 0.15f;
        }
        CFRelease(transfer);
    }

    if (!is_video_range) {
        cs.y_offset = 0.0f;
        cs.y_scale  = 1.0f;
        cs.c_offset = 0.5f;
        cs.c_scale  = 1.0f;
    } else if (is_10bit) {
        // Apple P010 ('x420'): 10-bit code values occupy the high 10 bits of uint16
        cs.y_offset = (64.0f * 64.0f) / 65535.0f;
        cs.y_scale  = 65535.0f / (876.0f * 64.0f);
        cs.c_offset = (512.0f * 64.0f) / 65535.0f;
        cs.c_scale  = 65535.0f / (896.0f * 64.0f);
    } else {
        cs.y_offset = 16.0f / 255.0f;
        cs.y_scale  = 255.0f / 219.0f;
        cs.c_offset = 128.0f / 255.0f;
        cs.c_scale  = 255.0f / 224.0f;
    }

    return cs;
}

static bool bind_pixel_buffer(CVMetalTextureCacheRef cache,
                              CVPixelBufferRef buf,
                              FramePlanes &out) {
    OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);

    if (fmt == kCVPixelFormatType_32BGRA) {
        out.is_biplanar = false;
        out.is_10bit = false;
        out.is_video_range = false;
        if (CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buf, nullptr,
                MTLPixelFormatBGRA8Unorm, w, h, 0, &out.cv_tex0) != kCVReturnSuccess) {
            return false;
        }
        out.tex0 = CVMetalTextureGetTexture(out.cv_tex0);
        return out.tex0 != nil;
    }

    out.is_biplanar = true;
    out.is_10bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                    fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
    out.is_video_range = (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
                          fmt != kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);

    MTLPixelFormat y_fmt  = out.is_10bit ? MTLPixelFormatR16Unorm  : MTLPixelFormatR8Unorm;
    MTLPixelFormat uv_fmt = out.is_10bit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm;

    size_t y_w  = CVPixelBufferGetWidthOfPlane(buf, 0);
    size_t y_h  = CVPixelBufferGetHeightOfPlane(buf, 0);
    size_t uv_w = CVPixelBufferGetWidthOfPlane(buf, 1);
    size_t uv_h = CVPixelBufferGetHeightOfPlane(buf, 1);

    if (CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buf, nullptr,
            y_fmt, y_w, y_h, 0, &out.cv_tex0) != kCVReturnSuccess) {
        return false;
    }
    if (CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buf, nullptr,
            uv_fmt, uv_w, uv_h, 1, &out.cv_tex1) != kCVReturnSuccess) {
        return false;
    }
    out.tex0 = CVMetalTextureGetTexture(out.cv_tex0);
    out.tex1 = CVMetalTextureGetTexture(out.cv_tex1);
    return (out.tex0 != nil && out.tex1 != nil);
}

static CVPixelBufferPoolRef create_pool(int width, int height, OSType pix_fmt) {
    NSDictionary *pb_attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(pix_fmt),
        (id)kCVPixelBufferWidthKey : @(width),
        (id)kCVPixelBufferHeightKey : @(height),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferPoolRef pool = nullptr;
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)pb_attrs, &pool);
    return pool;
}

static double command_buffer_gpu_ms(id<MTLCommandBuffer> cb,
                                    std::chrono::steady_clock::time_point wall_t0) {
    CFTimeInterval start = cb.GPUStartTime;
    CFTimeInterval end   = cb.GPUEndTime;
    if (end > start && start > 0.0) {
        return (end - start) * 1000.0;
    }
    auto wall_t1 = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(wall_t1 - wall_t0).count();
}

} // namespace

struct mf_engine {
    mf_config cfg;
    MetalContext &ctx;
    Timeline timeline;
    Governor governor;

    CVMetalTextureCacheRef tex_cache = nullptr;
    CVPixelBufferPoolRef out_pool = nullptr;
    CVPixelBufferPoolRef rgha_pool = nullptr;

    // Pre-allocated zero-allocation pyramid ring pool
    PyramidSlot pyr_pool[kPyrPoolSize];
    std::vector<int> pyr_free_slots;

    // Ping-pong flow & guard textures per level
    uint32_t pyr_w[kMaxPyrLevels]{};
    uint32_t pyr_h[kMaxPyrLevels]{};
    id<MTLTexture> f01_a[kMaxPyrLevels];
    id<MTLTexture> f01_b[kMaxPyrLevels];
    id<MTLTexture> f10_a[kMaxPyrLevels];
    id<MTLTexture> f10_b[kMaxPyrLevels];
    id<MTLTexture> prev_f01[kMaxPyrLevels];
    id<MTLTexture> prev_f10[kMaxPyrLevels];

    id<MTLTexture> f01_clean[3];
    id<MTLTexture> f10_clean[3];
    id<MTLTexture> vis_conf[3];
    id<MTLTexture> prev_guard[3];
    id<MTLTexture> ft_proj[3];
    id<MTLTexture> vc_smooth[3];

    id<MTLTexture> static_mask_a = nil;
    id<MTLTexture> static_mask_b = nil;
    bool static_ping = false;

    id<MTLBuffer> analysis_buf = nil;
    id<MTLBuffer> conf_stats_buf = nil;

    // Apple VTFrameProcessor state (macOS 26.0+) & span batch cache
    VTFrameProcessor *vt_processor = nil;
    bool vt_supported = false;
    uint64_t vt_cached_f0 = UINT64_MAX;
    uint64_t vt_cached_f1 = UINT64_MAX;
    uint64_t vt_last_f1_id = UINT64_MAX;
    std::unordered_map<int, CVPixelBufferRef> vt_cached_outs;

    // Live shared-memory IPC
    mf_ipc_state *ipc_state = nullptr;
    uint64_t last_ipc_seq = 0;

    // Cached active pair state
    uint64_t prepared_f0_id = UINT64_MAX;
    uint64_t prepared_f1_id = UINT64_MAX;
    int prepared_me_base = 0;

    uint64_t next_frame_id = 1;
    std::deque<std::shared_ptr<CachedSourceFrame>> frame_store;

    mf_stats stats{};
    int letterbox_top = 0;
    int letterbox_bottom = 0;
    float global_fallback_alpha = 0.0f;

    mf_engine(const mf_config &c)
        : cfg(c),
          ctx(MetalContext::shared()),
          timeline(c.out_fps, c.dedup != 0, c.scene_detect != 0, c.smoothness),
          governor(c.out_fps, c.quality, c.governor != 0) {
        letterbox_top = 0;
        letterbox_bottom = c.height;
    }

    ~mf_engine() {
        @autoreleasepool {
            clear_vt_cache();
            if (ipc_state) {
                mf_ipc_close(ipc_state);
                ipc_state = nullptr;
            }
            if (vt_processor) {
                [vt_processor endSession];
                vt_processor = nil;
            }
            frame_store.clear();
            if (out_pool) CVPixelBufferPoolRelease(out_pool);
            if (rgha_pool) CVPixelBufferPoolRelease(rgha_pool);
            if (tex_cache) CFRelease(tex_cache);
        }
    }

    void clear_vt_cache() {
        for (auto &kv : vt_cached_outs) {
            if (kv.second) CVPixelBufferRelease(kv.second);
        }
        vt_cached_outs.clear();
        vt_cached_f0 = UINT64_MAX;
        vt_cached_f1 = UINT64_MAX;
    }

    bool init(char *err, size_t errlen) {
        if (!ctx.is_valid()) {
            if (err && errlen) snprintf(err, errlen, "%s", ctx.init_error().c_str());
            return false;
        }
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, ctx.device(), nullptr, &tex_cache) != kCVReturnSuccess) {
            if (err && errlen) snprintf(err, errlen, "CVMetalTextureCacheCreate failed");
            return false;
        }

        OSType fmt = cfg.cv_pixel_format ? cfg.cv_pixel_format : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        out_pool = create_pool(cfg.width, cfg.height, fmt);
        if (!out_pool) {
            if (err && errlen) snprintf(err, errlen, "Failed to create output CVPixelBufferPool");
            return false;
        }

        for (int l = 0; l < kMaxPyrLevels; ++l) {
            pyr_w[l] = std::max(16, cfg.width >> l);
            pyr_h[l] = std::max(16, cfg.height >> l);
            MTLStorageMode sm = (l <= 1) ? MTLStorageModeShared : MTLStorageModePrivate;
            f01_a[l]    = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l], MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, sm);
            f01_b[l]    = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l], MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, sm);
            f10_a[l]    = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l], MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, sm);
            f10_b[l]    = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l], MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, sm);
            prev_f01[l] = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l]);
            prev_f10[l] = ctx.newTexture2D(MTLPixelFormatRGBA16Float, pyr_w[l], pyr_h[l]);
        }

        pyr_free_slots.reserve(kPyrPoolSize);
        for (int s = kPyrPoolSize - 1; s >= 0; --s) {
            for (int l = 0; l < kMaxPyrLevels; ++l) {
                pyr_pool[s].pyr[l] = ctx.newTexture2D(MTLPixelFormatR16Float, pyr_w[l], pyr_h[l]);
            }
            pyr_free_slots.push_back(s);
        }

        for (int base = 0; base < 3; ++base) {
            uint32_t w = pyr_w[base];
            uint32_t h = pyr_h[base];
            f01_clean[base]  = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, MTLStorageModeShared);
            f10_clean[base]  = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, MTLStorageModeShared);
            vis_conf[base]   = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h);
            prev_guard[base] = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h);
            ft_proj[base]    = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h);
            vc_smooth[base]  = ctx.newTexture2D(MTLPixelFormatRGBA16Float, w, h);
        }

        static_mask_a = ctx.newTexture2D(MTLPixelFormatR16Float, pyr_w[1], pyr_h[1]);
        static_mask_b = ctx.newTexture2D(MTLPixelFormatR16Float, pyr_w[1], pyr_h[1]);

        analysis_buf = [ctx.device() newBufferWithLength:sizeof(PairAnalysisResultHost)
                                                 options:MTLResourceStorageModeShared];
        conf_stats_buf = [ctx.device() newBufferWithLength:sizeof(ConfidenceStatsHost)
                                                   options:MTLResourceStorageModeShared];

        clear_state_textures();

        if ([VTFrameRateConversionConfiguration isSupported]) {
            VTFrameRateConversionConfiguration *vt_cfg =
                [[VTFrameRateConversionConfiguration alloc]
                    initWithFrameWidth:cfg.width
                           frameHeight:cfg.height
                    usePrecomputedFlow:NO
                 qualityPrioritization:VTFrameRateConversionConfigurationQualityPrioritizationNormal
                              revision:VTFrameRateConversionConfigurationRevision1];
            if (vt_cfg) {
                VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
                NSError *vt_err = nil;
                if ([proc startSessionWithConfiguration:vt_cfg error:&vt_err]) {
                    vt_processor = proc;
                    vt_supported = true;
                    rgha_pool = create_pool(cfg.width, cfg.height, kCVPixelFormatType_64RGBAHalf);
                }
            }
        }

        if (cfg.backend == MF_BACKEND_AUTO) {
            stats.active_backend = MF_BACKEND_MFLOW;
        } else if (cfg.backend == MF_BACKEND_VT_FRC && !vt_supported) {
            stats.active_backend = MF_BACKEND_MFLOW;
        } else {
            stats.active_backend = cfg.backend;
        }
        stats.current_tier = governor.current_tier();
        return true;
    }

    void clear_state_textures() {
        id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        for (int l = 0; l < kMaxPyrLevels; ++l) {
            [enc setTexture:f01_a[l] atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[l], pyr_h[l]);
            [enc setTexture:f10_a[l] atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[l], pyr_h[l]);
            [enc setTexture:prev_f01[l] atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[l], pyr_h[l]);
            [enc setTexture:prev_f10[l] atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[l], pyr_h[l]);
        }
        for (int b = 0; b < 3; ++b) {
            [enc setTexture:prev_guard[b] atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[b], pyr_h[b]);
        }
        [enc setTexture:static_mask_a atIndex:0];
        ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[1], pyr_h[1]);
        [enc setTexture:static_mask_b atIndex:0];
        ctx.dispatch2D(enc, ctx.pso_clear_texture_rgba16f, pyr_w[1], pyr_h[1]);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        prepared_f0_id = UINT64_MAX;
        prepared_f1_id = UINT64_MAX;
        vt_last_f1_id = UINT64_MAX;
        clear_vt_cache();
    }

    // Fused pyramid extraction + optional coarse pair analysis & static mask update in a single CommandBuffer
    std::shared_ptr<CachedSourceFrame> push_and_analyze_frame(CVPixelBufferRef src,
                                                              double pts,
                                                              const CachedSourceFrame *prev_frame,
                                                              bool &is_duplicate,
                                                              bool &is_scene_cut) {
        auto frame = std::make_shared<CachedSourceFrame>();
        frame->frame_id = next_frame_id++;
        frame->pts = pts;
        frame->buf = CVPixelBufferRetain(src);

        if (!pyr_free_slots.empty()) {
            int idx = pyr_free_slots.back();
            pyr_free_slots.pop_back();
            frame->pool_slot = idx;
            frame->free_list = &pyr_free_slots;
            frame->slot_ptr  = &pyr_pool[idx];
        } else {
            for (int l = 0; l < kMaxPyrLevels; ++l) {
                frame->fallback_pyr[l] = ctx.newTexture2D(MTLPixelFormatR16Float, pyr_w[l], pyr_h[l]);
            }
        }

        FramePlanes planes;
        if (!bind_pixel_buffer(tex_cache, src, planes)) {
            return nullptr;
        }

        MFColorSpec cs = detect_color_spec(src, planes.is_10bit, planes.is_video_range);
        stats.is_hdr = cs.is_hdr;

        id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

        PreprocessParams pp{};
        pp.dst_size[0] = pyr_w[0];
        pp.dst_size[1] = pyr_h[0];
        pp.inv_src_size[0] = 1.0f / float(cfg.width);
        pp.inv_src_size[1] = 1.0f / float(cfg.height);
        pp.is_video_range = planes.is_video_range ? 1u : 0u;

        [enc setTexture:planes.tex0 atIndex:0];
        [enc setTexture:frame->pyr_level(0) atIndex:1];
        [enc setBytes:&pp length:sizeof(pp) atIndex:0];
        ctx.dispatch2D(enc, planes.is_biplanar ? ctx.pso_extract_luma_y : ctx.pso_extract_luma_bgra,
                       pyr_w[0], pyr_h[0]);

        for (int l = 1; l < kMaxPyrLevels; ++l) {
            [enc setTexture:frame->pyr_level(l - 1) atIndex:0];
            [enc setTexture:frame->pyr_level(l) atIndex:1];
            ctx.dispatch2D(enc, ctx.pso_pyramid_downsample, pyr_w[l], pyr_h[l]);
        }

        if (prev_frame) {
            [enc setComputePipelineState:ctx.pso_clear_pair_analysis];
            [enc setBuffer:analysis_buf offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(512, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];

            uint32_t w = pyr_w[2];
            uint32_t h = pyr_h[2];
            [enc setComputePipelineState:ctx.pso_analyze_pair_coarse];
            [enc setTexture:prev_frame->pyr_level(2) atIndex:0];
            [enc setTexture:frame->pyr_level(2) atIndex:1];
            [enc setBuffer:analysis_buf offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];

            id<MTLTexture> s_prev = static_ping ? static_mask_b : static_mask_a;
            id<MTLTexture> s_next = static_ping ? static_mask_a : static_mask_b;
            static_ping = !static_ping;
            [enc setTexture:prev_frame->pyr_level(1) atIndex:0];
            [enc setTexture:frame->pyr_level(1) atIndex:1];
            [enc setTexture:s_prev atIndex:2];
            [enc setTexture:s_next atIndex:3];
            ctx.dispatch2D(enc, ctx.pso_update_static_mask, pyr_w[1], pyr_h[1]);
        }

        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (prev_frame) {
            decode_pair_analysis_results(is_duplicate, is_scene_cut);
        }
        return frame;
    }

    void decode_pair_analysis_results(bool &is_duplicate, bool &is_scene_cut) {
        uint32_t w = pyr_w[2];
        uint32_t h = pyr_h[2];
        const auto *res = static_cast<const PairAnalysisResultHost *>([analysis_buf contents]);
        float total_px = float(w * h);
        float mean_diff = (float(res->diff_sum_fixed) / 1024.0f) / std::max(total_px, 1.0f);
        float max_blk   = float(res->max_block_diff) / 1024.0f;

        float hist_diff = 0.0f;
        for (int i = 0; i < 32; ++i) {
            hist_diff += std::fabs(float(res->hist0[i]) - float(res->hist1[i]));
        }
        hist_diff /= std::max(total_px, 1.0f);

        is_duplicate = (mean_diff < 0.0028f && max_blk < 0.0115f);
        is_scene_cut = (mean_diff > 0.165f && hist_diff > 0.42f) ||
                       (mean_diff > 0.24f) ||
                       (hist_diff > 0.82f && mean_diff > 0.095f);

        if (cfg.letterbox_guard != 0 && h <= 512) {
            uint32_t top_rows = 0;
            uint32_t max_bar = h / 4;
            for (uint32_t r = 0; r < max_bar; ++r) {
                float row_luma = (float(res->row_luma_sum[r]) / 1024.0f) / float(w);
                float row_grad = (float(res->row_grad_sum[r]) / 1024.0f) / float(w);
                if (row_luma < 0.025f && row_grad < 0.004f) {
                    top_rows = r + 1;
                } else {
                    break;
                }
            }
            uint32_t bot_rows = 0;
            for (uint32_t r = 0; r < max_bar; ++r) {
                uint32_t ry = h - 1 - r;
                float row_luma = (float(res->row_luma_sum[ry]) / 1024.0f) / float(w);
                float row_grad = (float(res->row_grad_sum[ry]) / 1024.0f) / float(w);
                if (row_luma < 0.025f && row_grad < 0.004f) {
                    bot_rows = r + 1;
                } else {
                    break;
                }
            }
            letterbox_top = (top_rows >= 2) ? int(top_rows * 4) : 0;
            letterbox_bottom = (bot_rows >= 2) ? int(cfg.height - bot_rows * 4) : cfg.height;
            stats.letterbox_top = letterbox_top;
            stats.letterbox_bottom = cfg.height - letterbox_bottom;
        } else {
            letterbox_top = 0;
            letterbox_bottom = cfg.height;
        }
    }

    // Encode optical flow + consistency into an open CommandBuffer (zero intermediate CPU sync)
    void encode_prepare_pair_flow(id<MTLCommandBuffer> cb,
                                  const CachedSourceFrame &f0,
                                  const CachedSourceFrame &f1,
                                  const TierParams &tp,
                                  int me_base) {
        int top_level = std::min(tp.pyramid_levels - 1, kMaxPyrLevels - 1);
        while (top_level > me_base + 1 && ((cfg.height >> top_level) < 24 || (cfg.width >> top_level) < 32)) {
            top_level--;
        }
        float grad_w = (cfg.preset == MF_PRESET_ANIME) ? 0.55f : 0.35f;
        float smooth_lambda = (cfg.preset == MF_PRESET_ANIME) ? 0.012f : 0.008f;
        int base_radius = (cfg.preset == MF_PRESET_SPORTS) ? 8 : 4;

        auto *cstats = static_cast<ConfidenceStatsHost *>([conf_stats_buf contents]);
        cstats->conf_sum_fixed = 0;
        cstats->fallback_pixels = 0;

        id<MTLTexture> cur_static = static_ping ? static_mask_a : static_mask_b;
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

        for (int l = top_level; l >= me_base; --l) {
            MESearchParams mp{};
            mp.size[0] = pyr_w[l];
            mp.size[1] = pyr_h[l];
            mp.inv_size[0] = 1.0f / float(pyr_w[l]);
            mp.inv_size[1] = 1.0f / float(pyr_h[l]);
            mp.grad_weight = grad_w;
            mp.smooth_lambda = smooth_lambda;
            mp.search_radius = (l >= top_level - 1) ? base_radius : 2;
            mp.is_coarsest = (l == top_level) ? 1 : 0;
            mp.use_static_early_exit = (cfg.static_lock != 0 && l <= me_base + 1) ? 1 : 0;

            id<MTLTexture> parent_f01 = (l == top_level) ? f01_a[l] : f01_a[l + 1];
            id<MTLTexture> parent_f10 = (l == top_level) ? f10_a[l] : f10_a[l + 1];

            [enc setTexture:f0.pyr_level(l) atIndex:0];
            [enc setTexture:f1.pyr_level(l) atIndex:1];
            [enc setTexture:parent_f01 atIndex:2];
            [enc setTexture:prev_f01[l] atIndex:3];
            [enc setTexture:cur_static atIndex:4];
            [enc setTexture:f01_b[l] atIndex:5];
            [enc setBytes:&mp length:sizeof(mp) atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_me_hierarchical_search, pyr_w[l], pyr_h[l]);

            [enc setTexture:f0.pyr_level(l) atIndex:0];
            [enc setTexture:f01_b[l] atIndex:1];
            [enc setTexture:f01_a[l] atIndex:2];
            ctx.dispatch2D(enc, ctx.pso_flow_bilateral_smooth, pyr_w[l], pyr_h[l]);

            int dis_n = (l == me_base) ? tp.dis_iters : ((l == me_base + 1 && tp.tier >= 4) ? 1 : 0);
            for (int it = 0; it < dis_n; ++it) {
                [enc setTexture:f0.pyr_level(l) atIndex:0];
                [enc setTexture:f1.pyr_level(l) atIndex:1];
                [enc setTexture:f01_a[l] atIndex:2];
                [enc setTexture:f01_b[l] atIndex:3];
                ctx.dispatch2D(enc, ctx.pso_flow_refine_dis, pyr_w[l], pyr_h[l]);
                std::swap(f01_a[l], f01_b[l]);
            }

            if (tp.bidirectional) {
                [enc setTexture:f1.pyr_level(l) atIndex:0];
                [enc setTexture:f0.pyr_level(l) atIndex:1];
                [enc setTexture:parent_f10 atIndex:2];
                [enc setTexture:prev_f10[l] atIndex:3];
                [enc setTexture:cur_static atIndex:4];
                [enc setTexture:f10_b[l] atIndex:5];
                [enc setBytes:&mp length:sizeof(mp) atIndex:0];
                ctx.dispatch2D(enc, ctx.pso_me_hierarchical_search, pyr_w[l], pyr_h[l]);

                [enc setTexture:f1.pyr_level(l) atIndex:0];
                [enc setTexture:f10_b[l] atIndex:1];
                [enc setTexture:f10_a[l] atIndex:2];
                ctx.dispatch2D(enc, ctx.pso_flow_bilateral_smooth, pyr_w[l], pyr_h[l]);

                for (int it = 0; it < dis_n; ++it) {
                    [enc setTexture:f1.pyr_level(l) atIndex:0];
                    [enc setTexture:f0.pyr_level(l) atIndex:1];
                    [enc setTexture:f10_a[l] atIndex:2];
                    [enc setTexture:f10_b[l] atIndex:3];
                    ctx.dispatch2D(enc, ctx.pso_flow_refine_dis, pyr_w[l], pyr_h[l]);
                    std::swap(f10_a[l], f10_b[l]);
                }
            }
        }

        ConsistencyParams cp{};
        cp.size[0] = pyr_w[me_base];
        cp.size[1] = pyr_h[me_base];
        cp.inv_size[0] = 1.0f / float(pyr_w[me_base]);
        cp.inv_size[1] = 1.0f / float(pyr_h[me_base]);
        cp.bidirectional = tp.bidirectional ? 1 : 0;
        cp.static_lock = cfg.static_lock;
        cp.letterbox_top_me = letterbox_top >> me_base;
        cp.letterbox_bottom_me = letterbox_bottom >> me_base;
        cp.guard_strength = cfg.artifact_guard;

        [enc setTexture:f0.pyr_level(me_base) atIndex:0];
        [enc setTexture:f1.pyr_level(me_base) atIndex:1];
        [enc setTexture:f01_a[me_base] atIndex:2];
        [enc setTexture:f10_a[me_base] atIndex:3];
        [enc setTexture:cur_static atIndex:4];
        [enc setTexture:prev_guard[me_base] atIndex:5];
        [enc setTexture:f01_clean[me_base] atIndex:6];
        [enc setTexture:f10_clean[me_base] atIndex:7];
        [enc setTexture:vis_conf[me_base] atIndex:8];
        [enc setBuffer:conf_stats_buf offset:0 atIndex:0];
        [enc setBytes:&cp length:sizeof(cp) atIndex:1];
        ctx.dispatch2D(enc, ctx.pso_compute_consistency, pyr_w[me_base], pyr_h[me_base]);

        [enc endEncoding];

        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        for (int l = me_base; l <= top_level; ++l) {
            [blit copyFromTexture:f01_a[l] toTexture:prev_f01[l]];
            if (tp.bidirectional) {
                [blit copyFromTexture:f10_a[l] toTexture:prev_f10[l]];
            }
        }
        [blit copyFromTexture:vis_conf[me_base] toTexture:prev_guard[me_base]];
        [blit endEncoding];
    }

    void finalize_pair_flow_stats(uint64_t f0_id, uint64_t f1_id, int me_base) {
        const auto *cstats = static_cast<const ConfidenceStatsHost *>([conf_stats_buf contents]);
        float total_me_px = float(pyr_w[me_base] * pyr_h[me_base]);
        float mean_conf = (float(cstats->conf_sum_fixed) / 1024.0f) / std::max(total_me_px, 1.0f);
        float fb_ratio  = float(cstats->fallback_pixels) / std::max(total_me_px, 1.0f);

        stats.mean_confidence = std::clamp(mean_conf, 0.0f, 1.0f);
        stats.fallback_ratio  = std::clamp(fb_ratio, 0.0f, 1.0f);

        float target_global = 0.0f;
        if (mean_conf < 0.48f) {
            target_global = std::clamp((0.48f - mean_conf) * 2.5f * cfg.artifact_guard, 0.0f, 0.85f);
        }
        global_fallback_alpha = 0.65f * global_fallback_alpha + 0.35f * target_global;
        stats.global_blend_alpha = global_fallback_alpha;

        prepared_f0_id = f0_id;
        prepared_f1_id = f1_id;
        prepared_me_base = me_base;
    }

    SynthParams make_synth_params(float phase_t, int tier, const MFColorSpec &cs) const {
        SynthParams sp{};
        sp.y_size[0] = uint32_t(cfg.width);
        sp.y_size[1] = uint32_t(cfg.height);
        sp.uv_size[0] = uint32_t((cfg.width + 1) / 2);
        sp.uv_size[1] = uint32_t((cfg.height + 1) / 2);
        sp.phase_t = phase_t;
        sp.global_fallback_alpha = global_fallback_alpha;
        sp.is_anime_preset = (cfg.preset == MF_PRESET_ANIME) ? 1 : 0;
        sp.letterbox_top = letterbox_top;
        sp.letterbox_bottom = letterbox_bottom;
        sp.debug_osd = cfg.debug_osd;
        sp.current_tier = tier;
        sp.ab_mode = cfg.ab_mode;
        sp.ab_split = std::clamp(cfg.ab_split, 0.1f, 0.9f);
        sp.overlay_hi = cs.overlay_hi;
        sp.overlay_lo = cs.overlay_lo;
        sp.kr = cs.kr;
        sp.kb = cs.kb;
        sp.y_offset = cs.y_offset;
        sp.y_scale = cs.y_scale;
        sp.c_offset = cs.c_offset;
        sp.c_scale = cs.c_scale;
        return sp;
    }

    CVPixelBufferRef synthesize_passthrough_with_overlay(const CachedSourceFrame &f0,
                                                         const CachedSourceFrame &f1,
                                                         bool use_f1) {
        CVPixelBufferRef out_buf = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, out_pool, &out_buf) != kCVReturnSuccess || !out_buf) {
            return nullptr;
        }
        CVBufferPropagateAttachments(use_f1 ? f1.buf : f0.buf, out_buf);

        FramePlanes p0, p1, pout;
        if (!bind_pixel_buffer(tex_cache, f0.buf, p0) ||
            !bind_pixel_buffer(tex_cache, f1.buf, p1) ||
            !bind_pixel_buffer(tex_cache, out_buf, pout)) {
            CVPixelBufferRelease(out_buf);
            return nullptr;
        }
        MFColorSpec cs = detect_color_spec(f0.buf, p0.is_10bit, p0.is_video_range);
        stats.is_hdr = cs.is_hdr;
        SynthParams sp = make_synth_params(use_f1 ? 1.0f : 0.0f, stats.current_tier, cs);

        if (pout.is_biplanar) {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setTexture:p0.tex0 atIndex:0];
            [enc setTexture:p0.tex1 atIndex:1];
            [enc setTexture:p1.tex0 atIndex:2];
            [enc setTexture:p1.tex1 atIndex:3];
            [enc setTexture:pout.tex0 atIndex:4];
            [enc setTexture:pout.tex1 atIndex:5];
            [enc setBytes:&sp length:sizeof(sp) atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_blend_biplanar_yuv, sp.uv_size[0], sp.uv_size[1]);
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
        return out_buf;
    }

    CVPixelBufferRef synthesize_phase(const CachedSourceFrame &f0,
                                      const CachedSourceFrame &f1,
                                      float phase_t) {
        auto t0 = std::chrono::steady_clock::now();

        if (stats.active_backend == MF_BACKEND_VT_FRC && vt_supported &&
            vt_cached_f0 == f0.frame_id && vt_cached_f1 == f1.frame_id) {
            int pkey = int(std::round(phase_t * 10000.0f));
            auto it = vt_cached_outs.find(pkey);
            if (it != vt_cached_outs.end() && it->second) {
                return CVPixelBufferRetain(it->second);
            }
        }

        CVPixelBufferRef out_buf = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, out_pool, &out_buf) != kCVReturnSuccess || !out_buf) {
            return nullptr;
        }
        CVBufferPropagateAttachments(f0.buf, out_buf);

        FramePlanes p0, p1, pout;
        if (!bind_pixel_buffer(tex_cache, f0.buf, p0) ||
            !bind_pixel_buffer(tex_cache, f1.buf, p1) ||
            !bind_pixel_buffer(tex_cache, out_buf, pout)) {
            CVPixelBufferRelease(out_buf);
            return nullptr;
        }

        MFColorSpec cs = detect_color_spec(f0.buf, p0.is_10bit, p0.is_video_range);
        stats.is_hdr = cs.is_hdr;

        TierParams tp = governor.tier_params();
        stats.current_tier = tp.tier;
        SynthParams sp = make_synth_params(phase_t, tp.tier, cs);

        // Fast linear blend path if requested or governor stepped down to Q0
        if (stats.active_backend == MF_BACKEND_BLEND || tp.tier == 0) {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            if (pout.is_biplanar) {
                [enc setTexture:p0.tex0 atIndex:0];
                [enc setTexture:p0.tex1 atIndex:1];
                [enc setTexture:p1.tex0 atIndex:2];
                [enc setTexture:p1.tex1 atIndex:3];
                [enc setTexture:pout.tex0 atIndex:4];
                [enc setTexture:pout.tex1 atIndex:5];
                [enc setBytes:&sp length:sizeof(sp) atIndex:0];
                ctx.dispatch2D(enc, ctx.pso_blend_biplanar_yuv, sp.uv_size[0], sp.uv_size[1]);
            }
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            double ms = command_buffer_gpu_ms(cb, t0);
            governor.record_gpu_time_ms(ms);
            stats.gpu_time_ms_avg = governor.avg_ms();
            stats.gpu_time_ms_p99 = governor.p99_ms();
            return out_buf;
        }

        // Apple VTFrameRateConversion Batch Multi-Phase Path + MacFrame Artifact Guard
        if (stats.active_backend == MF_BACKEND_VT_FRC && vt_supported && pout.is_biplanar) {
            clear_vt_cache();
            std::vector<float> phases = { phase_t };
            auto queued = timeline.peek_phases_for_pair(f0.frame_id, f1.frame_id);
            for (float qp : queued) {
                bool dup_p = false;
                for (float ep : phases) {
                    if (std::fabs(ep - qp) < 1e-4f) { dup_p = true; break; }
                }
                if (!dup_p) phases.push_back(qp);
            }

            TierParams guard_tp = Governor::params_for_tier((tp.tier >= 3) ? 2 : 1);
            int guard_me_base = (guard_tp.me_divisor >= 4) ? 2 : ((guard_tp.me_divisor >= 2) ? 1 : 0);
            bool need_flow = (prepared_f0_id != f0.frame_id || prepared_f1_id != f1.frame_id || prepared_me_base != guard_me_base);

            CVPixelBufferRef rgha0 = nullptr, rgha1 = nullptr;
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rgha_pool, &rgha0);
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rgha_pool, &rgha1);
            CVBufferPropagateAttachments(f0.buf, rgha0);
            CVBufferPropagateAttachments(f1.buf, rgha1);

            CVMetalTextureRef cv_r0 = nullptr, cv_r1 = nullptr;
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, tex_cache, rgha0, nullptr, MTLPixelFormatRGBA16Float, cfg.width, cfg.height, 0, &cv_r0);
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, tex_cache, rgha1, nullptr, MTLPixelFormatRGBA16Float, cfg.width, cfg.height, 0, &cv_r1);

            ColorMatrixParams cm{};
            cm.kr = cs.kr;
            cm.kb = cs.kb;
            cm.y_offset = cs.y_offset;
            cm.y_scale  = cs.y_scale;
            cm.c_offset = cs.c_offset;
            cm.c_scale  = cs.c_scale;
            cm.overlay_hi = cs.overlay_hi;
            cm.overlay_lo = cs.overlay_lo;

            id<MTLCommandBuffer> cb_in = [ctx.queue() commandBuffer];
            if (need_flow) {
                encode_prepare_pair_flow(cb_in, f0, f1, guard_tp, guard_me_base);
            }
            {
                id<MTLComputeCommandEncoder> enc_in = [cb_in computeCommandEncoder];
                [enc_in setTexture:p0.tex0 atIndex:0];
                [enc_in setTexture:p0.tex1 atIndex:1];
                [enc_in setTexture:CVMetalTextureGetTexture(cv_r0) atIndex:2];
                [enc_in setBytes:&cm length:sizeof(cm) atIndex:0];
                ctx.dispatch2D(enc_in, ctx.pso_yuv_to_rgba16f, cfg.width, cfg.height);

                [enc_in setTexture:p1.tex0 atIndex:0];
                [enc_in setTexture:p1.tex1 atIndex:1];
                [enc_in setTexture:CVMetalTextureGetTexture(cv_r1) atIndex:2];
                [enc_in setBytes:&cm length:sizeof(cm) atIndex:0];
                ctx.dispatch2D(enc_in, ctx.pso_yuv_to_rgba16f, cfg.width, cfg.height);
                [enc_in endEncoding];
            }
            [cb_in commit];
            [cb_in waitUntilCompleted];
            if (need_flow) {
                finalize_pair_flow_stats(f0.frame_id, f1.frame_id, guard_me_base);
            }

            size_t N = phases.size();
            std::vector<CVPixelBufferRef> rgha_outs(N, nullptr);
            std::vector<CVMetalTextureRef> cv_ros(N, nullptr);
            NSMutableArray<NSNumber *> *ns_phases = [NSMutableArray arrayWithCapacity:N];
            NSMutableArray<VTFrameProcessorFrame *> *dst_frames = [NSMutableArray arrayWithCapacity:N];

            for (size_t i = 0; i < N; ++i) {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rgha_pool, &rgha_outs[i]);
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, tex_cache, rgha_outs[i], nullptr, MTLPixelFormatRGBA16Float, cfg.width, cfg.height, 0, &cv_ros[i]);
                [ns_phases addObject:@(phases[i])];
                CMTime dt = CMTimeMake(int64_t(f0.frame_id * 1000 + std::llround(phases[i] * 1000.0)), 60000);
                [dst_frames addObject:[[VTFrameProcessorFrame alloc] initWithBuffer:rgha_outs[i] presentationTimeStamp:dt]];
            }

            VTFrameProcessorFrame *vf0 = [[VTFrameProcessorFrame alloc] initWithBuffer:rgha0 presentationTimeStamp:CMTimeMake(int64_t(f0.frame_id * 1000), 60000)];
            VTFrameProcessorFrame *vf1 = [[VTFrameProcessorFrame alloc] initWithBuffer:rgha1 presentationTimeStamp:CMTimeMake(int64_t((f0.frame_id + 1) * 1000), 60000)];
            auto sub_mode = (vt_last_f1_id == f0.frame_id)
                ? VTFrameRateConversionParametersSubmissionModeSequential
                : VTFrameRateConversionParametersSubmissionModeRandom;
            VTFrameRateConversionParameters *params =
                [[VTFrameRateConversionParameters alloc]
                    initWithSourceFrame:vf0
                              nextFrame:vf1
                            opticalFlow:nil
                     interpolationPhase:ns_phases
                         submissionMode:sub_mode
                      destinationFrames:dst_frames];
            NSError *vt_err = nil;
            bool frc_ok = (params && [vt_processor processWithParameters:params error:&vt_err]);
            if (frc_ok) {
                vt_last_f1_id = f1.frame_id;
                std::vector<CVPixelBufferRef> dst_pbs(N, nullptr);
                dst_pbs[0] = out_buf;
                for (size_t i = 1; i < N; ++i) {
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, out_pool, &dst_pbs[i]);
                    if (dst_pbs[i]) CVBufferPropagateAttachments(f0.buf, dst_pbs[i]);
                }

                id<MTLCommandBuffer> cb_out = [ctx.queue() commandBuffer];
                id<MTLComputeCommandEncoder> enc_out = [cb_out computeCommandEncoder];
                for (size_t i = 0; i < N; ++i) {
                    if (!dst_pbs[i] || !cv_ros[i]) continue;
                    FramePlanes dp;
                    if (!bind_pixel_buffer(tex_cache, dst_pbs[i], dp)) continue;
                    SynthParams sp_i = make_synth_params(phases[i], tp.tier, cs);
                    [enc_out setTexture:CVMetalTextureGetTexture(cv_ros[i]) atIndex:0];
                    [enc_out setTexture:p0.tex0 atIndex:1];
                    [enc_out setTexture:p0.tex1 atIndex:2];
                    [enc_out setTexture:p1.tex0 atIndex:3];
                    [enc_out setTexture:p1.tex1 atIndex:4];
                    [enc_out setTexture:vis_conf[guard_me_base] atIndex:5];
                    [enc_out setTexture:dp.tex0 atIndex:6];
                    [enc_out setTexture:dp.tex1 atIndex:7];
                    [enc_out setBytes:&sp_i length:sizeof(sp_i) atIndex:0];
                    ctx.dispatch2D(enc_out, ctx.pso_rgba16f_to_yuv_guarded, sp_i.uv_size[0], sp_i.uv_size[1]);
                }
                [enc_out endEncoding];
                [cb_out commit];
                [cb_out waitUntilCompleted];

                vt_cached_f0 = f0.frame_id;
                vt_cached_f1 = f1.frame_id;
                for (size_t i = 1; i < N; ++i) {
                    if (dst_pbs[i]) {
                        int pkey = int(std::round(phases[i] * 10000.0f));
                        vt_cached_outs[pkey] = dst_pbs[i];
                    }
                }
            }

            if (cv_r0) CFRelease(cv_r0);
            if (cv_r1) CFRelease(cv_r1);
            if (rgha0) CVPixelBufferRelease(rgha0);
            if (rgha1) CVPixelBufferRelease(rgha1);
            for (size_t i = 0; i < N; ++i) {
                if (cv_ros[i]) CFRelease(cv_ros[i]);
                if (rgha_outs[i]) CVPixelBufferRelease(rgha_outs[i]);
            }

            if (frc_ok) {
                auto t1 = std::chrono::steady_clock::now();
                double ms_total = std::chrono::duration<double, std::milli>(t1 - t0).count();
                governor.record_gpu_time_ms(ms_total / double(N + 1), true);
                stats.gpu_time_ms_avg = governor.avg_ms();
                stats.gpu_time_ms_p99 = governor.p99_ms();
                return out_buf;
            }
        }

        // Default MF-Flow path — single CommandBuffer fusion (flow if needed + phase proj + 2x2 quad synth)
        int me_base = (tp.me_divisor >= 4) ? 2 : ((tp.me_divisor >= 2) ? 1 : 0);
        bool need_flow = (prepared_f0_id != f0.frame_id || prepared_f1_id != f1.frame_id || prepared_me_base != me_base);

        id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
        if (need_flow) {
            encode_prepare_pair_flow(cb, f0, f1, tp, me_base);
        }

        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

        PhaseProjectParams ppp{};
        ppp.size[0] = pyr_w[me_base];
        ppp.size[1] = pyr_h[me_base];
        ppp.inv_size[0] = 1.0f / float(pyr_w[me_base]);
        ppp.inv_size[1] = 1.0f / float(pyr_h[me_base]);
        ppp.phase_t = phase_t;
        ppp.flow_scale = float(1 << me_base);

        [enc setTexture:f0.pyr_level(me_base) atIndex:0];
        [enc setTexture:f1.pyr_level(me_base) atIndex:1];
        [enc setTexture:f01_clean[me_base] atIndex:2];
        [enc setTexture:f10_clean[me_base] atIndex:3];
        [enc setTexture:vis_conf[me_base] atIndex:4];
        [enc setTexture:ft_proj[me_base] atIndex:5];
        [enc setTexture:vc_smooth[me_base] atIndex:6];
        [enc setBytes:&ppp length:sizeof(ppp) atIndex:0];
        ctx.dispatch2D(enc, ctx.pso_project_phase_flow, pyr_w[me_base], pyr_h[me_base]);

        if (pout.is_biplanar) {
            [enc setTexture:p0.tex0 atIndex:0];
            [enc setTexture:p0.tex1 atIndex:1];
            [enc setTexture:p1.tex0 atIndex:2];
            [enc setTexture:p1.tex1 atIndex:3];
            [enc setTexture:ft_proj[me_base] atIndex:4];
            [enc setTexture:vc_smooth[me_base] atIndex:5];
            [enc setTexture:pout.tex0 atIndex:6];
            [enc setTexture:pout.tex1 atIndex:7];
            [enc setBytes:&sp length:sizeof(sp) atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_synth_biplanar_yuv_quad, sp.uv_size[0], sp.uv_size[1]);
        } else {
            [enc setTexture:p0.tex0 atIndex:0];
            [enc setTexture:p1.tex0 atIndex:1];
            [enc setTexture:ft_proj[me_base] atIndex:2];
            [enc setTexture:vc_smooth[me_base] atIndex:3];
            [enc setTexture:pout.tex0 atIndex:4];
            [enc setBytes:&sp length:sizeof(sp) atIndex:0];
            ctx.dispatch2D(enc, ctx.pso_synth_bgra, cfg.width, cfg.height);
        }

        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (need_flow) {
            finalize_pair_flow_stats(f0.frame_id, f1.frame_id, me_base);
        }

        double gpu_ms = command_buffer_gpu_ms(cb, t0);
        governor.record_gpu_time_ms(gpu_ms);
        stats.gpu_time_ms_avg = governor.avg_ms();
        stats.gpu_time_ms_p99 = governor.p99_ms();
        return out_buf;
    }

    std::shared_ptr<CachedSourceFrame> find_frame(uint64_t fid) {
        for (auto &f : frame_store) {
            if (f->frame_id == fid) return f;
        }
        return nullptr;
    }

    void gc_old_frames(uint64_t min_keep_id) {
        while (frame_store.size() > 6 && frame_store.front()->frame_id < min_keep_id) {
            frame_store.pop_front();
        }
    }

    void sync_from_ipc() {
        if (!ipc_state || ipc_state->magic != MF_IPC_MAGIC) return;
        uint64_t seq = ipc_state->config_seq;
        if (seq == last_ipc_seq) return;
        last_ipc_seq = seq;

        cfg.preset          = static_cast<mf_preset>(ipc_state->preset);
        cfg.backend         = static_cast<mf_backend>(ipc_state->backend);
        cfg.quality         = std::clamp(ipc_state->quality, 0.0f, 1.0f);
        cfg.artifact_guard  = std::clamp(ipc_state->artifact_guard, 0.0f, 1.0f);
        cfg.smoothness      = std::clamp(ipc_state->smoothness, 0.0f, 1.0f);
        cfg.scene_detect    = ipc_state->scene_detect;
        cfg.dedup           = ipc_state->dedup;
        cfg.static_lock     = ipc_state->static_lock;
        cfg.letterbox_guard = ipc_state->letterbox_guard;
        cfg.governor        = ipc_state->governor;
        cfg.debug_osd       = ipc_state->debug_osd;
        cfg.ab_mode         = std::clamp(ipc_state->ab_mode, 0, 4);
        cfg.ab_split        = std::clamp(ipc_state->ab_split, 0.1f, 0.9f);

        if (cfg.backend == MF_BACKEND_VT_FRC && vt_supported) {
            stats.active_backend = MF_BACKEND_VT_FRC;
        } else if (cfg.backend == MF_BACKEND_BLEND) {
            stats.active_backend = MF_BACKEND_BLEND;
        } else {
            stats.active_backend = MF_BACKEND_MFLOW;
        }

        timeline.set_params(cfg.dedup != 0, cfg.scene_detect != 0, cfg.smoothness);
        governor.set_params(cfg.quality, cfg.governor != 0);
        stats.current_tier = governor.current_tier();
    }

    void publish_to_ipc() {
        if (!ipc_state || ipc_state->magic != MF_IPC_MAGIC) return;
        stats.scene_cuts   = timeline.scene_cuts();
        stats.dedup_drops  = timeline.dedup_drops();
        stats.current_tier = governor.current_tier();

        ipc_state->heartbeat_ms = mf_ipc_now_ms();
        ipc_state->active_pid   = getpid();
        ipc_state->video_width  = cfg.width;
        ipc_state->video_height = cfg.height;
        ipc_state->source_fps   = cfg.in_fps;
        ipc_state->output_fps   = cfg.out_fps;
        ipc_state->is_hdr       = stats.is_hdr;
        ipc_state->stats        = stats;
    }
};

extern "C" {

void mf_config_init_default(mf_config *cfg, mf_preset preset) {
    if (!cfg) return;
    std::memset(cfg, 0, sizeof(*cfg));
    cfg->abi_version = MF_ABI_VERSION;
    cfg->width = 1920;
    cfg->height = 1080;
    cfg->cv_pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    cfg->in_fps = 24.0;
    cfg->out_fps = 120.0;
    cfg->backend = MF_BACKEND_AUTO;
    cfg->preset = preset;
    cfg->quality = 1.0f;
    cfg->scene_detect = 1;
    cfg->static_lock = 1;
    cfg->letterbox_guard = 1;
    cfg->governor = 1;
    cfg->debug_osd = 0;
    cfg->ab_mode = MF_AB_OFF;
    cfg->ab_split = 0.5f;

    switch (preset) {
        case MF_PRESET_ANIME:
            cfg->artifact_guard = 0.80f;
            cfg->smoothness = 1.0f;
            cfg->dedup = 1;
            break;
        case MF_PRESET_SPORTS:
            cfg->artifact_guard = 0.65f;
            cfg->smoothness = 1.0f;
            cfg->dedup = 0;
            break;
        case MF_PRESET_FILM:
        default:
            cfg->artifact_guard = 0.60f;
            cfg->smoothness = 0.90f;
            cfg->dedup = 0;
            break;
    }
}

mf_engine *mf_engine_create(const mf_config *cfg, char *err, size_t errlen) {
    @autoreleasepool {
        if (!cfg || cfg->abi_version != MF_ABI_VERSION) {
            if (err && errlen) snprintf(err, errlen, "ABI version mismatch");
            return nullptr;
        }
        if (cfg->width <= 0 || cfg->height <= 0) {
            if (err && errlen) snprintf(err, errlen, "Invalid dimensions %dx%d", cfg->width, cfg->height);
            return nullptr;
        }
        auto *e = new mf_engine(*cfg);
        if (!e->init(err, errlen)) {
            delete e;
            return nullptr;
        }
        return e;
    }
}

int mf_engine_push(mf_engine *e, CVPixelBufferRef src, double pts) {
    @autoreleasepool {
        if (!e || !src) return MF_ERR;
        e->sync_from_ipc();
        bool is_dup = false;
        bool is_cut = false;
        const CachedSourceFrame *prev = e->frame_store.empty() ? nullptr : e->frame_store.back().get();
        auto frame = e->push_and_analyze_frame(src, pts, prev, is_dup, is_cut);
        if (!frame) return MF_ERR;

        e->frame_store.push_back(frame);
        e->stats.frames_in++;

        TimelineInputFrame tif{};
        tif.id = frame->frame_id;
        tif.pts = pts;
        tif.is_duplicate = is_dup;
        tif.is_scene_cut = is_cut;
        e->timeline.push(tif);
        e->stats.scene_cuts = e->timeline.scene_cuts();
        e->stats.dedup_drops = e->timeline.dedup_drops();
        return MF_OK;
    }
}

int mf_engine_pull(mf_engine *e, CVPixelBufferRef *out_buf, double *out_pts) {
    @autoreleasepool {
        if (!e || !out_buf || !out_pts) return MF_ERR;
        if (!e->timeline.has_ready_output()) {
            return MF_EAGAIN;
        }

        TimelineOutputTask task = e->timeline.pop_output();
        auto f0 = e->find_frame(task.f0_id);
        auto f1 = e->find_frame(task.f1_id);
        if (!f0) return MF_ERR;
        if (!f1) f1 = f0;

        *out_pts = task.out_pts;
        bool need_overlay = (e->cfg.ab_mode != 0 || e->cfg.debug_osd != 0);
        if (task.mode == OutputMode::PassthroughF0) {
            *out_buf = need_overlay ? e->synthesize_passthrough_with_overlay(*f0, *f1, false) : nullptr;
            if (!*out_buf) *out_buf = CVPixelBufferRetain(f0->buf);
        } else if (task.mode == OutputMode::PassthroughF1) {
            *out_buf = need_overlay ? e->synthesize_passthrough_with_overlay(*f0, *f1, true) : nullptr;
            if (!*out_buf) *out_buf = CVPixelBufferRetain(f1->buf);
        } else {
            *out_buf = e->synthesize_phase(*f0, *f1, task.shaped_phase);
            if (!*out_buf) {
                *out_buf = CVPixelBufferRetain(f0->buf);
            }
        }

        e->stats.frames_out++;
        e->gc_old_frames(task.f0_id);
        e->publish_to_ipc();
        return MF_OK;
    }
}

int mf_engine_flush(mf_engine *e) {
    if (!e) return MF_ERR;
    e->timeline.flush();
    return MF_OK;
}

void mf_engine_reset(mf_engine *e) {
    @autoreleasepool {
        if (!e) return;
        e->timeline.reset();
        e->governor.reset();
        e->frame_store.clear();
        e->clear_state_textures();
    }
}

void mf_engine_get_stats(mf_engine *e, mf_stats *st) {
    if (!e || !st) return;
    e->stats.scene_cuts = e->timeline.scene_cuts();
    e->stats.dedup_drops = e->timeline.dedup_drops();
    e->stats.current_tier = e->governor.current_tier();
    *st = e->stats;
}

void mf_engine_enable_ipc(mf_engine *e, int enable) {
    if (!e) return;
    if (enable && !e->ipc_state) {
        e->ipc_state = mf_ipc_open();
        e->last_ipc_seq = 0;
        e->sync_from_ipc();
        e->publish_to_ipc();
    } else if (!enable && e->ipc_state) {
        mf_ipc_close(e->ipc_state);
        e->ipc_state = nullptr;
    }
}

int mf_engine_interpolate_pair(mf_engine *e,
                               CVPixelBufferRef f0_buf,
                               CVPixelBufferRef f1_buf,
                               float phase,
                               CVPixelBufferRef *out_buf,
                               float *out_flow_xy) {
    @autoreleasepool {
        if (!e || !f0_buf || !f1_buf || !out_buf) return MF_ERR;
        bool is_dup = false, is_cut = false;
        auto f0 = e->push_and_analyze_frame(f0_buf, 0.0, nullptr, is_dup, is_cut);
        if (!f0) return MF_ERR;
        auto f1 = e->push_and_analyze_frame(f1_buf, 1.0, f0.get(), is_dup, is_cut);
        if (!f1) return MF_ERR;

        *out_buf = e->synthesize_phase(*f0, *f1, phase);
        if (!*out_buf) return MF_ERR;

        if (out_flow_xy) {
            int me_base = e->prepared_me_base;
            uint32_t mw = e->pyr_w[me_base];
            uint32_t mh = e->pyr_h[me_base];
            float scale = float(1 << me_base);

            std::vector<uint16_t> raw_half(mw * mh * 4);
            [e->f01_clean[me_base] getBytes:raw_half.data()
                                bytesPerRow:mw * 4 * sizeof(uint16_t)
                                 fromRegion:MTLRegionMake2D(0, 0, mw, mh)
                                mipmapLevel:0];

            for (int y = 0; y < e->cfg.height; ++y) {
                uint32_t sy = std::min(uint32_t(y >> me_base), mh - 1);
                for (int x = 0; x < e->cfg.width; ++x) {
                    uint32_t sx = std::min(uint32_t(x >> me_base), mw - 1);
                    const __fp16 *hp = reinterpret_cast<const __fp16 *>(&raw_half[(sy * mw + sx) * 4]);
                    size_t dst_idx = (size_t(y) * e->cfg.width + x) * 2;
                    out_flow_xy[dst_idx + 0] = float(hp[0]) * scale;
                    out_flow_xy[dst_idx + 1] = float(hp[1]) * scale;
                }
            }
        }
        return MF_OK;
    }
}

void mf_engine_destroy(mf_engine *e) {
    @autoreleasepool {
        delete e;
    }
}

} // extern "C"
