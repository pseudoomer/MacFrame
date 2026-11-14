// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <string>

namespace macframe {

struct PreprocessParams {
    uint32_t dst_size[2];
    float    inv_src_size[2];
    uint32_t is_video_range;
};

struct PairAnalysisResultHost {
    uint32_t diff_sum_fixed;
    uint32_t max_block_diff;
    uint32_t grad_sum_fixed;
    uint32_t hist0[32];
    uint32_t hist1[32];
    uint32_t row_luma_sum[512];
    uint32_t row_grad_sum[512];
};

struct MESearchParams {
    uint32_t size[2];
    float    inv_size[2];
    float    grad_weight;
    float    smooth_lambda;
    int32_t  search_radius;
    int32_t  is_coarsest;
};

struct ConsistencyParams {
    uint32_t size[2];
    float    inv_size[2];
    int32_t  bidirectional;
    int32_t  static_lock;
    int32_t  letterbox_top_me;
    int32_t  letterbox_bottom_me;
    float    guard_strength;
};

struct ConfidenceStatsHost {
    uint32_t conf_sum_fixed;
    uint32_t fallback_pixels;
};

struct PhaseProjectParams {
    uint32_t size[2];
    float    inv_size[2];
    float    phase_t;
    float    flow_scale;
};

struct SynthParams {
    uint32_t y_size[2];
    uint32_t uv_size[2];
    float    phase_t;
    float    global_fallback_alpha;
    int32_t  is_anime_preset;
    int32_t  letterbox_top;
    int32_t  letterbox_bottom;
    int32_t  debug_osd;
    int32_t  current_tier;
};

class MetalContext {
public:
    static MetalContext &shared();

    bool is_valid() const { return valid_; }
    const std::string &init_error() const { return error_; }

    id<MTLDevice> device() const { return device_; }
    id<MTLCommandQueue> queue() const { return queue_; }

    id<MTLComputePipelineState> pso_clear_texture_rgba16f;
    id<MTLComputePipelineState> pso_extract_luma_y;
    id<MTLComputePipelineState> pso_extract_luma_bgra;
    id<MTLComputePipelineState> pso_pyramid_downsample;
    id<MTLComputePipelineState> pso_clear_pair_analysis;
    id<MTLComputePipelineState> pso_analyze_pair_coarse;
    id<MTLComputePipelineState> pso_update_static_mask;
    id<MTLComputePipelineState> pso_me_hierarchical_search;
    id<MTLComputePipelineState> pso_flow_bilateral_smooth;
    id<MTLComputePipelineState> pso_flow_refine_dis;
    id<MTLComputePipelineState> pso_compute_consistency;
    id<MTLComputePipelineState> pso_project_phase_flow;
    id<MTLComputePipelineState> pso_synth_biplanar_yuv;
    id<MTLComputePipelineState> pso_synth_bgra;
    id<MTLComputePipelineState> pso_blend_biplanar_yuv;
    id<MTLComputePipelineState> pso_yuv_to_rgba16f;
    id<MTLComputePipelineState> pso_rgba16f_to_yuv_guarded;

    void dispatch2D(id<MTLComputeCommandEncoder> enc,
                    id<MTLComputePipelineState> pso,
                    uint32_t width,
                    uint32_t height) const;

    id<MTLTexture> newTexture2D(MTLPixelFormat fmt,
                                uint32_t width,
                                uint32_t height,
                                MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                                MTLStorageMode storage = MTLStorageModePrivate) const;

private:
    MetalContext();
    bool valid_ = false;
    std::string error_;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLLibrary> library_ = nil;
};

} // namespace macframe
