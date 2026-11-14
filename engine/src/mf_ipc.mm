// SPDX-License-Identifier: GPL-3.0-or-later
#include "macframe/mf_ipc.h"

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

static std::string get_ipc_dir() {
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    return std::string(home) + "/Library/Application Support/MacFrame";
}

static std::string get_ipc_file_path() {
    return get_ipc_dir() + "/ipc_state.bin";
}

static void init_default_ipc_state(mf_ipc_state *st) {
    std::memset(st, 0, sizeof(*st));
    st->magic           = MF_IPC_MAGIC;
    st->version         = MF_IPC_VERSION;
    st->config_seq      = 1;
    st->enabled         = 1;
    st->fps_mode        = MF_FPS_MODE_DISPLAY;
    st->max_fps_cap     = 120.0;
    st->preset          = MF_PRESET_FILM;
    st->backend         = MF_BACKEND_MFLOW;
    st->quality         = 1.0f;
    st->artifact_guard  = 0.65f;
    st->smoothness      = 0.95f;
    st->scene_detect    = 1;
    st->dedup           = 1;
    st->static_lock     = 1;
    st->letterbox_guard = 1;
    st->governor        = 1;
    st->debug_osd       = 0;
}

} // namespace

extern "C" {

uint64_t mf_ipc_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (uint64_t)tv.tv_sec * 1000ull + (uint64_t)(tv.tv_usec / 1000);
}

mf_ipc_state *mf_ipc_open(void) {
    @autoreleasepool {
        std::string dir = get_ipc_dir();
        [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:dir.c_str()]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        std::string path = get_ipc_file_path();
        int fd = open(path.c_str(), O_RDWR | O_CREAT, 0644);
        if (fd < 0) return nullptr;

        struct stat sb{};
        bool needs_init = false;
        if (fstat(fd, &sb) == 0 && (size_t)sb.st_size < 4096) {
            if (ftruncate(fd, 4096) != 0) {
                close(fd);
                return nullptr;
            }
            needs_init = true;
        }

        void *ptr = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (ptr == MAP_FAILED || !ptr) return nullptr;

        auto *st = static_cast<mf_ipc_state *>(ptr);
        if (needs_init || st->magic != MF_IPC_MAGIC || st->version != MF_IPC_VERSION) {
            init_default_ipc_state(st);
            mf_ipc_write_plugin_json(st);
        }
        return st;
    }
}

void mf_ipc_close(mf_ipc_state *st) {
    if (st) {
        munmap(st, 4096);
    }
}

int mf_ipc_write_plugin_json(const mf_ipc_state *st) {
    if (!st) return -1;
    @autoreleasepool {
        const char *preset_str = "film";
        if (st->preset == MF_PRESET_ANIME) preset_str = "anime";
        else if (st->preset == MF_PRESET_SPORTS) preset_str = "sports";
        else if (st->preset == MF_PRESET_CUSTOM) preset_str = "custom";

        const char *backend_str = "mflow";
        if (st->backend == MF_BACKEND_VT_FRC) backend_str = "vtfrc";
        else if (st->backend == MF_BACKEND_AUTO) backend_str = "auto";
        else if (st->backend == MF_BACKEND_BLEND) backend_str = "blend";

        const char *fps_mode_str = "display";
        if (st->fps_mode == MF_FPS_MODE_FIXED) fps_mode_str = "fixed";
        else if (st->fps_mode == MF_FPS_MODE_DOUBLE) fps_mode_str = "double";

        char json[1024];
        snprintf(json, sizeof(json),
                 "{\n"
                 "  \"seq\": %llu,\n"
                 "  \"enabled\": %s,\n"
                 "  \"fps_mode\": \"%s\",\n"
                 "  \"max_fps_cap\": %.2f,\n"
                 "  \"preset\": \"%s\",\n"
                 "  \"backend\": \"%s\",\n"
                 "  \"quality\": %.3f,\n"
                 "  \"guard\": %.3f,\n"
                 "  \"smoothness\": %.3f,\n"
                 "  \"scene\": %d,\n"
                 "  \"dedup\": %d,\n"
                 "  \"static_lock\": %d,\n"
                 "  \"letterbox\": %d,\n"
                 "  \"governor\": %d,\n"
                 "  \"debug_osd\": %d\n"
                 "}\n",
                 (unsigned long long)st->config_seq,
                 st->enabled ? "true" : "false",
                 fps_mode_str,
                 st->max_fps_cap,
                 preset_str,
                 backend_str,
                 st->quality,
                 st->artifact_guard,
                 st->smoothness,
                 st->scene_detect ? 1 : 0,
                 st->dedup ? 1 : 0,
                 st->static_lock ? 1 : 0,
                 st->letterbox_guard ? 1 : 0,
                 st->governor ? 1 : 0,
                 st->debug_osd ? 1 : 0);

        NSString *content = [NSString stringWithUTF8String:json];
        std::string dir1 = get_ipc_dir();
        NSString *path1 = [NSString stringWithFormat:@"%s/live_config.json", dir1.c_str()];
        [content writeToFile:path1 atomically:YES encoding:NSUTF8StringEncoding error:nil];

        const char *home = getenv("HOME");
        if (home) {
            NSString *pluginDir = [NSString stringWithFormat:@"%s/Library/Application Support/com.colliderli.iina/plugins/io.github.pseudoomer.macframe.iinaplugin", home];
            if ([[NSFileManager defaultManager] fileExistsAtPath:pluginDir]) {
                NSString *path2 = [pluginDir stringByAppendingPathComponent:@"live_config.json"];
                [content writeToFile:path2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        return 0;
    }
}

} // extern "C"
