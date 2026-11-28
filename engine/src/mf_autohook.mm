// SPDX-License-Identifier: GPL-3.0-or-later
// mf_autohook.mm — Automatic in-process libmpv controller for IINA.
// Loaded automatically when IINA maps libavfilter.12.dylib -> libmacframe.dylib.
// Hooks IINA's Mach-O GOT entries for libmpv so MacFrame.app can enable/disable
// and control frame interpolation in real time without requiring IINA plugins
// or manual IINA filter configuration. When disabled, restores 100% of the
// user's original IINA settings.

#include "macframe/macframe.h"
#include "macframe/mf_ipc.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using mpv_initialize_fn          = int (*)(void *ctx);
using mpv_wait_event_fn          = void *(*)(void *ctx, double timeout);
using mpv_get_property_string_fn = char *(*)(void *ctx, const char *name);
using mpv_set_property_string_fn = int (*)(void *ctx, const char *name, const char *data);
using mpv_command_fn             = int (*)(void *ctx, const char **args);
using mpv_free_fn                = void (*)(void *data);
using mpv_destroy_fn             = void (*)(void *ctx);

static mpv_initialize_fn          orig_mpv_initialize          = nullptr;
static mpv_wait_event_fn          orig_mpv_wait_event          = nullptr;
static mpv_get_property_string_fn orig_mpv_get_property_string = nullptr;
static mpv_set_property_string_fn orig_mpv_set_property_string = nullptr;
static mpv_command_fn             orig_mpv_command             = nullptr;
static mpv_free_fn                orig_mpv_free                = nullptr;
static mpv_destroy_fn             orig_mpv_destroy             = nullptr;
static mpv_destroy_fn             orig_mpv_terminate_destroy   = nullptr;

struct MpvSession {
    void *ctx = nullptr;
    bool has_snapshot = false;
    bool filter_applied = false;
    double applied_fps = 0.0;
    std::string orig_hwdec;
    std::string orig_vsync;
    std::string orig_interp;
};

static std::mutex g_mtx;
static std::vector<MpvSession> g_sessions;

static void autohook_log(const char *fmt, ...) {
    FILE *f = fopen("/tmp/macframe_autohook.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fprintf(f, "\n");
    fclose(f);
}

static void register_ctx(void *ctx) {
    if (!ctx) return;
    std::lock_guard<std::mutex> lock(g_mtx);
    for (auto &s : g_sessions) {
        if (s.ctx == ctx) return;
    }
    MpvSession s;
    s.ctx = ctx;
    g_sessions.push_back(s);
    autohook_log("[autohook] Registered mpv_handle ctx=%p (total=%zu)", ctx, g_sessions.size());
}

static void unregister_ctx(void *ctx) {
    if (!ctx) return;
    std::lock_guard<std::mutex> lock(g_mtx);
    for (auto it = g_sessions.begin(); it != g_sessions.end(); ++it) {
        if (it->ctx == ctx) {
            g_sessions.erase(it);
            autohook_log("[autohook] Unregistered mpv_handle ctx=%p", ctx);
            return;
        }
    }
}

static int hook_mpv_initialize(void *ctx) {
    int r = orig_mpv_initialize ? orig_mpv_initialize(ctx) : -1;
    if (r >= 0 && ctx) {
        register_ctx(ctx);
    }
    return r;
}

static void *hook_mpv_wait_event(void *ctx, double timeout) {
    if (ctx) {
        register_ctx(ctx);
    }
    return orig_mpv_wait_event ? orig_mpv_wait_event(ctx, timeout) : nullptr;
}

static int hook_mpv_command(void *ctx, const char **args) {
    if (ctx) {
        register_ctx(ctx);
        if (args && args[0]) {
            autohook_log("[autohook] mpv_command ctx=%p cmd='%s' arg1='%s'",
                         ctx, args[0], args[1] ? args[1] : "");
        }
    }
    return orig_mpv_command ? orig_mpv_command(ctx, args) : -1;
}

static void hook_mpv_destroy(void *ctx) {
    unregister_ctx(ctx);
    if (orig_mpv_destroy) orig_mpv_destroy(ctx);
}

static void hook_mpv_terminate_destroy(void *ctx) {
    unregister_ctx(ctx);
    if (orig_mpv_terminate_destroy) orig_mpv_terminate_destroy(ctx);
}

static void patch_section_pointers(const struct mach_header_64 *mh,
                                   const char *segname,
                                   const char *sectname) {
    unsigned long size = 0;
    uint8_t *sec = getsectiondata(mh, segname, sectname, &size);
    if (!sec || size < sizeof(void *)) return;

    vm_address_t page_start = (vm_address_t)sec & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t page_len = (((vm_address_t)sec + size - page_start) + vm_page_size - 1) &
                         ~(vm_size_t)(vm_page_size - 1);

    kern_return_t kr = vm_protect(mach_task_self(), page_start, page_len, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return;

    int patched = 0;
    void **slots = reinterpret_cast<void **>(sec);
    size_t count = size / sizeof(void *);
    for (size_t i = 0; i < count; ++i) {
        void *val = slots[i];
        if (orig_mpv_initialize && val == reinterpret_cast<void *>(orig_mpv_initialize)) {
            slots[i] = reinterpret_cast<void *>(&hook_mpv_initialize);
            patched++;
        } else if (orig_mpv_wait_event && val == reinterpret_cast<void *>(orig_mpv_wait_event)) {
            slots[i] = reinterpret_cast<void *>(&hook_mpv_wait_event);
            patched++;
        } else if (orig_mpv_command && val == reinterpret_cast<void *>(orig_mpv_command)) {
            slots[i] = reinterpret_cast<void *>(&hook_mpv_command);
            patched++;
        } else if (orig_mpv_destroy && val == reinterpret_cast<void *>(orig_mpv_destroy)) {
            slots[i] = reinterpret_cast<void *>(&hook_mpv_destroy);
            patched++;
        } else if (orig_mpv_terminate_destroy && val == reinterpret_cast<void *>(orig_mpv_terminate_destroy)) {
            slots[i] = reinterpret_cast<void *>(&hook_mpv_terminate_destroy);
            patched++;
        }
    }
    if (patched > 0) {
        autohook_log("[autohook] Patched %d GOT slots in %s.%s", patched, segname, sectname);
    }

    vm_protect(mach_task_self(), page_start, page_len, FALSE, VM_PROT_READ);
}

static bool install_got_hooks() {
    if (!orig_mpv_initialize) {
        orig_mpv_initialize          = reinterpret_cast<mpv_initialize_fn>(dlsym(RTLD_DEFAULT, "mpv_initialize"));
        orig_mpv_wait_event          = reinterpret_cast<mpv_wait_event_fn>(dlsym(RTLD_DEFAULT, "mpv_wait_event"));
        orig_mpv_get_property_string = reinterpret_cast<mpv_get_property_string_fn>(dlsym(RTLD_DEFAULT, "mpv_get_property_string"));
        orig_mpv_set_property_string = reinterpret_cast<mpv_set_property_string_fn>(dlsym(RTLD_DEFAULT, "mpv_set_property_string"));
        orig_mpv_command             = reinterpret_cast<mpv_command_fn>(dlsym(RTLD_DEFAULT, "mpv_command"));
        orig_mpv_free                = reinterpret_cast<mpv_free_fn>(dlsym(RTLD_DEFAULT, "mpv_free"));
        orig_mpv_destroy             = reinterpret_cast<mpv_destroy_fn>(dlsym(RTLD_DEFAULT, "mpv_destroy"));
        orig_mpv_terminate_destroy   = reinterpret_cast<mpv_destroy_fn>(dlsym(RTLD_DEFAULT, "mpv_terminate_destroy"));
    }
    if (!orig_mpv_initialize || !orig_mpv_get_property_string || !orig_mpv_set_property_string || !orig_mpv_command || !orig_mpv_free) {
        return false;
    }

    uint32_t img_count = _dyld_image_count();
    for (uint32_t i = 0; i < img_count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (i == 0 || strstr(name, "/MacOS/IINA") != nullptr) {
            const auto *mh = reinterpret_cast<const struct mach_header_64 *>(_dyld_get_image_header(i));
            if (!mh || mh->magic != MH_MAGIC_64) continue;
            patch_section_pointers(mh, "__DATA_CONST", "__got");
            patch_section_pointers(mh, "__DATA", "__got");
            patch_section_pointers(mh, "__DATA", "__la_symbol_ptr");
            patch_section_pointers(mh, "__DATA", "__nl_symbol_ptr");
        }
    }
    return true;
}

static std::string get_mpv_prop(void *ctx, const char *name) {
    if (!orig_mpv_get_property_string || !ctx) return {};
    char *s = orig_mpv_get_property_string(ctx, name);
    if (!s) return {};
    std::string res(s);
    if (orig_mpv_free) orig_mpv_free(s);
    return res;
}

static double query_main_display_refresh_rate() {
    double hz = 120.0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (mode) {
        double r = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
        if (r >= 48.0) hz = r;
    }
    return hz;
}

static const char *preset_to_str(int32_t p) {
    switch (p) {
        case 1: return "anime";
        case 2: return "sports";
        case 3: return "custom";
        default: return "film";
    }
}

static const char *backend_to_str(int32_t b) {
    switch (b) {
        case 0: return "auto";
        case 2: return "vtfrc";
        case 3: return "blend";
        default: return "mflow";
    }
}

// Executed WITHOUT holding g_mtx so mpv API calls never block IINA threads
static void sync_session(MpvSession &s, mf_ipc_state *ipc) {
    if (!s.ctx || !ipc) return;

    std::string vo_str = get_mpv_prop(s.ctx, "vo");
    if (vo_str == "null") {
        return;
    }
    std::string w_str = get_mpv_prop(s.ctx, "video-params/w");
    if (w_str.empty() || std::atoi(w_str.c_str()) <= 0) {
        s.filter_applied = false;
        return;
    }

    std::string cur_vf = get_mpv_prop(s.ctx, "vf");
    bool has_macframe_in_vf = (cur_vf.find("macframe") != std::string::npos);

    if (ipc->enabled == 0) {
        if (has_macframe_in_vf || s.filter_applied) {
            const char *rm_cmd[] = {"vf", "remove", "@macframe", nullptr};
            orig_mpv_command(s.ctx, rm_cmd);

            if (s.has_snapshot) {
                if (!s.orig_hwdec.empty()) {
                    orig_mpv_set_property_string(s.ctx, "hwdec", s.orig_hwdec.c_str());
                }
                if (!s.orig_vsync.empty()) {
                    orig_mpv_set_property_string(s.ctx, "video-sync", s.orig_vsync.c_str());
                }
                if (!s.orig_interp.empty()) {
                    orig_mpv_set_property_string(s.ctx, "interpolation", s.orig_interp.c_str());
                }
                s.has_snapshot = false;
            }
            s.filter_applied = false;
            s.applied_fps = 0.0;
            autohook_log("[autohook] Removed @macframe and restored original IINA settings on ctx=%p", s.ctx);
        }
        return;
    }

    if (!s.has_snapshot) {
        s.orig_hwdec  = get_mpv_prop(s.ctx, "hwdec");
        s.orig_vsync  = get_mpv_prop(s.ctx, "video-sync");
        s.orig_interp = get_mpv_prop(s.ctx, "interpolation");
        s.has_snapshot = true;
    }

    double in_fps = std::atof(get_mpv_prop(s.ctx, "container-fps").c_str());
    if (in_fps <= 1.0) in_fps = 24.0;

    double disp_fps = std::max(
        std::atof(get_mpv_prop(s.ctx, "display-fps").c_str()),
        query_main_display_refresh_rate());
    if (disp_fps < 60.0) disp_fps = 120.0;

    double cap = (ipc->max_fps_cap >= 24.0) ? ipc->max_fps_cap : 120.0;
    double target_fps = cap;
    if (ipc->fps_mode == MF_FPS_MODE_FIXED) {
        target_fps = cap;
    } else if (ipc->fps_mode == MF_FPS_MODE_DOUBLE) {
        target_fps = std::min(in_fps * 2.0, cap);
    } else {
        target_fps = std::min(disp_fps, cap);
    }
    if (target_fps < 30.0) target_fps = 60.0;

    std::string cur_hwdec = get_mpv_prop(s.ctx, "hwdec");
    if (cur_hwdec == "no" || cur_hwdec == "auto-copy") {
        orig_mpv_set_property_string(s.ctx, "hwdec", "videotoolbox");
    }

    if (!has_macframe_in_vf || std::abs(target_fps - s.applied_fps) > 0.5) {
        if (has_macframe_in_vf) {
            const char *rm_cmd[] = {"vf", "remove", "@macframe", nullptr};
            orig_mpv_command(s.ctx, rm_cmd);
        }

        char spec[640];
        std::snprintf(
            spec, sizeof(spec),
            "@macframe:lavfi=[macframe=fps=%.2f:preset=%s:backend=%s:quality=%.2f:guard=%.2f:smoothness=%.2f:scene=%d:dedup=%d:static_lock=%d:letterbox=%d:governor=%d:osd=%d:ab_mode=%d:ab_split=%.2f]",
            target_fps,
            preset_to_str(ipc->preset),
            backend_to_str(ipc->backend),
            std::clamp(ipc->quality, 0.0f, 1.0f),
            std::clamp(ipc->artifact_guard, 0.0f, 1.0f),
            std::clamp(ipc->smoothness, 0.0f, 1.0f),
            ipc->scene_detect ? 1 : 0,
            ipc->dedup ? 1 : 0,
            ipc->static_lock ? 1 : 0,
            ipc->letterbox_guard ? 1 : 0,
            ipc->governor ? 1 : 0,
            ipc->debug_osd ? 1 : 0,
            std::clamp(ipc->ab_mode, 0, 4),
            std::clamp(ipc->ab_split, 0.1f, 0.9f));

        const char *add_cmd[] = {"vf", "add", spec, nullptr};
        int rc = orig_mpv_command(s.ctx, add_cmd);
        autohook_log("[autohook] vf add %s -> rc=%d (in_fps=%.2f disp_fps=%.2f cap=%.2f)",
                     spec, rc, in_fps, disp_fps, cap);
        s.filter_applied = (rc >= 0);
        s.applied_fps = target_fps;
    }
}

static void autohook_worker() {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    mf_ipc_state *ipc = mf_ipc_open();
    bool hooked = false;
    autohook_log("[autohook] worker started ipc=%p", ipc);

    while (true) {
        if (!hooked) {
            hooked = install_got_hooks();
            autohook_log("[autohook] install_got_hooks -> %d", (int)hooked);
        }
        if (ipc && hooked) {
            std::vector<MpvSession> snapshot;
            {
                std::lock_guard<std::mutex> lock(g_mtx);
                snapshot = g_sessions;
            }
            for (auto &s : snapshot) {
                sync_session(s, ipc);
                std::lock_guard<std::mutex> lock(g_mtx);
                for (auto &orig : g_sessions) {
                    if (orig.ctx == s.ctx) {
                        orig = s;
                        break;
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
}

__attribute__((constructor))
static void mf_autohook_ctor() {
    const char *prog = getprogname();
    autohook_log("[autohook] ctor loaded in prog=%s pid=%d", prog ? prog : "null", getpid());
    bool is_iina = (prog && (strcmp(prog, "IINA") == 0 || strcmp(prog, "iina-cli") == 0));
    if (!is_iina && !getenv("MACFRAME_FORCE_AUTOHOOK")) {
        return;
    }
    std::thread(autohook_worker).detach();
    if (mf_ipc_state *st = mf_ipc_open()) {
        std::snprintf(st->active_client, sizeof(st->active_client), "%s", "IINA");
        mf_ipc_close(st);
    }
}

} // namespace
