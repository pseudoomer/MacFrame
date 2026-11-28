/*
 * MacFrame — Apple Silicon Native Frame Interpolation Filter for FFmpeg / mpv / IINA
 * Copyright (c) 2026 pseudoomer
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <arm_neon.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/avstring.h"
#include "libavutil/buffer.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_videotoolbox.h"
#include "libavutil/mastering_display_metadata.h"
#include "libavutil/mathematics.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "avfilter.h"
#include "filters.h"
#include "video.h"

/* --- MacFrame Engine C ABI v2 (matched to engine/include/macframe/macframe.h & mf_ipc.h) --- */
#define MF_ABI_VERSION 2u
#define MF_OK          0
#define MF_EAGAIN      1
#define MF_EOF         2
#define MF_ERR        -1

typedef struct mf_engine mf_engine;

typedef enum mf_backend {
    MF_BACKEND_AUTO   = 0,
    MF_BACKEND_MFLOW  = 1,
    MF_BACKEND_VT_FRC = 2,
    MF_BACKEND_BLEND  = 3,
} mf_backend;

typedef enum mf_preset {
    MF_PRESET_FILM   = 0,
    MF_PRESET_ANIME  = 1,
    MF_PRESET_SPORTS = 2,
    MF_PRESET_CUSTOM = 3,
} mf_preset;

typedef struct mf_config {
    uint32_t   abi_version;
    int        width;
    int        height;
    uint32_t   cv_pixel_format;
    double     in_fps;
    double     out_fps;
    mf_backend backend;
    mf_preset  preset;
    float      quality;
    float      artifact_guard;
    float      smoothness;
    int        scene_detect;
    int        dedup;
    int        static_lock;
    int        letterbox_guard;
    int        governor;
    int        debug_osd;
    int        ab_mode;
    float      ab_split;
} mf_config;

typedef struct mf_stats {
    uint64_t   frames_in;
    uint64_t   frames_out;
    uint64_t   scene_cuts;
    uint64_t   dedup_drops;
    int        current_tier;
    mf_backend active_backend;
    double     gpu_time_ms_avg;
    double     gpu_time_ms_p99;
    float      mean_confidence;
    float      fallback_ratio;
    float      global_blend_alpha;
    int        letterbox_top;
    int        letterbox_bottom;
    int        is_hdr;
} mf_stats;

typedef void       (*mf_config_init_default_fn)(mf_config *, mf_preset);
typedef mf_engine *(*mf_engine_create_fn)(const mf_config *, char *, size_t);
typedef int        (*mf_engine_push_fn)(mf_engine *, CVPixelBufferRef, double);
typedef int        (*mf_engine_pull_fn)(mf_engine *, CVPixelBufferRef *, double *);
typedef int        (*mf_engine_flush_fn)(mf_engine *);
typedef void       (*mf_engine_reset_fn)(mf_engine *);
typedef void       (*mf_engine_get_stats_fn)(mf_engine *, mf_stats *);
typedef void       (*mf_engine_enable_ipc_fn)(mf_engine *, int);
typedef void       (*mf_engine_destroy_fn)(mf_engine *);

typedef struct mf_ipc_state {
    uint32_t magic;
    uint32_t version;
    uint64_t config_seq;
    int32_t  enabled;
    int32_t  fps_mode;
    double   max_fps_cap;
    int32_t  preset;
    int32_t  backend;
    float    quality;
    float    artifact_guard;
    float    smoothness;
    int32_t  scene_detect;
    int32_t  dedup;
    int32_t  static_lock;
    int32_t  letterbox_guard;
    int32_t  governor;
    int32_t  debug_osd;
    int32_t  ab_mode;
    float    ab_split;
} mf_ipc_state;

typedef mf_ipc_state *(*mf_ipc_open_fn)(void);
typedef void          (*mf_ipc_close_fn)(mf_ipc_state *);

#define TMPL_RING_SIZE 8

typedef struct TemplateEntry {
    AVFrame *frame;
    double   pts_sec;
    bool     valid;
} TemplateEntry;

typedef struct MacFrameContext {
    const AVClass *class;

    /* Filter options */
    double fps;
    char  *preset_str;
    char  *backend_str;
    float  quality;
    float  guard;
    float  smoothness;
    int    scene;
    int    dedup;
    int    static_lock;
    int    letterbox;
    int    governor;
    int    osd;
    int    ab_mode;
    float  ab_split;
    char  *lib_path;

    /* Dynamic library & function pointers */
    void                     *dl_handle;
    mf_config_init_default_fn fn_init_default;
    mf_engine_create_fn       fn_create;
    mf_engine_push_fn         fn_push;
    mf_engine_pull_fn         fn_pull;
    mf_engine_flush_fn        fn_flush;
    mf_engine_reset_fn        fn_reset;
    mf_engine_get_stats_fn    fn_get_stats;
    mf_engine_enable_ipc_fn   fn_enable_ipc;
    mf_engine_destroy_fn      fn_destroy;
    mf_ipc_open_fn            fn_ipc_open;
    mf_ipc_close_fn           fn_ipc_close;

    mf_engine    *engine;
    mf_ipc_state *ipc_state;
    bool       passthrough_fallback;
    bool       eof;
    int        eof_status;
    int64_t    eof_pts;
    int64_t    last_in_pts;
    uint64_t   in_count;
    double     in_fps;

    TemplateEntry tmpl_ring[TMPL_RING_SIZE];
    int           tmpl_head;
} MacFrameContext;

static void macframe_cvbuf_release(void *opaque, uint8_t *data)
{
    (void)opaque;
    if (data) {
        CVPixelBufferRelease((CVPixelBufferRef)data);
    }
}

static mf_preset parse_preset_opt(const char *s)
{
    if (!s) return MF_PRESET_FILM;
    if (!av_strcasecmp(s, "anime"))  return MF_PRESET_ANIME;
    if (!av_strcasecmp(s, "sports")) return MF_PRESET_SPORTS;
    if (!av_strcasecmp(s, "custom")) return MF_PRESET_CUSTOM;
    return MF_PRESET_FILM;
}

static mf_backend parse_backend_opt(const char *s)
{
    if (!s) return MF_BACKEND_MFLOW;
    if (!av_strcasecmp(s, "vtfrc") || !av_strcasecmp(s, "vt")) return MF_BACKEND_VT_FRC;
    if (!av_strcasecmp(s, "blend")) return MF_BACKEND_BLEND;
    if (!av_strcasecmp(s, "auto"))  return MF_BACKEND_AUTO;
    return MF_BACKEND_MFLOW;
}

static bool load_engine_dylib(AVFilterContext *avctx, MacFrameContext *s)
{
    char sibling_path[1024] = {0};
    Dl_info dli;
    const char *env_lib;
    const char *candidates[6];
    size_t i;

    if (dladdr((const void *)&load_engine_dylib, &dli) && dli.dli_fname) {
        const char *slash = strrchr(dli.dli_fname, '/');
        if (slash) {
            size_t dir_len = (size_t)(slash - dli.dli_fname);
            if (dir_len + sizeof("/libmacframe.dylib") < sizeof(sibling_path)) {
                memcpy(sibling_path, dli.dli_fname, dir_len);
                strcpy(sibling_path + dir_len, "/libmacframe.dylib");
            }
        }
    }

    env_lib = getenv("MACFRAME_LIB");
    candidates[0] = s->lib_path;
    candidates[1] = env_lib;
    candidates[2] = sibling_path[0] ? sibling_path : NULL;
    candidates[3] = "@loader_path/libmacframe.dylib";
    candidates[4] = "/usr/local/lib/libmacframe.dylib";
    candidates[5] = "/opt/homebrew/lib/libmacframe.dylib";

    for (i = 0; i < 6; ++i) {
        if (!candidates[i] || !candidates[i][0]) continue;
        s->dl_handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (s->dl_handle) {
            av_log(avctx, AV_LOG_INFO, "Loaded MacFrame engine from %s\n", candidates[i]);
            break;
        }
    }

    if (!s->dl_handle) {
        av_log(avctx, AV_LOG_WARNING,
               "Could not load libmacframe.dylib (%s); falling back to passthrough.\n",
               dlerror());
        return false;
    }

#define LOAD_SYM(field, name)                                                  \
    do {                                                                       \
        s->field = (name##_fn)dlsym(s->dl_handle, #name);                      \
        if (!s->field) {                                                       \
            av_log(avctx, AV_LOG_ERROR, "Missing symbol %s in libmacframe\n",  \
                   #name);                                                     \
            dlclose(s->dl_handle);                                             \
            s->dl_handle = NULL;                                               \
            return false;                                                      \
        }                                                                      \
    } while (0)

    LOAD_SYM(fn_init_default, mf_config_init_default);
    LOAD_SYM(fn_create,       mf_engine_create);
    LOAD_SYM(fn_push,         mf_engine_push);
    LOAD_SYM(fn_pull,         mf_engine_pull);
    LOAD_SYM(fn_flush,        mf_engine_flush);
    LOAD_SYM(fn_reset,        mf_engine_reset);
    LOAD_SYM(fn_get_stats,    mf_engine_get_stats);
    LOAD_SYM(fn_enable_ipc,   mf_engine_enable_ipc);
    LOAD_SYM(fn_destroy,      mf_engine_destroy);
    LOAD_SYM(fn_ipc_open,     mf_ipc_open);
    LOAD_SYM(fn_ipc_close,    mf_ipc_close);
#undef LOAD_SYM

    return true;
}

static av_cold int macframe_init(AVFilterContext *avctx)
{
    MacFrameContext *s = avctx->priv;
    int i;
    s->last_in_pts = AV_NOPTS_VALUE;
    for (i = 0; i < TMPL_RING_SIZE; ++i) {
        s->tmpl_ring[i].frame = av_frame_alloc();
        s->tmpl_ring[i].valid = false;
        if (!s->tmpl_ring[i].frame)
            return AVERROR(ENOMEM);
    }

    if (!load_engine_dylib(avctx, s)) {
        s->passthrough_fallback = true;
    } else if (s->fn_ipc_open) {
        s->ipc_state = s->fn_ipc_open();
    }
    return 0;
}

static av_cold void macframe_uninit(AVFilterContext *avctx)
{
    MacFrameContext *s = avctx->priv;
    int i;
    if (s->ipc_state && s->fn_ipc_close) {
        s->fn_ipc_close(s->ipc_state);
        s->ipc_state = NULL;
    }
    if (s->engine && s->fn_destroy) {
        mf_stats st;
        if (s->fn_get_stats) {
            s->fn_get_stats(s->engine, &st);
            av_log(avctx, AV_LOG_INFO,
                   "MacFrame summary: in=%llu out=%llu cuts=%llu dedup=%llu tier=Q%d avg_gpu=%.2fms\n",
                   (unsigned long long)st.frames_in,
                   (unsigned long long)st.frames_out,
                   (unsigned long long)st.scene_cuts,
                   (unsigned long long)st.dedup_drops,
                   st.current_tier,
                   st.gpu_time_ms_avg);
        }
        s->fn_destroy(s->engine);
        s->engine = NULL;
    }
    if (s->dl_handle) {
        dlclose(s->dl_handle);
        s->dl_handle = NULL;
    }
    for (i = 0; i < TMPL_RING_SIZE; ++i) {
        av_frame_free(&s->tmpl_ring[i].frame);
    }
}

static const AVFrame *find_template_for_pts(const MacFrameContext *s, double pts_sec)
{
    const AVFrame *best = NULL;
    double best_dt = 1e30;
    int i;
    for (i = 0; i < TMPL_RING_SIZE; ++i) {
        if (!s->tmpl_ring[i].valid) continue;
        double dt = fabs(s->tmpl_ring[i].pts_sec - pts_sec);
        if (dt < best_dt) {
            best_dt = dt;
            best = s->tmpl_ring[i].frame;
        }
    }
    return best;
}

static int macframe_config_output(AVFilterLink *outlink)
{
    AVFilterContext *avctx = outlink->src;
    MacFrameContext *s = avctx->priv;
    AVFilterLink *inlink = avctx->inputs[0];
    FilterLink *inl = ff_filter_link(inlink);
    FilterLink *outl = ff_filter_link(outlink);
    int err;
    double target_fps;
    uint32_t cv_pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    outlink->w = inlink->w;
    outlink->h = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    outlink->colorspace = inlink->colorspace;
    outlink->color_range = inlink->color_range;

    s->in_fps = (inl->frame_rate.num > 0 && inl->frame_rate.den > 0)
                    ? av_q2d(inl->frame_rate)
                    : 24.0;
    target_fps = (s->fps > 1.0) ? s->fps : 120.0;
    if (s->ipc_state && s->ipc_state->max_fps_cap >= 24.0) {
        double cap = s->ipc_state->max_fps_cap;
        if (s->ipc_state->fps_mode == 1) {
            target_fps = cap;
        } else if (s->ipc_state->fps_mode == 2) {
            target_fps = FFMIN(s->in_fps * 2.0, cap);
        } else {
            target_fps = FFMIN(target_fps, cap);
        }
    }

    outl->frame_rate   = av_d2q(target_fps, 100000);
    outlink->time_base = av_inv_q(outl->frame_rate);

    if (inlink->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        AVHWFramesContext *hw_in;
        AVHWFramesContext *hw_out;
        if (!inl->hw_frames_ctx) {
            av_log(avctx, AV_LOG_ERROR, "macframe requires hw_frames_ctx for videotoolbox input\n");
            return AVERROR(EINVAL);
        }
        hw_in = (AVHWFramesContext *)inl->hw_frames_ctx->data;
        av_buffer_unref(&outl->hw_frames_ctx);
        outl->hw_frames_ctx = av_hwframe_ctx_alloc(hw_in->device_ref);
        if (!outl->hw_frames_ctx)
            return AVERROR(ENOMEM);

        hw_out = (AVHWFramesContext *)outl->hw_frames_ctx->data;
        hw_out->format    = AV_PIX_FMT_VIDEOTOOLBOX;
        hw_out->sw_format = hw_in->sw_format;
        hw_out->width     = outlink->w;
        hw_out->height    = outlink->h;
        ((AVVTFramesContext *)hw_out->hwctx)->color_range =
            ((AVVTFramesContext *)hw_in->hwctx)->color_range;

        err = ff_filter_init_hw_frames(avctx, outlink, 1);
        if (err < 0)
            return err;

        err = av_hwframe_ctx_init(outl->hw_frames_ctx);
        if (err < 0) {
            av_log(avctx, AV_LOG_ERROR, "Failed to init videotoolbox out hw_frames_ctx\n");
            return err;
        }

        if (hw_in->sw_format == AV_PIX_FMT_P010LE || hw_in->sw_format == AV_PIX_FMT_P010BE) {
            cv_pixfmt = (inlink->color_range == AVCOL_RANGE_JPEG)
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        } else if (hw_in->sw_format == AV_PIX_FMT_BGRA) {
            cv_pixfmt = kCVPixelFormatType_32BGRA;
        } else if (inlink->color_range == AVCOL_RANGE_JPEG) {
            cv_pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        }
    } else if (inlink->format == AV_PIX_FMT_P010LE || inlink->format == AV_PIX_FMT_YUV420P10LE) {
        cv_pixfmt = (inlink->color_range == AVCOL_RANGE_JPEG)
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    } else if (inlink->color_range == AVCOL_RANGE_JPEG) {
        cv_pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }

    if (!s->passthrough_fallback && s->fn_create) {
        mf_preset preset;
        mf_config cfg;
        char errbuf[256] = {0};

        if (s->engine) {
            s->fn_destroy(s->engine);
            s->engine = NULL;
        }
        preset = parse_preset_opt(s->preset_str);
        s->fn_init_default(&cfg, preset);
        cfg.width           = outlink->w;
        cfg.height          = outlink->h;
        cfg.cv_pixel_format = cv_pixfmt;
        cfg.in_fps          = s->in_fps;
        cfg.out_fps         = target_fps;
        cfg.backend         = parse_backend_opt(s->backend_str);
        cfg.preset          = preset;
        cfg.quality         = s->quality;
        cfg.artifact_guard  = s->guard;
        cfg.smoothness      = s->smoothness;
        cfg.scene_detect    = s->scene;
        cfg.dedup           = s->dedup;
        cfg.static_lock     = s->static_lock;
        cfg.letterbox_guard = s->letterbox;
        cfg.governor        = s->governor;
        cfg.debug_osd       = s->osd;
        cfg.ab_mode         = s->ab_mode;
        cfg.ab_split        = s->ab_split;

        s->engine = s->fn_create(&cfg, errbuf, sizeof(errbuf));
        if (!s->engine) {
            av_log(avctx, AV_LOG_WARNING,
                   "mf_engine_create failed (%s); falling back to passthrough.\n",
                   errbuf);
            s->passthrough_fallback = true;
        } else {
            if (s->fn_enable_ipc) {
                s->fn_enable_ipc(s->engine, 1);
            }
            av_log(avctx, AV_LOG_INFO,
                   "MacFrame active: %dx%d %.2f->%.2ffps preset=%s backend=%s\n",
                   cfg.width, cfg.height, cfg.in_fps, cfg.out_fps,
                   s->preset_str ? s->preset_str : "film",
                   s->backend_str ? s->backend_str : "mflow");
        }
    }

    return 0;
}

static inline void write_be16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xff);
}

static inline void write_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)((v >> 16) & 0xff);
    p[2] = (uint8_t)((v >> 8) & 0xff);
    p[3] = (uint8_t)(v & 0xff);
}

static void attach_hdr_side_data(AVFilterContext *avctx, CVPixelBufferRef pb, const AVFrame *in)
{
    const AVFrameSideData *sd_md;
    const AVFrameSideData *sd_cll;

    av_vt_pixbuf_set_attachments(avctx, pb, in);

    sd_md = av_frame_get_side_data(in, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    if (sd_md && sd_md->size >= sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *md = (const AVMasteringDisplayMetadata *)sd_md->data;
        if (md->has_primaries && md->has_luminance) {
            uint8_t buf[24];
            /* SMPTE ST 2086: G, B, R, White Point (in 0.00002), max_lum, min_lum (in 0.0001) */
            const int order[3] = { 1, 2, 0 };
            int i;
            for (i = 0; i < 3; ++i) {
                int idx = order[i];
                uint16_t gx = (uint16_t)llround(av_q2d(md->display_primaries[idx][0]) * 50000.0);
                uint16_t gy = (uint16_t)llround(av_q2d(md->display_primaries[idx][1]) * 50000.0);
                write_be16(buf + i * 4 + 0, gx);
                write_be16(buf + i * 4 + 2, gy);
            }
            write_be16(buf + 12, (uint16_t)llround(av_q2d(md->white_point[0]) * 50000.0));
            write_be16(buf + 14, (uint16_t)llround(av_q2d(md->white_point[1]) * 50000.0));
            write_be32(buf + 16, (uint32_t)llround(av_q2d(md->max_luminance) * 10000.0));
            write_be32(buf + 20, (uint32_t)llround(av_q2d(md->min_luminance) * 10000.0));

            CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, sizeof(buf));
            if (data) {
                CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey,
                                      data, kCVAttachmentMode_ShouldPropagate);
                CFRelease(data);
            }
        }
    }

    sd_cll = av_frame_get_side_data(in, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    if (sd_cll && sd_cll->size >= sizeof(AVContentLightMetadata)) {
        const AVContentLightMetadata *cll = (const AVContentLightMetadata *)sd_cll->data;
        uint8_t buf[4];
        write_be16(buf + 0, (uint16_t)cll->MaxCLL);
        write_be16(buf + 2, (uint16_t)cll->MaxFALL);
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, sizeof(buf));
        if (data) {
            CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey,
                                  data, kCVAttachmentMode_ShouldPropagate);
            CFRelease(data);
        }
    }
}

static CVPixelBufferRef sw_frame_to_cvpixelbuffer(AVFilterContext *avctx, const AVFrame *in)
{
    bool is_10bit = (in->format == AV_PIX_FMT_P010LE || in->format == AV_PIX_FMT_YUV420P10LE);
    bool is_full = (in->color_range == AVCOL_RANGE_JPEG);
    OSType fmt = is_10bit
        ? (is_full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : (is_full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange  : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CFMutableDictionaryRef attrs;
    CFMutableDictionaryRef io_attrs;
    CVPixelBufferRef pb = NULL;
    CVReturn cr;
    int y;
    uint8_t *dst_y, *dst_uv;
    size_t stride_y, stride_uv;

    attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    io_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, io_attrs);
    CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);

    cr = CVPixelBufferCreate(kCFAllocatorDefault, in->width, in->height, fmt, attrs, &pb);
    CFRelease(io_attrs);
    CFRelease(attrs);
    if (cr != kCVReturnSuccess || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    dst_y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    stride_y = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    dst_uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

    if (in->format == AV_PIX_FMT_YUV420P10LE) {
        int x;
        for (y = 0; y < in->height; ++y) {
            const uint16_t *sy = (const uint16_t *)(in->data[0] + y * in->linesize[0]);
            uint16_t *dy = (uint16_t *)(dst_y + y * stride_y);
            for (x = 0; x + 8 <= in->width; x += 8) {
                uint16x8_t v = vld1q_u16(sy + x);
                vst1q_u16(dy + x, vshlq_n_u16(v, 6));
            }
            for (; x < in->width; ++x) dy[x] = (uint16_t)(sy[x] << 6);
        }
        for (y = 0; y < in->height / 2; ++y) {
            const uint16_t *su = (const uint16_t *)(in->data[1] + y * in->linesize[1]);
            const uint16_t *sv = (const uint16_t *)(in->data[2] + y * in->linesize[2]);
            uint16_t *duv = (uint16_t *)(dst_uv + y * stride_uv);
            int half_w = in->width / 2;
            for (x = 0; x + 8 <= half_w; x += 8) {
                uint16x8x2_t pair;
                pair.val[0] = vshlq_n_u16(vld1q_u16(su + x), 6);
                pair.val[1] = vshlq_n_u16(vld1q_u16(sv + x), 6);
                vst2q_u16(duv + x * 2, pair);
            }
            for (; x < half_w; ++x) {
                duv[2 * x + 0] = (uint16_t)(su[x] << 6);
                duv[2 * x + 1] = (uint16_t)(sv[x] << 6);
            }
        }
    } else if (in->format == AV_PIX_FMT_YUV420P) {
        int x;
        for (y = 0; y < in->height; ++y) {
            memcpy(dst_y + y * stride_y, in->data[0] + y * in->linesize[0], (size_t)in->width);
        }
        for (y = 0; y < in->height / 2; ++y) {
            const uint8_t *su = in->data[1] + y * in->linesize[1];
            const uint8_t *sv = in->data[2] + y * in->linesize[2];
            uint8_t *duv = dst_uv + y * stride_uv;
            int half_w = in->width / 2;
            for (x = 0; x + 16 <= half_w; x += 16) {
                uint8x16x2_t pair;
                pair.val[0] = vld1q_u8(su + x);
                pair.val[1] = vld1q_u8(sv + x);
                vst2q_u8(duv + x * 2, pair);
            }
            for (; x < half_w; ++x) {
                duv[2 * x + 0] = su[x];
                duv[2 * x + 1] = sv[x];
            }
        }
    } else {
        int bpp = (in->format == AV_PIX_FMT_P010LE) ? 2 : 1;
        for (y = 0; y < in->height; ++y) {
            memcpy(dst_y + y * stride_y, in->data[0] + y * in->linesize[0], (size_t)in->width * bpp);
        }
        for (y = 0; y < in->height / 2; ++y) {
            memcpy(dst_uv + y * stride_uv, in->data[1] + y * in->linesize[1], (size_t)in->width * bpp);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    attach_hdr_side_data(avctx, pb, in);
    return pb;
}

static AVFrame *wrap_output_cvpixelbuffer(AVFilterLink *outlink,
                                          const AVFrame *tmpl,
                                          CVPixelBufferRef pixbuf,
                                          double out_pts_sec)
{
    AVFrame *out = NULL;
    double tb;

    if (outlink->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        out = av_frame_alloc();
        if (!out) {
            CVPixelBufferRelease(pixbuf);
            return NULL;
        }
        if (tmpl) {
            av_frame_copy_props(out, tmpl);
        }
        out->width  = outlink->w;
        out->height = outlink->h;
        out->format = AV_PIX_FMT_VIDEOTOOLBOX;
        out->hw_frames_ctx = av_buffer_ref(ff_filter_link(outlink)->hw_frames_ctx);
        out->buf[0] = av_buffer_create((uint8_t *)pixbuf,
                                       sizeof(CVPixelBufferRef),
                                       macframe_cvbuf_release,
                                       NULL, 0);
        if (!out->buf[0] || !out->hw_frames_ctx) {
            av_frame_free(&out);
            return NULL;
        }
        out->data[3] = (uint8_t *)pixbuf;
    } else {
        int bpp, y;
        const uint8_t *src_y, *src_uv;
        size_t stride_y, stride_uv;

        out = ff_get_video_buffer(outlink, outlink->w, outlink->h);
        if (!out) {
            CVPixelBufferRelease(pixbuf);
            return NULL;
        }
        if (tmpl) {
            av_frame_copy_props(out, tmpl);
        }
        CVPixelBufferLockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);
        src_y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
        stride_y = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
        src_uv = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
        stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);

        if (outlink->format == AV_PIX_FMT_YUV420P10LE) {
            int x;
            for (y = 0; y < out->height; ++y) {
                const uint16_t *sy = (const uint16_t *)(src_y + y * stride_y);
                uint16_t *dy = (uint16_t *)(out->data[0] + y * out->linesize[0]);
                for (x = 0; x + 8 <= out->width; x += 8) {
                    vst1q_u16(dy + x, vshrq_n_u16(vld1q_u16(sy + x), 6));
                }
                for (; x < out->width; ++x) dy[x] = (uint16_t)(sy[x] >> 6);
            }
            for (y = 0; y < out->height / 2; ++y) {
                const uint16_t *suv = (const uint16_t *)(src_uv + y * stride_uv);
                uint16_t *du = (uint16_t *)(out->data[1] + y * out->linesize[1]);
                uint16_t *dv = (uint16_t *)(out->data[2] + y * out->linesize[2]);
                int half_w = out->width / 2;
                for (x = 0; x + 8 <= half_w; x += 8) {
                    uint16x8x2_t pair = vld2q_u16(suv + x * 2);
                    vst1q_u16(du + x, vshrq_n_u16(pair.val[0], 6));
                    vst1q_u16(dv + x, vshrq_n_u16(pair.val[1], 6));
                }
                for (; x < half_w; ++x) {
                    du[x] = (uint16_t)(suv[2 * x + 0] >> 6);
                    dv[x] = (uint16_t)(suv[2 * x + 1] >> 6);
                }
            }
        } else if (outlink->format == AV_PIX_FMT_YUV420P) {
            int x;
            for (y = 0; y < out->height; ++y) {
                memcpy(out->data[0] + y * out->linesize[0], src_y + y * stride_y, (size_t)out->width);
            }
            for (y = 0; y < out->height / 2; ++y) {
                const uint8_t *suv = src_uv + y * stride_uv;
                uint8_t *du = out->data[1] + y * out->linesize[1];
                uint8_t *dv = out->data[2] + y * out->linesize[2];
                int half_w = out->width / 2;
                for (x = 0; x + 16 <= half_w; x += 16) {
                    uint8x16x2_t pair = vld2q_u8(suv + x * 2);
                    vst1q_u8(du + x, pair.val[0]);
                    vst1q_u8(dv + x, pair.val[1]);
                }
                for (; x < half_w; ++x) {
                    du[x] = suv[2 * x + 0];
                    dv[x] = suv[2 * x + 1];
                }
            }
        } else {
            bpp = (outlink->format == AV_PIX_FMT_P010LE) ? 2 : 1;
            for (y = 0; y < out->height; ++y) {
                memcpy(out->data[0] + y * out->linesize[0], src_y + y * stride_y, (size_t)out->width * bpp);
            }
            for (y = 0; y < out->height / 2; ++y) {
                memcpy(out->data[1] + y * out->linesize[1], src_uv + y * stride_uv, (size_t)out->width * bpp);
            }
        }
        CVPixelBufferUnlockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(pixbuf);
    }

    tb = av_q2d(outlink->time_base);
    out->pts = (tb > 0.0) ? llround(out_pts_sec / tb) : 0;
    out->duration = 1;
    return out;
}

static int macframe_activate(AVFilterContext *ctx)
{
    MacFrameContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    int ret;
    CVPixelBufferRef out_pb = NULL;
    double out_pts_sec = 0.0;
    int pull_rc;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    if (s->passthrough_fallback || !s->engine || (s->ipc_state && !s->ipc_state->enabled)) {
        AVFrame *in = NULL;
        int status;
        int64_t pts;

        ret = ff_inlink_consume_frame(inlink, &in);
        if (ret < 0) return ret;
        if (ret > 0) {
            in->pts = av_rescale_q(in->pts, inlink->time_base, outlink->time_base);
            return ff_filter_frame(outlink, in);
        }
        if (ff_inlink_acknowledge_status(inlink, &status, &pts) > 0) {
            ff_outlink_set_status(outlink, status, av_rescale_q(pts, inlink->time_base, outlink->time_base));
            return 0;
        }
        FF_FILTER_FORWARD_WANTED(outlink, inlink);
        return 0;
    }

    /* 1. Drain next ready interpolated frame if available */
    pull_rc = s->fn_pull(s->engine, &out_pb, &out_pts_sec);
    if (pull_rc == MF_OK && out_pb) {
        const AVFrame *tmpl = find_template_for_pts(s, out_pts_sec);
        AVFrame *out = wrap_output_cvpixelbuffer(outlink, tmpl, out_pb, out_pts_sec);
        if (!out)
            return AVERROR(ENOMEM);
        ff_filter_set_ready(ctx, 100);
        return ff_filter_frame(outlink, out);
    }

    /* 2. Consume next input frame if available */
    if (!s->eof) {
        AVFrame *in = NULL;
        int status;
        int64_t status_pts;

        ret = ff_inlink_consume_frame(inlink, &in);
        if (ret < 0)
            return ret;
        if (ret > 0) {
            double pts_sec;
            TemplateEntry *slot;

            if (s->last_in_pts != AV_NOPTS_VALUE && in->pts != AV_NOPTS_VALUE &&
                (in->pts < s->last_in_pts ||
                 (in->pts - s->last_in_pts) * av_q2d(inlink->time_base) > 2.0)) {
                s->fn_reset(s->engine);
            }
            s->last_in_pts = in->pts;

            pts_sec = (in->pts != AV_NOPTS_VALUE)
                          ? (in->pts * av_q2d(inlink->time_base))
                          : ((double)s->in_count / s->in_fps);
            s->in_count++;

            slot = &s->tmpl_ring[s->tmpl_head];
            s->tmpl_head = (s->tmpl_head + 1) % TMPL_RING_SIZE;
            av_frame_unref(slot->frame);
            av_frame_copy_props(slot->frame, in);
            slot->pts_sec = pts_sec;
            slot->valid = true;

            if (in->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                CVPixelBufferRef src_pb = (CVPixelBufferRef)in->data[3];
                if (src_pb) {
                    s->fn_push(s->engine, src_pb, pts_sec);
                }
            } else {
                CVPixelBufferRef src_pb = sw_frame_to_cvpixelbuffer(ctx, in);
                if (src_pb) {
                    s->fn_push(s->engine, src_pb, pts_sec);
                    CVPixelBufferRelease(src_pb);
                }
            }
            av_frame_free(&in);
            ff_filter_set_ready(ctx, 100);
            return 0;
        }

        if (ff_inlink_acknowledge_status(inlink, &status, &status_pts) > 0) {
            s->eof = true;
            s->eof_status = status;
            s->eof_pts = av_rescale_q(status_pts, inlink->time_base, outlink->time_base);
            s->fn_flush(s->engine);
            ff_filter_set_ready(ctx, 100);
            return 0;
        }

        FF_FILTER_FORWARD_WANTED(outlink, inlink);
        return 0;
    }

    /* 3. EOF reached and engine drained */
    ff_outlink_set_status(outlink, s->eof_status, s->eof_pts);
    return 0;
}

#define OFFSET(x) offsetof(MacFrameContext, x)
#define FLAGS (AV_OPT_FLAG_FILTERING_PARAM | AV_OPT_FLAG_VIDEO_PARAM)

static const AVOption macframe_options[] = {
    { "fps",         "Target output frame rate",               OFFSET(fps),         AV_OPT_TYPE_DOUBLE, {.dbl = 120.0}, 15.0, 240.0, FLAGS },
    { "preset",      "Content preset (film|anime|sports)",     OFFSET(preset_str),  AV_OPT_TYPE_STRING, {.str = "film"},   0,     0, FLAGS },
    { "backend",     "Engine backend (mflow|vtfrc|auto|blend)",OFFSET(backend_str), AV_OPT_TYPE_STRING, {.str = "mflow"},  0,     0, FLAGS },
    { "quality",     "Quality ceiling (0.0..1.0)",             OFFSET(quality),     AV_OPT_TYPE_FLOAT,  {.dbl = 1.0},   0.0f,  1.0f, FLAGS },
    { "guard",       "Artifact guard strength (0.0..1.0)",     OFFSET(guard),       AV_OPT_TYPE_FLOAT,  {.dbl = 0.65},  0.0f,  1.0f, FLAGS },
    { "smoothness",  "Motion phase smoothness (0.0..1.0)",     OFFSET(smoothness),  AV_OPT_TYPE_FLOAT,  {.dbl = 0.95},  0.0f,  1.0f, FLAGS },
    { "smooth",      "Motion phase smoothness (0.0..1.0)",     OFFSET(smoothness),  AV_OPT_TYPE_FLOAT,  {.dbl = 0.95},  0.0f,  1.0f, FLAGS },
    { "scene",       "Enable scene cut detection",             OFFSET(scene),       AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "dedup",       "Enable anime 2s/3s deduplication",       OFFSET(dedup),       AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "static_lock", "Lock static HUD/logos/subtitles",        OFFSET(static_lock), AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "letterbox",   "Enable letterbox black-bar guard",       OFFSET(letterbox),   AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "governor",    "Enable adaptive performance governor",   OFFSET(governor),    AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "osd",         "Draw debug confidence bar on frame",     OFFSET(osd),         AV_OPT_TYPE_BOOL,   {.i64 = 0},        0,     1, FLAGS },
    { "ab_mode",     "A/B comparison split mode (0..4)",       OFFSET(ab_mode),     AV_OPT_TYPE_INT,    {.i64 = 0},        0,     4, FLAGS },
    { "ab_split",    "A/B divider position (0.1..0.9)",        OFFSET(ab_split),    AV_OPT_TYPE_FLOAT,  {.dbl = 0.5},   0.1f,  0.9f, FLAGS },
    { "lib",         "Explicit path to libmacframe.dylib",     OFFSET(lib_path),    AV_OPT_TYPE_STRING, {.str = NULL},     0,     0, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(macframe);

static const enum AVPixelFormat macframe_pix_fmts[] = {
    AV_PIX_FMT_VIDEOTOOLBOX,
    AV_PIX_FMT_NV12,
    AV_PIX_FMT_P010LE,
    AV_PIX_FMT_YUV420P10LE,
    AV_PIX_FMT_YUV420P,
    AV_PIX_FMT_NONE
};

static const AVFilterPad macframe_inputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_VIDEO,
    },
};

static const AVFilterPad macframe_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = macframe_config_output,
    },
};

const FFFilter ff_vf_macframe = {
    .p.name         = "macframe",
    .p.description  = NULL_IF_CONFIG_SMALL("Apple Silicon native real-time frame interpolation (MacFrame)"),
    .p.priv_class   = &macframe_class,
    .p.flags        = AVFILTER_FLAG_HWDEVICE,
    .priv_size      = sizeof(MacFrameContext),
    .init           = macframe_init,
    .uninit         = macframe_uninit,
    .activate       = macframe_activate,
    FILTER_INPUTS(macframe_inputs),
    FILTER_OUTPUTS(macframe_outputs),
    FILTER_PIXFMTS_ARRAY(macframe_pix_fmts),
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
};

#if defined(__APPLE__) && defined(__aarch64__)
__attribute__((constructor))
static void macframe_avfilter_autoload(void)
{
    char sibling_path[1024] = {0};
    Dl_info dli;
    if (dladdr((const void *)&macframe_avfilter_autoload, &dli) && dli.dli_fname) {
        const char *slash = strrchr(dli.dli_fname, '/');
        if (slash) {
            size_t dir_len = (size_t)(slash - dli.dli_fname);
            if (dir_len + sizeof("/libmacframe.dylib") < sizeof(sibling_path)) {
                memcpy(sibling_path, dli.dli_fname, dir_len);
                strcpy(sibling_path + dir_len, "/libmacframe.dylib");
                dlopen(sibling_path, RTLD_NOW | RTLD_LOCAL);
            }
        }
    }
}
#endif
