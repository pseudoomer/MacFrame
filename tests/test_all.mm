// SPDX-License-Identifier: GPL-3.0-or-later
#include "macframe/macframe.h"
#include "macframe/mf_ipc.h"
#include "mf_governor.hpp"
#include "mf_timeline.hpp"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace macframe;

#define REQUIRE(cond)                                                          \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", #cond, __FILE__, __LINE__);  \
            return 1;                                                          \
        }                                                                      \
    } while (0)

static CVPixelBufferRef make_nv12(int w, int h) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferRef pb = nullptr;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs, &pb);
    return pb;
}

static void draw_shifted_pattern(CVPixelBufferRef pb, float dx, float dy) {
    CVPixelBufferLockBaseAddress(pb, 0);
    int w = (int)CVPixelBufferGetWidthOfPlane(pb, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *py = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            float u = float(x) - dx;
            float v = float(y) - dy;
            float val = 0.50f
                      + 0.22f * std::sin(u * 0.045f) * std::cos(v * 0.040f)
                      + 0.14f * std::sin((u + v) * 0.085f)
                      + 0.09f * std::cos((u - v * 1.3f) * 0.12f);
            py[y * sy + x] = (uint8_t)std::clamp(std::round(16.0f + val * 219.0f), 16.0f, 235.0f);
        }
    }
    int uw = (int)CVPixelBufferGetWidthOfPlane(pb, 1);
    int uh = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t suv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *puv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < uh; ++y) std::memset(puv + y * suv, 128, uw * 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static void draw_flat_luma(CVPixelBufferRef pb, uint8_t y_val) {
    CVPixelBufferLockBaseAddress(pb, 0);
    int w = (int)CVPixelBufferGetWidthOfPlane(pb, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *py = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    for (int y = 0; y < h; ++y) std::memset(py + y * sy, y_val, w);
    int uw = (int)CVPixelBufferGetWidthOfPlane(pb, 1);
    int uh = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t suv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *puv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < uh; ++y) std::memset(puv + y * suv, 128, uw * 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static double calc_psnr(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidthOfPlane(a, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(a, 0);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);

    double mse = 0.0;
    size_t cnt = 0;
    for (int y = 20; y < h - 20; ++y) {
        for (int x = 20; x < w - 20; ++x) {
            double d = double(pa[y * sa + x]) - double(pb[y * sb + x]);
            mse += d * d;
            cnt++;
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    mse /= std::max<size_t>(cnt, 1);
    return (mse <= 1e-6) ? 99.0 : 10.0 * std::log10((255.0 * 255.0) / mse);
}

static int test_timeline_unit() {
    printf("[Test] Timeline 24->120fps, scene cut & anime 2s dedup...\n");
    {
        Timeline tl(120.0, false, true, 1.0f);
        tl.push({1, 0.0, false, false});
        tl.push({2, 1.0 / 24.0, false, false});
        int count = 0;
        while (tl.has_ready_output()) {
            auto t = tl.pop_output();
            if (count == 0) REQUIRE(t.mode == OutputMode::PassthroughF0);
            else REQUIRE(t.mode == OutputMode::Interpolate);
            count++;
        }
        REQUIRE(count == 5);
    }

    // Scene cut must never emit Interpolate mode
    {
        Timeline tl(120.0, false, true, 1.0f);
        tl.push({1, 0.0, false, false});
        tl.push({2, 1.0 / 24.0, false, true});
        REQUIRE(tl.scene_cuts() == 1);
        while (tl.has_ready_output()) {
            auto t = tl.pop_output();
            REQUIRE(t.mode != OutputMode::Interpolate);
        }
    }

    // Anime 2s duplicate collapsing: frame 2 is a duplicate of frame 1, frame 3 is new drawing
    {
        Timeline tl(120.0, true, true, 1.0f);
        tl.push({1, 0.0 / 24.0, false, false});
        tl.push({2, 1.0 / 24.0, true,  false}); // duplicate of frame 1
        REQUIRE(!tl.has_ready_output());        // waiting for lookahead frame 3
        tl.push({3, 2.0 / 24.0, false, false}); // new drawing!
        REQUIRE(tl.dedup_drops() == 1);
        int count = 0;
        while (tl.has_ready_output()) {
            auto t = tl.pop_output();
            REQUIRE(t.f0_id == 1);
            REQUIRE(t.f1_id == 3);
            count++;
        }
        REQUIRE(count == 10); // 2/24s at 120fps = 10 smoothly interpolated frames!
    }
    return 0;
}

static int test_governor_unit() {
    printf("[Test] Performance Governor step-down & hysteresis recovery...\n");
    Governor gov(120.0, 1.0f, true); // budget = 8.33ms
    REQUIRE(gov.current_tier() == 4);

    // 4 frames over budget -> step down to Q3
    for (int i = 0; i < 4; ++i) gov.record_gpu_time_ms(7.8);
    REQUIRE(gov.current_tier() == 3);

    // 4 more frames over budget -> step down to Q2
    for (int i = 0; i < 4; ++i) gov.record_gpu_time_ms(7.8);
    REQUIRE(gov.current_tier() == 2);

    // 24 fast frames under 40% budget -> step up to Q3
    for (int i = 0; i < 24; ++i) gov.record_gpu_time_ms(1.8);
    REQUIRE(gov.current_tier() == 3);
    return 0;
}

static int test_engine_gpu() {
    printf("[Test] GPU Engine EPE, PSNR, Scene Cut & VT-FRC...\n");
    const int W = 640, H = 360;
    CVPixelBufferRef f0 = make_nv12(W, H);
    CVPixelBufferRef f1 = make_nv12(W, H);
    CVPixelBufferRef fgt = make_nv12(W, H);

    draw_shifted_pattern(f0, 0.0f, 0.0f);
    draw_shifted_pattern(f1, 4.0f, -2.0f);
    draw_shifted_pattern(fgt, 2.0f, -1.0f);

    mf_config cfg;
    mf_config_init_default(&cfg, MF_PRESET_FILM);
    cfg.width = W;
    cfg.height = H;
    cfg.governor = 0;

    // 1. Blend baseline
    cfg.backend = MF_BACKEND_BLEND;
    mf_engine *eng_blend = mf_engine_create(&cfg, nullptr, 0);
    REQUIRE(eng_blend != nullptr);
    CVPixelBufferRef out_blend = nullptr;
    REQUIRE(mf_engine_interpolate_pair(eng_blend, f0, f1, 0.5f, &out_blend, nullptr) == MF_OK);
    double psnr_blend = calc_psnr(out_blend, fgt);
    CVPixelBufferRelease(out_blend);
    mf_engine_destroy(eng_blend);

    // 2. MF-Flow
    cfg.backend = MF_BACKEND_MFLOW;
    mf_engine *eng_mflow = mf_engine_create(&cfg, nullptr, 0);
    REQUIRE(eng_mflow != nullptr);
    std::vector<float> flow(W * H * 2, 0.0f);
    CVPixelBufferRef out_mflow = nullptr;
    REQUIRE(mf_engine_interpolate_pair(eng_mflow, f0, f1, 0.5f, &out_mflow, flow.data()) == MF_OK);
    double psnr_mflow = calc_psnr(out_mflow, fgt);
    CVPixelBufferRelease(out_mflow);

    double epe_sum = 0.0;
    size_t cnt = 0;
    for (int y = 24; y < H - 24; ++y) {
        for (int x = 24; x < W - 24; ++x) {
            size_t idx = (size_t(y) * W + x) * 2;
            epe_sum += std::hypot(flow[idx + 0] - 4.0, flow[idx + 1] - (-2.0));
            cnt++;
        }
    }
    double epe = epe_sum / std::max<size_t>(cnt, 1);
    printf("  GPU Test: Blend PSNR=%.2f dB, MF-Flow PSNR=%.2f dB (+%.2f dB), EPE=%.3f px\n",
           psnr_blend, psnr_mflow, psnr_mflow - psnr_blend, epe);
    REQUIRE(epe < 0.35);
    REQUIRE(psnr_mflow - psnr_blend >= 6.0);

    // 3. End-to-end Scene Cut detection on GPU
    mf_engine_reset(eng_mflow);
    draw_flat_luma(f0, 30);
    draw_flat_luma(f1, 220);
    REQUIRE(mf_engine_push(eng_mflow, f0, 0.0) == MF_OK);
    REQUIRE(mf_engine_push(eng_mflow, f1, 1.0 / 24.0) == MF_OK);
    mf_stats st{};
    mf_engine_get_stats(eng_mflow, &st);
    REQUIRE(st.scene_cuts == 1);
    mf_engine_destroy(eng_mflow);

    // 4. Apple VT-FRC backend test
    cfg.backend = MF_BACKEND_VT_FRC;
    draw_shifted_pattern(f0, 0.0f, 0.0f);
    draw_shifted_pattern(f1, 4.0f, -2.0f);
    mf_engine *eng_vt = mf_engine_create(&cfg, nullptr, 0);
    REQUIRE(eng_vt != nullptr);
    CVPixelBufferRef out_vt = nullptr;
    REQUIRE(mf_engine_interpolate_pair(eng_vt, f0, f1, 0.5f, &out_vt, nullptr) == MF_OK);
    double psnr_vt = calc_psnr(out_vt, fgt);
    printf("  GPU Test: VT-FRC PSNR=%.2f dB\n", psnr_vt);
    REQUIRE(psnr_vt > psnr_blend + 3.0);
    CVPixelBufferRelease(out_vt);
    mf_engine_destroy(eng_vt);

    CVPixelBufferRelease(f0);
    CVPixelBufferRelease(f1);
    CVPixelBufferRelease(fgt);
    return 0;
}

static int test_ipc_sync() {
    printf("[4/4] Testing Shared-Memory IPC & Live Engine Config Sync...\n");
    mf_ipc_state *ipc = mf_ipc_open();
    REQUIRE(ipc != nullptr);
    REQUIRE(ipc->magic == MF_IPC_MAGIC);
    REQUIRE(ipc->version == MF_IPC_VERSION);

    // Save state
    mf_ipc_state saved = *ipc;

    ipc->enabled = 1;
    ipc->max_fps_cap = 90.0;
    ipc->smoothness = 0.75f;
    ipc->artifact_guard = 0.85f;
    ipc->config_seq++;
    mf_ipc_write_plugin_json(ipc);

    mf_config cfg;
    mf_config_init_default(&cfg, MF_PRESET_FILM);
    cfg.width = 320;
    cfg.height = 180;
    mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);
    REQUIRE(eng != nullptr);
    mf_engine_enable_ipc(eng, 1);

    CVPixelBufferRef f0 = make_nv12(320, 180);
    CVPixelBufferRef f1 = make_nv12(320, 180);
    draw_shifted_pattern(f0, 0.0f, 0.0f);
    draw_shifted_pattern(f1, 2.0f, 0.0f);

    CVPixelBufferRef out = nullptr;
    REQUIRE(mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out, nullptr) == MF_OK);
    CVPixelBufferRelease(out);

    REQUIRE(ipc->active_pid > 0);
    REQUIRE(ipc->video_width == 320);
    REQUIRE(ipc->video_height == 180);
    REQUIRE(ipc->heartbeat_ms > 0);

    mf_engine_destroy(eng);
    CVPixelBufferRelease(f0);
    CVPixelBufferRelease(f1);

    // Restore clean defaults
    *ipc = saved;
    ipc->enabled = 1;
    ipc->max_fps_cap = 120.0;
    ipc->config_seq++;
    mf_ipc_write_plugin_json(ipc);
    mf_ipc_close(ipc);
    return 0;
}

static CVPixelBufferRef make_p010_hdr(int w, int h) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferRef pb = nullptr;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs, &pb);
    if (pb) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        uint8_t md[24] = {0x35,0xC0,0x3D,0xE8, 0x1D,0x4C,0x05,0xDC, 0x8A,0x48,0x39,0x08, 0x3D,0x13,0x40,0x42, 0x00,0x98,0x96,0x80, 0x00,0x00,0x00,0x32};
        CFDataRef md_ref = CFDataCreate(kCFAllocatorDefault, md, sizeof(md));
        CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, md_ref, kCVAttachmentMode_ShouldPropagate);
        CFRelease(md_ref);
        uint8_t cll[4] = {0x03,0xE8, 0x01,0x90};
        CFDataRef cll_ref = CFDataCreate(kCFAllocatorDefault, cll, sizeof(cll));
        CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey, cll_ref, kCVAttachmentMode_ShouldPropagate);
        CFRelease(cll_ref);
    }
    return pb;
}

static void draw_shifted_p010(CVPixelBufferRef pb, float dx, float dy) {
    CVPixelBufferLockBaseAddress(pb, 0);
    int w = (int)CVPixelBufferGetWidthOfPlane(pb, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *py = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    for (int y = 0; y < h; ++y) {
        uint16_t *row = (uint16_t *)(py + y * sy);
        for (int x = 0; x < w; ++x) {
            float u = float(x) - dx;
            float v = float(y) - dy;
            float val = 0.50f
                      + 0.22f * std::sin(u * 0.045f) * std::cos(v * 0.040f)
                      + 0.14f * std::sin((u + v) * 0.085f);
            int q10 = std::clamp(int(std::round(64.0f + val * 876.0f)), 64, 940);
            row[x] = uint16_t(q10 << 6);
        }
    }
    int uw = (int)CVPixelBufferGetWidthOfPlane(pb, 1);
    int uh = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t suv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *puv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < uh; ++y) {
        uint16_t *row = (uint16_t *)(puv + y * suv);
        for (int x = 0; x < uw * 2; ++x) row[x] = uint16_t(512 << 6);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static double calc_psnr_p010(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidthOfPlane(a, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(a, 0);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    double mse = 0.0;
    size_t cnt = 0;
    for (int y = 20; y < h - 20; ++y) {
        const uint16_t *ra = (const uint16_t *)(pa + y * sa);
        const uint16_t *rb = (const uint16_t *)(pb + y * sb);
        for (int x = 20; x < w - 20; ++x) {
            double d = double(ra[x] >> 6) - double(rb[x] >> 6);
            mse += d * d;
            cnt++;
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    mse /= std::max<size_t>(cnt, 1);
    return (mse <= 1e-6) ? 99.0 : 10.0 * std::log10((1023.0 * 1023.0) / mse);
}

static int test_hdr_10bit_passthrough() {
    printf("[5/6] Testing 10-bit P010 BT.2020 PQ HDR metadata passthrough...\n");
    const int W = 320, H = 180;
    CVPixelBufferRef f0  = make_p010_hdr(W, H);
    CVPixelBufferRef f1  = make_p010_hdr(W, H);
    CVPixelBufferRef fgt = make_p010_hdr(W, H);
    draw_shifted_p010(f0, 0.0f, 0.0f);
    draw_shifted_p010(f1, 4.0f, 0.0f);
    draw_shifted_p010(fgt, 2.0f, 0.0f);

    mf_backend backends[3] = { MF_BACKEND_MFLOW, MF_BACKEND_VT_FRC, MF_BACKEND_BLEND };
    for (int bi = 0; bi < 3; ++bi) {
        mf_config cfg;
        mf_config_init_default(&cfg, MF_PRESET_FILM);
        cfg.width = W;
        cfg.height = H;
        cfg.cv_pixel_format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        cfg.backend = backends[bi];
        cfg.governor = 0;

        mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);
        REQUIRE(eng != nullptr);
        CVPixelBufferRef out = nullptr;
        REQUIRE(mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out, nullptr) == MF_OK);
        REQUIRE(out != nullptr);

        CFStringRef matrix = (CFStringRef)CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nullptr);
        CFStringRef trc    = (CFStringRef)CVBufferCopyAttachment(out, kCVImageBufferTransferFunctionKey, nullptr);
        CFDataRef   md     = (CFDataRef)CVBufferCopyAttachment(out, kCVImageBufferMasteringDisplayColorVolumeKey, nullptr);
        CFDataRef   cll    = (CFDataRef)CVBufferCopyAttachment(out, kCVImageBufferContentLightLevelInfoKey, nullptr);
        REQUIRE(matrix && CFStringCompare(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020, 0) == kCFCompareEqualTo);
        REQUIRE(trc && CFStringCompare(trc, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo);
        REQUIRE(md && CFDataGetLength(md) == 24);
        REQUIRE(cll && CFDataGetLength(cll) == 4);
        if (matrix) CFRelease(matrix);
        if (trc) CFRelease(trc);
        if (md) CFRelease(md);
        if (cll) CFRelease(cll);

        mf_stats st{};
        mf_engine_get_stats(eng, &st);
        REQUIRE(st.is_hdr == 1);

        if (backends[bi] != MF_BACKEND_BLEND) {
            double psnr = calc_psnr_p010(out, fgt);
            printf("  P010 HDR backend=%d PSNR=%.2f dB\n", (int)backends[bi], psnr);
            REQUIRE(psnr >= 48.0);
        }
        CVPixelBufferRelease(out);
        mf_engine_destroy(eng);
    }

    CVPixelBufferRelease(f0);
    CVPixelBufferRelease(f1);
    CVPixelBufferRelease(fgt);
    return 0;
}

static double calc_psnr_region(CVPixelBufferRef a, CVPixelBufferRef b, int x0, int y0, int x1, int y1) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    double mse = 0.0;
    size_t cnt = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            double d = double(pa[y * sa + x]) - double(pb[y * sb + x]);
            mse += d * d;
            cnt++;
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    mse /= std::max<size_t>(cnt, 1);
    return (mse <= 1e-6) ? 99.0 : 10.0 * std::log10((255.0 * 255.0) / mse);
}

static int test_ab_split_modes() {
    printf("[6/6] Testing A/B 4-way split modes (LR/RL/TB/BT)...\n");
    const int W = 320, H = 180;
    CVPixelBufferRef f0  = make_nv12(W, H);
    CVPixelBufferRef f1  = make_nv12(W, H);
    CVPixelBufferRef fgt = make_nv12(W, H);
    draw_shifted_pattern(f0, 0.0f, 0.0f);
    draw_shifted_pattern(f1, 6.0f, 0.0f);
    draw_shifted_pattern(fgt, 3.0f, 0.0f);

    for (int mode = 1; mode <= 4; ++mode) {
        mf_config cfg;
        mf_config_init_default(&cfg, MF_PRESET_FILM);
        cfg.width = W;
        cfg.height = H;
        cfg.ab_mode = mode;
        cfg.ab_split = 0.5f;
        cfg.governor = 0;
        mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);
        REQUIRE(eng != nullptr);
        CVPixelBufferRef out = nullptr;
        REQUIRE(mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out, nullptr) == MF_OK);

        double psnr_orig = 0.0, psnr_interp = 0.0;
        if (mode == 1) { // Left Orig, Right Interp
            psnr_orig   = calc_psnr_region(out, f0,  16, 48, W/2 - 24, H - 16);
            psnr_interp = calc_psnr_region(out, fgt, W/2 + 24, 48, W - 16, H - 16);
        } else if (mode == 2) { // Right Orig, Left Interp
            psnr_interp = calc_psnr_region(out, fgt, 16, 48, W/2 - 24, H - 16);
            psnr_orig   = calc_psnr_region(out, f0,  W/2 + 24, 48, W - 16, H - 16);
        } else if (mode == 3) { // Top Orig, Bottom Interp
            psnr_orig   = calc_psnr_region(out, f0,  48, 16, W - 16, H/2 - 24);
            psnr_interp = calc_psnr_region(out, fgt, 48, H/2 + 24, W - 16, H - 16);
        } else { // Bottom Orig, Top Interp
            psnr_interp = calc_psnr_region(out, fgt, 48, 16, W - 16, H/2 - 24);
            psnr_orig   = calc_psnr_region(out, f0,  48, H/2 + 24, W - 16, H - 16);
        }
        printf("  A/B mode %d: orig_side=%.2f dB, interp_side=%.2f dB\n", mode, psnr_orig, psnr_interp);
        REQUIRE(psnr_orig > 60.0);
        REQUIRE(psnr_interp > 48.0);

        CVPixelBufferRelease(out);
        mf_engine_destroy(eng);
    }

    CVPixelBufferRelease(f0);
    CVPixelBufferRelease(f1);
    CVPixelBufferRelease(fgt);
    return 0;
}

int main() {
    if (test_timeline_unit() != 0) return 1;
    if (test_governor_unit() != 0) return 1;
    if (test_engine_gpu() != 0) return 1;
    if (test_ipc_sync() != 0) return 1;
    if (test_hdr_10bit_passthrough() != 0) return 1;
    if (test_ab_split_modes() != 0) return 1;
    printf("ALL TESTS PASSED.\n");
    return 0;
}
