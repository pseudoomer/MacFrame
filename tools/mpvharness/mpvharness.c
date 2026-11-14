// SPDX-License-Identifier: GPL-3.0-or-later
// mpvharness: headless libmpv player used to test MacFrame inside IINA's own
// libmpv/FFmpeg build. Renders through the OpenGL render API into an offscreen
// FBO (the same path IINA uses), so VideoToolbox hwdec + interop are active.
//
// usage: mpvharness [options] <file>
//   --lib <path/to/libmpv.2.dylib>  (default: ~/Applications/IINA-MacFrame.app)
//   --opt key=value                 set any mpv option (repeatable)
//   --frames N                      stop after N rendered frames (default 300)
//   --log LEVEL                     mpv log level for printed messages (default warn)
//   --grep STR                      also print log lines containing STR (any level)
//   --dump N:path.ppm               write rendered frame N to a PPM file
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "client.h"
#include "render_gl.h"

// --- dynamically loaded libmpv API ------------------------------------------
#define MPV_FUNCS(X)                                                           \
    X(mpv_create) X(mpv_initialize) X(mpv_set_option_string)                   \
    X(mpv_command) X(mpv_wait_event) X(mpv_get_property_string)                \
    X(mpv_free) X(mpv_request_log_messages) X(mpv_terminate_destroy)           \
    X(mpv_render_context_create) X(mpv_render_context_set_update_callback)     \
    X(mpv_render_context_update) X(mpv_render_context_render)                  \
    X(mpv_render_context_report_swap) X(mpv_render_context_free)               \
    X(mpv_error_string) X(mpv_get_property)
#define DECL(n) static __typeof__(n) *p_##n;
MPV_FUNCS(DECL)

static void *gl_proc(void *ctx, const char *name) {
    static void *lib;
    (void)ctx;
    if (!lib)
        lib = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
    return dlsym(lib, name);
}

static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int wakeup_pending;

static void on_update(void *ctx) {
    (void)ctx;
    pthread_mutex_lock(&mtx);
    wakeup_pending = 1;
    pthread_cond_signal(&cond);
    pthread_mutex_unlock(&mtx);
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void print_prop(mpv_handle *h, const char *name) {
    char *v = p_mpv_get_property_string(h, name);
    printf("  %-28s %s\n", name, v ? v : "(unavailable)");
    if (v) p_mpv_free(v);
}

static void dump_ppm(const char *path, int w, int h) {
    unsigned char *buf = malloc((size_t)w * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (int y = h - 1; y >= 0; y--)
            for (int x = 0; x < w; x++)
                fwrite(buf + ((size_t)y * w + x) * 4, 1, 3, f);
        fclose(f);
    }
    free(buf);
}

int main(int argc, char **argv) {
    const char *lib = NULL, *file = NULL, *loglevel = "warn", *grep = NULL;
    const char *opts[128];
    int nopts = 0, max_frames = 300, dump_n = -1;
    const char *dump_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--lib") && i + 1 < argc) lib = argv[++i];
        else if (!strcmp(argv[i], "--opt") && i + 1 < argc && nopts < 128) opts[nopts++] = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) loglevel = argv[++i];
        else if (!strcmp(argv[i], "--grep") && i + 1 < argc) grep = argv[++i];
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) {
            char *s = argv[++i];
            dump_n = atoi(s);
            dump_path = strchr(s, ':') ? strchr(s, ':') + 1 : NULL;
        } else file = argv[i];
    }
    if (!file) {
        fprintf(stderr, "usage: %s [--lib libmpv] [--opt k=v]... [--frames N] file\n", argv[0]);
        return 2;
    }
    if (!lib) {
        lib = "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib";
    }
    void *h_lib = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
    if (!h_lib) {
        fprintf(stderr, "dlopen %s failed: %s\n", lib, dlerror());
        return 1;
    }
#define LOAD(n)                                                                \
    if (!(p_##n = dlsym(h_lib, #n))) { fprintf(stderr, "missing %s\n", #n); return 1; }
    MPV_FUNCS(LOAD)

    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0};
    CGLPixelFormatObj pix;
    GLint npix;
    CGLContextObj cgl;
    if (CGLChoosePixelFormat(attrs, &pix, &npix) || CGLCreateContext(pix, NULL, &cgl)) {
        fprintf(stderr, "CGL context creation failed\n");
        return 1;
    }
    CGLSetCurrentContext(cgl);

    mpv_handle *mpv = p_mpv_create();
    p_mpv_set_option_string(mpv, "vo", "libmpv");
    p_mpv_set_option_string(mpv, "ao", "null");
    p_mpv_set_option_string(mpv, "hwdec", "videotoolbox");
    p_mpv_set_option_string(mpv, "keep-open", "no");
    for (int i = 0; i < nopts; i++) {
        char key[256];
        const char *eq = strchr(opts[i], '=');
        if (!eq) continue;
        snprintf(key, sizeof key, "%.*s", (int)(eq - opts[i]), opts[i]);
        int r = p_mpv_set_option_string(mpv, key, eq + 1);
        if (r < 0) fprintf(stderr, "option %s: %s\n", opts[i], p_mpv_error_string(r));
    }
    if (p_mpv_initialize(mpv) < 0) {
        fprintf(stderr, "mpv_initialize failed\n");
        return 1;
    }
    p_mpv_request_log_messages(mpv, grep ? "v" : loglevel);

    mpv_opengl_init_params gl_init = {.get_proc_address = gl_proc};
    int adv = 1;
    mpv_render_param rparams[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &adv},
        {0}};
    mpv_render_context *rctx;
    if (p_mpv_render_context_create(&rctx, mpv, rparams) < 0) {
        fprintf(stderr, "render context creation failed\n");
        return 1;
    }
    p_mpv_render_context_set_update_callback(rctx, on_update, NULL);

    const int W = 1920, H = 1080;
    GLuint fbo, tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);

    const char *cmd[] = {"loadfile", file, NULL};
    p_mpv_command(mpv, cmd);

    int frames = 0, done = 0, printed_info = 0;
    double t_first = 0, t_last = 0;
    while (!done) {
        // drain events
        for (;;) {
            mpv_event *ev = p_mpv_wait_event(mpv, 0);
            if (ev->event_id == MPV_EVENT_NONE) break;
            if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
                mpv_event_log_message *m = ev->data;
                int show = 0;
                if (grep && (strstr(m->text, grep) || strstr(m->prefix, grep))) show = 1;
                if (m->log_level <= MPV_LOG_LEVEL_WARN) show = 1;
                if (show) printf("[%s] %s: %s", m->level, m->prefix, m->text);
            } else if (ev->event_id == MPV_EVENT_END_FILE ||
                       ev->event_id == MPV_EVENT_SHUTDOWN) {
                done = 1;
            }
        }
        if (done) break;
        pthread_mutex_lock(&mtx);
        while (!wakeup_pending) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 20 * 1000 * 1000;
            if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&cond, &mtx, &ts);
            break;
        }
        wakeup_pending = 0;
        pthread_mutex_unlock(&mtx);

        uint64_t flags = p_mpv_render_context_update(rctx);
        if (flags & MPV_RENDER_UPDATE_FRAME) {
            mpv_opengl_fbo f = {.fbo = (int)fbo, .w = W, .h = H};
            int flip = 0;
            mpv_render_param rp[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &f},
                                     {MPV_RENDER_PARAM_FLIP_Y, &flip}, {0}};
            p_mpv_render_context_render(rctx, rp);
            glFinish();
            p_mpv_render_context_report_swap(rctx);
            double t = now();
            if (!frames) t_first = t;
            t_last = t;
            if (frames == dump_n && dump_path) dump_ppm(dump_path, W, H);
            frames++;
            if (frames == 30 && !printed_info) {
                printed_info = 1;
                printf("--- stream info after 30 frames ---\n");
                print_prop(mpv, "hwdec-current");
                print_prop(mpv, "video-params/pixelformat");
                print_prop(mpv, "video-params/hw-pixelformat");
                print_prop(mpv, "video-dec-params/pixelformat");
                print_prop(mpv, "video-out-params/pixelformat");
                print_prop(mpv, "video-out-params/hw-pixelformat");
                print_prop(mpv, "container-fps");
                print_prop(mpv, "estimated-vf-fps");
                print_prop(mpv, "vf");
            }
            if (frames >= max_frames) done = 1;
        }
    }
    printf("--- result ---\n");
    print_prop(mpv, "estimated-vf-fps");
    print_prop(mpv, "frame-drop-count");
    print_prop(mpv, "decoder-frame-drop-count");
    double dt = t_last - t_first;
    printf("  rendered_frames              %d\n", frames);
    printf("  wall_seconds                 %.3f\n", dt);
    printf("  render_fps                   %.2f\n", dt > 0 ? (frames - 1) / dt : 0.0);

    p_mpv_render_context_free(rctx);
    p_mpv_terminate_destroy(mpv);
    return 0;
}
