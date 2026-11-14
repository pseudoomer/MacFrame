// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef MACFRAME_H
#define MACFRAME_H

#include <CoreVideo/CoreVideo.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MF_ABI_VERSION 1u

#define MF_OK     0
#define MF_EAGAIN 1
#define MF_EOF    2
#define MF_ERR   -1

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
    float      quality;          // 0.0 .. 1.0 (governor ceiling)
    float      artifact_guard;   // 0.0 .. 1.0 (local/global fallback strength)
    float      smoothness;       // 0.0 .. 1.0 (1.0 = uniform phase, <1.0 = cinematic)
    int        scene_detect;     // 0 or 1
    int        dedup;            // 0 = off, 1 = reconstruct uniform timeline (anime 2s/3s)
    int        static_lock;      // 0 or 1 (HUD / logo / subtitle stationary lock)
    int        letterbox_guard;  // 0 or 1 (black bar detection & boundary clamp)
    int        governor;         // 0 or 1 (adaptive quality Q4..Q0)
    int        debug_osd;        // 0 = off, 1 = overlay status bar
} mf_config;

typedef struct mf_stats {
    uint64_t   frames_in;
    uint64_t   frames_out;
    uint64_t   scene_cuts;
    uint64_t   dedup_drops;
    int        current_tier;     // 0 (passthrough) .. 4 (ultra)
    mf_backend active_backend;
    double     gpu_time_ms_avg;
    double     gpu_time_ms_p99;
    float      mean_confidence;
    float      fallback_ratio;
    float      global_blend_alpha;
    int        letterbox_top;
    int        letterbox_bottom;
} mf_stats;

// Initialize cfg with defaults for the given preset.
void mf_config_init_default(mf_config *cfg, mf_preset preset);

// Create an interpolation engine instance.
mf_engine *mf_engine_create(const mf_config *cfg, char *err, size_t errlen);

// Push a source frame with timestamp pts (in seconds).
int mf_engine_push(mf_engine *e, CVPixelBufferRef src, double pts);

// Pull the next interpolated output frame.
// Returns MF_OK (0) and sets *out_buf (caller must CVPixelBufferRelease) and *out_pts,
// MF_EAGAIN (1) if more input frames are needed, MF_EOF (2) when flushed and empty,
// or MF_ERR (<0) on failure.
int mf_engine_pull(mf_engine *e, CVPixelBufferRef *out_buf, double *out_pts);

// Signal end-of-stream so buffered frames are drained.
int mf_engine_flush(mf_engine *e);

// Reset timeline state (e.g. on seek) without destroying Metal pipelines.
void mf_engine_reset(mf_engine *e);

// Query runtime statistics and governor metrics.
void mf_engine_get_stats(mf_engine *e, mf_stats *st);

// Enable or disable live shared-memory IPC synchronization with MacFrame.app.
void mf_engine_enable_ipc(mf_engine *e, int enable);

// Direct pair interpolation for evaluation/benchmarking.
// If out_flow_xy is non-NULL, writes width*height*2 floats (dx, dy in pixels from f0 to f1).
int mf_engine_interpolate_pair(mf_engine *e,
                               CVPixelBufferRef f0,
                               CVPixelBufferRef f1,
                               float phase,
                               CVPixelBufferRef *out_buf,
                               float *out_flow_xy);

// Destroy engine instance.
void mf_engine_destroy(mf_engine *e);

// Function pointer typedefs for runtime dlopen/dlsym consumers (vf_macframe).
typedef void (*mf_config_init_default_fn)(mf_config *, mf_preset);
typedef mf_engine *(*mf_engine_create_fn)(const mf_config *, char *, size_t);
typedef int (*mf_engine_push_fn)(mf_engine *, CVPixelBufferRef, double);
typedef int (*mf_engine_pull_fn)(mf_engine *, CVPixelBufferRef *, double *);
typedef int (*mf_engine_flush_fn)(mf_engine *);
typedef void (*mf_engine_reset_fn)(mf_engine *);
typedef void (*mf_engine_get_stats_fn)(mf_engine *, mf_stats *);
typedef void (*mf_engine_enable_ipc_fn)(mf_engine *, int);
typedef void (*mf_engine_destroy_fn)(mf_engine *);

#ifdef __cplusplus
}
#endif

#endif // MACFRAME_H
