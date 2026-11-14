// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef MACFRAME_IPC_H
#define MACFRAME_IPC_H

#include "macframe/macframe.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MF_IPC_MAGIC   0x4D46524Du // 'MFRM'
#define MF_IPC_VERSION 1u

typedef enum mf_fps_mode {
    MF_FPS_MODE_DISPLAY = 0, // Match display refresh rate, capped at max_fps_cap
    MF_FPS_MODE_FIXED   = 1, // Fixed at max_fps_cap
    MF_FPS_MODE_DOUBLE  = 2, // 2x source FPS, capped at max_fps_cap
} mf_fps_mode;

// Page-aligned shared memory structure mapped at:
// ~/Library/Application Support/MacFrame/ipc_state.bin
typedef struct mf_ipc_state {
    uint32_t magic;              // MF_IPC_MAGIC
    uint32_t version;            // MF_IPC_VERSION
    uint64_t config_seq;         // Incremented atomically by MacFrame.app on any setting change

    // --- User Control Settings (written by MacFrame.app) ---
    int32_t  enabled;            // 1 = interpolation enabled, 0 = disabled (native IINA settings)
    int32_t  fps_mode;           // mf_fps_mode
    double   max_fps_cap;        // Maximum output frame rate cap (e.g. 60, 90, 120, 144, 240)
    int32_t  preset;             // mf_preset (0=film, 1=anime, 2=sports, 3=custom)
    int32_t  backend;            // mf_backend (0=auto, 1=mflow, 2=vtfrc, 3=blend)
    float    quality;            // 0.0 .. 1.0 (governor ceiling)
    float    artifact_guard;     // 0.0 .. 1.0 (artifact repair / fallback strength)
    float    smoothness;         // 0.0 .. 1.0 (motion smoothness / phase uniformity)
    int32_t  scene_detect;       // 0 or 1 (scene cut zero-ghosting protection)
    int32_t  dedup;              // 0 or 1 (anime 2s/3s duplicate cadence reconstruction)
    int32_t  static_lock;        // 0 or 1 (HUD / logo / scoreboard / subtitle lock)
    int32_t  letterbox_guard;    // 0 or 1 (black bar boundary protection)
    int32_t  governor;           // 0 or 1 (adaptive performance governor Q4..Q0)
    int32_t  debug_osd;          // 0 or 1 (draw confidence bar on frame)

    // --- Live Telemetry (written by libmacframe inside IINA) ---
    uint64_t heartbeat_ms;       // Epoch milliseconds of last processed frame
    int32_t  active_pid;         // PID of active player process
    int32_t  video_width;
    int32_t  video_height;
    double   source_fps;
    double   output_fps;
    mf_stats stats;
} mf_ipc_state;

// Open or create the shared memory mapping (returns pointer or NULL on failure).
mf_ipc_state *mf_ipc_open(void);

// Close the shared memory mapping.
void mf_ipc_close(mf_ipc_state *st);

// Return current wall-clock time in milliseconds since epoch.
uint64_t mf_ipc_now_ms(void);

// Export live_config.json for IINA JS plugin synchronization.
int mf_ipc_write_plugin_json(const mf_ipc_state *st);

typedef mf_ipc_state *(*mf_ipc_open_fn)(void);
typedef void (*mf_ipc_close_fn)(mf_ipc_state *);

#ifdef __cplusplus
}
#endif

#endif // MACFRAME_IPC_H
