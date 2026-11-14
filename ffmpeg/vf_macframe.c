/*
 * MacFrame — Apple Silicon Native Frame Interpolation Filter for FFmpeg / mpv / IINA
 * Copyright (c) 2026 pseudoomer
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
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
#include "libavutil/mathematics.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "avfilter.h"
#include "filters.h"
#include "internal.h"
#include "video.h"

/* --- MacFrame Engine C ABI (matched to engine/include/macframe/macframe.h) --- */
#define MF_ABI_VERSION 1u
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
} mf_stats;

typedef void       (*mf_config_init_default_fn)(mf_config *, mf_preset);
typedef mf_engine *(*mf_engine_create_fn)(const mf_config *, char *, size_t);
typedef int        (*mf_engine_push_fn)(mf_engine *, CVPixelBufferRef, double);
typedef int        (*mf_engine_pull_fn)(mf_engine *, CVPixelBufferRef *, double *);
typedef int        (*mf_engine_flush_fn)(mf_engine *);
typedef void       (*mf_engine_reset_fn)(mf_engine *);
typedef void       (*mf_engine_get_stats_fn)(mf_engine *, mf_stats *);
typedef void       (*mf_engine_destroy_fn)(mf_engine *);

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
    mf_engine_destroy_fn      fn_destroy;

    mf_engine *engine;
    bool       passthrough_fallback;
    bool       eof;
    int        eof_status;
    int64_t    eof_pts;
    int64_t    last_in_pts;
    uint64_t   in_count;
    double     in_fps;

    AVFrame   *template_frame;
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
    LOAD_SYM(fn_destroy,      mf_engine_destroy);
#undef LOAD_SYM

    return true;
}

static av_cold int macframe_init(AVFilterContext *avctx)
{
    MacFrameContext *s = avctx->priv;
    s->last_in_pts = AV_NOPTS_VALUE;
    s->template_frame = av_frame_alloc();
    if (!s->template_frame)
        return AVERROR(ENOMEM);

    if (!load_engine_dylib(avctx, s)) {
        s->passthrough_fallback = true;
    }
    return 0;
}

static av_cold void macframe_uninit(AVFilterContext *avctx)
{
    MacFrameContext *s = avctx->priv;
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
    av_frame_free(&s->template_frame);
}

static int macframe_config_output(AVFilterLink *outlink)
{
    AVFilterContext *avctx = outlink->src;
    MacFrameContext *s = avctx->priv;
    AVFilterLink *inlink = avctx->inputs[0];
    int err;
    double target_fps;
    uint32_t cv_pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    outlink->w = inlink->w;
    outlink->h = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;

    s->in_fps = (inlink->frame_rate.num > 0 && inlink->frame_rate.den > 0)
                    ? av_q2d(inlink->frame_rate)
                    : 24.0;
    target_fps = (s->fps > 1.0) ? s->fps : 120.0;

    outlink->frame_rate = av_d2q(target_fps, 100000);
    outlink->time_base  = av_inv_q(outlink->frame_rate);

    if (inlink->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        AVHWFramesContext *hw_in;
        AVHWFramesContext *hw_out;
        if (!inlink->hw_frames_ctx) {
            av_log(avctx, AV_LOG_ERROR, "macframe requires hw_frames_ctx for videotoolbox input\n");
            return AVERROR(EINVAL);
        }
        hw_in = (AVHWFramesContext *)inlink->hw_frames_ctx->data;
        av_buffer_unref(&outlink->hw_frames_ctx);
        outlink->hw_frames_ctx = av_hwframe_ctx_alloc(hw_in->device_ref);
        if (!outlink->hw_frames_ctx)
            return AVERROR(ENOMEM);

        hw_out = (AVHWFramesContext *)outlink->hw_frames_ctx->data;
        hw_out->format    = AV_PIX_FMT_VIDEOTOOLBOX;
        hw_out->sw_format = hw_in->sw_format;
        hw_out->width     = outlink->w;
        hw_out->height    = outlink->h;

        err = ff_filter_init_hw_frames(avctx, outlink, 1);
        if (err < 0)
            return err;

        err = av_hwframe_ctx_init(outlink->hw_frames_ctx);
        if (err < 0) {
            av_log(avctx, AV_LOG_ERROR, "Failed to init videotoolbox out hw_frames_ctx\n");
            return err;
        }

        if (hw_in->sw_format == AV_PIX_FMT_P010LE || hw_in->sw_format == AV_PIX_FMT_P010BE) {
            cv_pixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        } else if (hw_in->sw_format == AV_PIX_FMT_BGRA) {
            cv_pixfmt = kCVPixelFormatType_32BGRA;
        }
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

        s->engine = s->fn_create(&cfg, errbuf, sizeof(errbuf));
        if (!s->engine) {
            av_log(avctx, AV_LOG_WARNING,
                   "mf_engine_create failed (%s); falling back to passthrough.\n",
                   errbuf);
            s->passthrough_fallback = true;
        } else {
            av_log(avctx, AV_LOG_INFO,
                   "MacFrame active: %dx%d %.2f->%.2ffps preset=%s backend=%s\n",
                   cfg.width, cfg.height, cfg.in_fps, cfg.out_fps,
                   s->preset_str ? s->preset_str : "film",
                   s->backend_str ? s->backend_str : "mflow");
        }
    }

    return 0;
}

static CVPixelBufferRef sw_frame_to_cvpixelbuffer(const AVFrame *in)
{
    OSType fmt = (in->format == AV_PIX_FMT_P010LE)
                     ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFMutableDictionaryRef attrs;
    CFMutableDictionaryRef io_attrs;
    CVPixelBufferRef pb = NULL;
    CVReturn cr;
    int bpp, y;
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
    bpp = (in->format == AV_PIX_FMT_P010LE) ? 2 : 1;
    dst_y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    stride_y = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (y = 0; y < in->height; ++y) {
        memcpy(dst_y + y * stride_y, in->data[0] + y * in->linesize[0], (size_t)in->width * bpp);
    }
    dst_uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (y = 0; y < in->height / 2; ++y) {
        memcpy(dst_uv + y * stride_uv, in->data[1] + y * in->linesize[1], (size_t)in->width * bpp);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
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
        out->hw_frames_ctx = av_buffer_ref(outlink->hw_frames_ctx);
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
        bpp = (outlink->format == AV_PIX_FMT_P010LE) ? 2 : 1;
        CVPixelBufferLockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);
        src_y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
        stride_y = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
        for (y = 0; y < out->height; ++y) {
            memcpy(out->data[0] + y * out->linesize[0], src_y + y * stride_y, (size_t)out->width * bpp);
        }
        src_uv = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
        stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);
        for (y = 0; y < out->height / 2; ++y) {
            memcpy(out->data[1] + y * out->linesize[1], src_uv + y * stride_uv, (size_t)out->width * bpp);
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

    if (s->passthrough_fallback || !s->engine) {
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
        AVFrame *out = wrap_output_cvpixelbuffer(outlink, s->template_frame, out_pb, out_pts_sec);
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

            av_frame_unref(s->template_frame);
            av_frame_copy_props(s->template_frame, in);

            if (in->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                CVPixelBufferRef src_pb = (CVPixelBufferRef)in->data[3];
                if (src_pb) {
                    s->fn_push(s->engine, src_pb, pts_sec);
                }
            } else {
                CVPixelBufferRef src_pb = sw_frame_to_cvpixelbuffer(in);
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
    { "scene",       "Enable scene cut detection",             OFFSET(scene),       AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "dedup",       "Enable anime 2s/3s deduplication",       OFFSET(dedup),       AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "static_lock", "Lock static HUD/logos/subtitles",        OFFSET(static_lock), AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "letterbox",   "Enable letterbox black-bar guard",       OFFSET(letterbox),   AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "governor",    "Enable adaptive performance governor",   OFFSET(governor),    AV_OPT_TYPE_BOOL,   {.i64 = 1},        0,     1, FLAGS },
    { "osd",         "Draw debug confidence bar on frame",     OFFSET(osd),         AV_OPT_TYPE_BOOL,   {.i64 = 0},        0,     1, FLAGS },
    { "lib",         "Explicit path to libmacframe.dylib",     OFFSET(lib_path),    AV_OPT_TYPE_STRING, {.str = NULL},     0,     0, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(macframe);

static const enum AVPixelFormat macframe_pix_fmts[] = {
    AV_PIX_FMT_VIDEOTOOLBOX,
    AV_PIX_FMT_NV12,
    AV_PIX_FMT_P010LE,
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

const AVFilter ff_vf_macframe = {
    .name           = "macframe",
    .description    = NULL_IF_CONFIG_SMALL("Apple Silicon native real-time frame interpolation (MacFrame)"),
    .priv_size      = sizeof(MacFrameContext),
    .priv_class     = &macframe_class,
    .init           = macframe_init,
    .uninit         = macframe_uninit,
    .activate       = macframe_activate,
    FILTER_INPUTS(macframe_inputs),
    FILTER_OUTPUTS(macframe_outputs),
    FILTER_PIXFMTS_ARRAY(macframe_pix_fmts),
    .flags          = AVFILTER_FLAG_HWDEVICE,
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
};
