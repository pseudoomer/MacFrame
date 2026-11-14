// SPDX-License-Identifier: GPL-3.0-or-later
#include "macframe/macframe.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

static CVPixelBufferRef create_nv12_buffer(int w, int h) {
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

static inline uint8_t float_to_video_y(float v) {
    v = std::clamp(v, 0.0f, 1.0f);
    return static_cast<uint8_t>(std::round(16.0f + v * 219.0f));
}

// Smooth band-limited procedural texture so sub-pixel ground-truth at any float (x, y) is exact
static float procedural_bg(float x, float y) {
    float v = 0.50f
            + 0.22f * std::sin(x * 0.045f) * std::cos(y * 0.040f)
            + 0.14f * std::sin((x + y) * 0.085f)
            + 0.09f * std::cos((x - y * 1.3f) * 0.12f);
    return std::clamp(v, 0.05f, 0.95f);
}

static void fill_synthetic_pan(CVPixelBufferRef pb, float shift_x, float shift_y, float gain = 1.0f) {
    CVPixelBufferLockBaseAddress(pb, 0);
    int w = (int)CVPixelBufferGetWidthOfPlane(pb, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t stride_y = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *base_y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);

    for (int y = 0; y < h; ++y) {
        uint8_t *row = base_y + y * stride_y;
        for (int x = 0; x < w; ++x) {
            float val = procedural_bg(float(x) - shift_x, float(y) - shift_y) * gain;
            row[x] = float_to_video_y(val);
        }
    }

    int uw = (int)CVPixelBufferGetWidthOfPlane(pb, 1);
    int uh = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *base_uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < uh; ++y) {
        std::memset(base_uv + y * stride_uv, 128, uw * 2);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// Moving foreground disc occluding a moving background + optional static HUD logo & letterbox
static void fill_synthetic_scene(CVPixelBufferRef pb,
                                 float t,
                                 bool with_logo,
                                 bool with_letterbox) {
    CVPixelBufferLockBaseAddress(pb, 0);
    int w = (int)CVPixelBufferGetWidthOfPlane(pb, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t stride_y = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *base_y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);

    float bg_dx = 4.0f * t;
    float bg_dy = -2.0f * t;
    float fg_cx = w * 0.45f - 8.0f * t;
    float fg_cy = h * 0.52f + 4.0f * t;
    float fg_r  = std::min(w, h) * 0.16f;

    int bar_h = with_letterbox ? (h / 8) : 0;

    for (int y = 0; y < h; ++y) {
        uint8_t *row = base_y + y * stride_y;
        if (with_letterbox && (y < bar_h || y >= h - bar_h)) {
            std::memset(row, 16, w);
            continue;
        }
        for (int x = 0; x < w; ++x) {
            float val = procedural_bg(float(x) - bg_dx, float(y) - bg_dy);
            float dx = float(x) - fg_cx;
            float dy = float(y) - fg_cy;
            float dist = std::sqrt(dx * dx + dy * dy);
            if (dist < fg_r) {
                float fg_val = 0.65f + 0.25f * std::cos(dx * 0.15f) * std::sin(dy * 0.15f);
                float edge_w = std::clamp(fg_r - dist, 0.0f, 1.0f);
                val = val * (1.0f - edge_w) + fg_val * edge_w;
            }
            // High-contrast static HUD logo box in top-right corner
            if (with_logo && x >= w - 160 && x < w - 40 && y >= 40 && y < 100) {
                bool checker = (((x / 8) + (y / 8)) & 1) == 0;
                val = checker ? 0.92f : 0.12f;
            }
            row[x] = float_to_video_y(val);
        }
    }

    int uw = (int)CVPixelBufferGetWidthOfPlane(pb, 1);
    int uh = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *base_uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < uh; ++y) {
        std::memset(base_uv + y * stride_uv, 128, uw * 2);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

struct QualityMetrics {
    double psnr_db = 0.0;
    double ssim = 0.0;
};

static QualityMetrics compute_luma_metrics(CVPixelBufferRef a,
                                           CVPixelBufferRef b,
                                           int x0 = 0, int y0 = 0,
                                           int x1 = -1, int y1 = -1) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);

    int w = (int)CVPixelBufferGetWidthOfPlane(a, 0);
    int h = (int)CVPixelBufferGetHeightOfPlane(a, 0);
    if (x1 < 0) x1 = w;
    if (y1 < 0) y1 = h;

    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);

    double mse_sum = 0.0;
    double ssim_sum = 0.0;
    size_t ssim_blocks = 0;
    size_t count = 0;

    for (int y = y0; y < y1; ++y) {
        const uint8_t *ra = pa + y * sa;
        const uint8_t *rb = pb + y * sb;
        for (int x = x0; x < x1; ++x) {
            double d = double(ra[x]) - double(rb[x]);
            mse_sum += d * d;
            count++;
        }
    }

    // 8x8 block SSIM
    const double C1 = (0.01 * 255.0) * (0.01 * 255.0);
    const double C2 = (0.03 * 255.0) * (0.03 * 255.0);
    for (int by = y0; by + 8 <= y1; by += 8) {
        for (int bx = x0; bx + 8 <= x1; bx += 8) {
            double ma = 0.0, mb = 0.0;
            for (int dy = 0; dy < 8; ++dy) {
                for (int dx = 0; dx < 8; ++dx) {
                    ma += pa[(by + dy) * sa + (bx + dx)];
                    mb += pb[(by + dy) * sb + (bx + dx)];
                }
            }
            ma /= 64.0;
            mb /= 64.0;
            double va = 0.0, vb = 0.0, cov = 0.0;
            for (int dy = 0; dy < 8; ++dy) {
                for (int dx = 0; dx < 8; ++dx) {
                    double da = pa[(by + dy) * sa + (bx + dx)] - ma;
                    double db = pb[(by + dy) * sb + (bx + dx)] - mb;
                    va  += da * da;
                    vb  += db * db;
                    cov += da * db;
                }
            }
            va /= 63.0;
            vb /= 63.0;
            cov /= 63.0;
            double num = (2.0 * ma * mb + C1) * (2.0 * cov + C2);
            double den = (ma * ma + mb * mb + C1) * (va + vb + C2);
            ssim_sum += num / den;
            ssim_blocks++;
        }
    }

    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);

    double mse = mse_sum / std::max<size_t>(count, 1);
    double psnr = (mse <= 1e-6) ? 99.0 : (10.0 * std::log10((255.0 * 255.0) / mse));
    double ssim = ssim_blocks ? (ssim_sum / double(ssim_blocks)) : 1.0;
    return {psnr, ssim};
}

static int cmd_synth() {
    const int W = 960, H = 540;
    printf("=== MacFrame Synthetic Ground-Truth Benchmark (%dx%d) ===\n", W, H);

    // 1. Sub-pixel translation EPE & PSNR (Blend vs MF-Flow vs VT-FRC)
    const float gt_dx = 4.5f;
    const float gt_dy = -2.25f;
    CVPixelBufferRef f0 = create_nv12_buffer(W, H);
    CVPixelBufferRef f1 = create_nv12_buffer(W, H);
    CVPixelBufferRef f_gt = create_nv12_buffer(W, H);
    fill_synthetic_pan(f0, 0.0f, 0.0f);
    fill_synthetic_pan(f1, gt_dx, gt_dy);
    fill_synthetic_pan(f_gt, gt_dx * 0.5f, gt_dy * 0.5f);

    auto eval_backend_pan = [&](mf_backend backend, const char *name, double &out_psnr, double &out_epe) {
        mf_config cfg;
        mf_config_init_default(&cfg, MF_PRESET_FILM);
        cfg.width = W;
        cfg.height = H;
        cfg.backend = backend;
        cfg.governor = 0;
        cfg.quality = 1.0f;

        char err[256]{};
        mf_engine *eng = mf_engine_create(&cfg, err, sizeof(err));
        if (!eng) {
            printf("  [FAIL] %s init failed: %s\n", name, err);
            return;
        }
        std::vector<float> flow(W * H * 2, 0.0f);
        CVPixelBufferRef out = nullptr;
        mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out,
                                   (backend == MF_BACKEND_MFLOW) ? flow.data() : nullptr);

        QualityMetrics qm = compute_luma_metrics(out, f_gt, 24, 24, W - 24, H - 24);
        out_psnr = qm.psnr_db;
        out_epe = 0.0;
        if (backend == MF_BACKEND_MFLOW) {
            double epe_sum = 0.0;
            size_t cnt = 0;
            for (int y = 24; y < H - 24; ++y) {
                for (int x = 24; x < W - 24; ++x) {
                    size_t idx = (size_t(y) * W + x) * 2;
                    // Flow F01 maps x in I0 to x + F01 in I1; since I1(x) = I0(x - d), F01 == (gt_dx, gt_dy)
                    double ex = flow[idx + 0] - gt_dx;
                    double ey = flow[idx + 1] - gt_dy;
                    epe_sum += std::hypot(ex, ey);
                    cnt++;
                }
            }
            out_epe = epe_sum / std::max<size_t>(cnt, 1);
            printf("  %-12s Pan PSNR: %6.2f dB | SSIM: %.4f | Flow EPE: %.3f px\n",
                   name, qm.psnr_db, qm.ssim, out_epe);
        } else {
            printf("  %-12s Pan PSNR: %6.2f dB | SSIM: %.4f\n",
                   name, qm.psnr_db, qm.ssim);
        }
        CVPixelBufferRelease(out);
        mf_engine_destroy(eng);
    };

    double psnr_blend = 0, epe_blend = 0;
    double psnr_mflow = 0, epe_mflow = 0;
    double psnr_vtfrc = 0, epe_vtfrc = 0;
    eval_backend_pan(MF_BACKEND_BLEND,  "Blend",   psnr_blend, epe_blend);
    eval_backend_pan(MF_BACKEND_MFLOW,  "MF-Flow", psnr_mflow, epe_mflow);
    eval_backend_pan(MF_BACKEND_VT_FRC, "VT-FRC",  psnr_vtfrc, epe_vtfrc);

    // 2. Occlusion + Static Logo + Letterbox test
    mf_config cfg;
    mf_config_init_default(&cfg, MF_PRESET_FILM);
    cfg.width = W;
    cfg.height = H;
    cfg.backend = MF_BACKEND_MFLOW;
    cfg.governor = 0;
    mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);

    // Warm up static logo mask across 4 frames so static_lock engages
    for (int i = 0; i < 4; ++i) {
        fill_synthetic_scene(f0, float(i), true, true);
        fill_synthetic_scene(f1, float(i + 1), true, true);
        CVPixelBufferRef tmp = nullptr;
        mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &tmp, nullptr);
        if (tmp) CVPixelBufferRelease(tmp);
    }

    fill_synthetic_scene(f0, 4.0f, true, true);
    fill_synthetic_scene(f1, 5.0f, true, true);
    fill_synthetic_scene(f_gt, 4.5f, true, true);
    CVPixelBufferRef out_occ = nullptr;
    mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out_occ, nullptr);

    QualityMetrics occ_all  = compute_luma_metrics(out_occ, f_gt, 16, H / 8, W - 16, H - H / 8);
    QualityMetrics occ_logo = compute_luma_metrics(out_occ, f_gt, W - 160, 40, W - 40, 100);
    QualityMetrics occ_bar  = compute_luma_metrics(out_occ, f_gt, 0, 0, W, H / 8 - 4);
    printf("  MF-Flow Occlusion Scene PSNR: %6.2f dB | Static Logo PSNR: %6.2f dB | Letterbox Bar PSNR: %6.2f dB\n",
           occ_all.psnr_db, occ_logo.psnr_db, occ_bar.psnr_db);
    CVPixelBufferRelease(out_occ);

    // 3. Brightness fade resilience test
    fill_synthetic_pan(f0, 0.0f, 0.0f, 0.85f);
    fill_synthetic_pan(f1, gt_dx, gt_dy, 1.00f);
    fill_synthetic_pan(f_gt, gt_dx * 0.5f, gt_dy * 0.5f, 0.925f);
    CVPixelBufferRef out_fade = nullptr;
    mf_engine_interpolate_pair(eng, f0, f1, 0.5f, &out_fade, nullptr);
    QualityMetrics qm_fade = compute_luma_metrics(out_fade, f_gt, 24, 24, W - 24, H - 24);
    printf("  MF-Flow Fade+Pan Scene  PSNR: %6.2f dB | SSIM: %.4f\n", qm_fade.psnr_db, qm_fade.ssim);
    CVPixelBufferRelease(out_fade);
    mf_engine_destroy(eng);

    CVPixelBufferRelease(f0);
    CVPixelBufferRelease(f1);
    CVPixelBufferRelease(f_gt);

    bool ok = (epe_mflow < 0.50) && ((psnr_mflow - psnr_blend) >= 4.0) && (occ_logo.psnr_db >= 45.0);
    printf("=== Synthetic Suite Result: %s ===\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static std::vector<CVPixelBufferRef> decode_clip_frames(const char *path, int max_frames, double &out_fps) {
    std::vector<CVPixelBufferRef> frames;
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return frames;
        AVAssetTrack *track = tracks[0];
        out_fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 60.0;

        NSError *err = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (!reader) return frames;

        NSDictionary *out_settings = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        AVAssetReaderTrackOutput *output =
            [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:out_settings];
        [reader addOutput:output];
        [reader startReading];

        while ((int)frames.size() < max_frames) {
            CMSampleBufferRef sb = [output copyNextSampleBuffer];
            if (!sb) break;
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (pb) {
                frames.push_back(CVPixelBufferRetain(pb));
            }
            CFRelease(sb);
        }
    }
    return frames;
}

static mf_backend parse_backend(const std::string &s) {
    if (s == "vtfrc" || s == "vt") return MF_BACKEND_VT_FRC;
    if (s == "blend") return MF_BACKEND_BLEND;
    if (s == "auto") return MF_BACKEND_AUTO;
    return MF_BACKEND_MFLOW;
}

static mf_preset parse_preset(const std::string &s) {
    if (s == "anime") return MF_PRESET_ANIME;
    if (s == "sports") return MF_PRESET_SPORTS;
    return MF_PRESET_FILM;
}

static int cmd_eval(const char *path, const std::string &backend_str, const std::string &preset_str, int max_pairs) {
    double fps = 60.0;
    auto frames = decode_clip_frames(path, max_pairs * 2 + 1, fps);
    if (frames.size() < 3) {
        fprintf(stderr, "Failed to decode enough frames from %s\n", path);
        return 1;
    }
    int w = (int)CVPixelBufferGetWidth(frames[0]);
    int h = (int)CVPixelBufferGetHeight(frames[0]);

    mf_config cfg;
    mf_config_init_default(&cfg, parse_preset(preset_str));
    cfg.width = w;
    cfg.height = h;
    cfg.backend = parse_backend(backend_str);
    cfg.governor = 0;

    mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);
    if (!eng) return 1;

    double psnr_sum = 0.0, ssim_sum = 0.0;
    int pairs = 0;
    auto t0 = std::chrono::steady_clock::now();

    for (size_t i = 0; i + 2 < frames.size(); i += 2) {
        CVPixelBufferRef out = nullptr;
        mf_engine_interpolate_pair(eng, frames[i], frames[i + 2], 0.5f, &out, nullptr);
        if (out) {
            QualityMetrics qm = compute_luma_metrics(out, frames[i + 1]);
            psnr_sum += qm.psnr_db;
            ssim_sum += qm.ssim;
            pairs++;
            CVPixelBufferRelease(out);
        }
    }

    auto t1 = std::chrono::steady_clock::now();
    double ms_per_frame = std::chrono::duration<double, std::milli>(t1 - t0).count() / std::max(pairs, 1);

    printf("Eval [%s | preset=%s] on %s (%dx%d, %d held-out frames):\n",
           backend_str.c_str(), preset_str.c_str(), path, w, h, pairs);
    printf("  Mean PSNR: %6.2f dB | Mean SSIM: %.4f | Avg Time: %.2f ms/frame\n",
           psnr_sum / std::max(pairs, 1), ssim_sum / std::max(pairs, 1), ms_per_frame);

    for (auto pb : frames) CVPixelBufferRelease(pb);
    mf_engine_destroy(eng);
    return 0;
}

static int cmd_perf(const char *path, double out_fps, const std::string &backend_str, const std::string &preset_str, int in_count) {
    double src_fps = 24.0;
    auto frames = decode_clip_frames(path, in_count, src_fps);
    if (frames.size() < 4) {
        fprintf(stderr, "Failed to decode frames from %s\n", path);
        return 1;
    }
    // Simulate 24fps input -> out_fps (e.g. 120fps = 5x interpolation)
    src_fps = 24.0;
    int w = (int)CVPixelBufferGetWidth(frames[0]);
    int h = (int)CVPixelBufferGetHeight(frames[0]);

    mf_config cfg;
    mf_config_init_default(&cfg, parse_preset(preset_str));
    cfg.width = w;
    cfg.height = h;
    cfg.in_fps = src_fps;
    cfg.out_fps = out_fps;
    cfg.backend = parse_backend(backend_str);
    cfg.governor = 1;

    mf_engine *eng = mf_engine_create(&cfg, nullptr, 0);
    if (!eng) return 1;

    auto t0 = std::chrono::steady_clock::now();
    int total_out = 0;
    for (size_t i = 0; i < frames.size(); ++i) {
        mf_engine_push(eng, frames[i], double(i) / src_fps);
        CVPixelBufferRef out = nullptr;
        double pts = 0.0;
        while (mf_engine_pull(eng, &out, &pts) == MF_OK) {
            total_out++;
            CVPixelBufferRelease(out);
        }
    }
    mf_engine_flush(eng);
    CVPixelBufferRef out = nullptr;
    double pts = 0.0;
    while (mf_engine_pull(eng, &out, &pts) == MF_OK) {
        total_out++;
        CVPixelBufferRelease(out);
    }
    auto t1 = std::chrono::steady_clock::now();
    double wall_s = std::chrono::duration<double>(t1 - t0).count();

    mf_stats st{};
    mf_engine_get_stats(eng, &st);

    printf("Perf [%s | preset=%s | %.0f->%.0ffps] on %s (%dx%d):\n",
           backend_str.c_str(), preset_str.c_str(), src_fps, out_fps, path, w, h);
    printf("  Frames In: %llu | Frames Out: %d | Effective Throughput: %.1f fps (wall %.2fs)\n",
           st.frames_in, total_out, total_out / std::max(wall_s, 1e-6), wall_s);
    printf("  GPU Synth Avg: %.2f ms | P99: %.2f ms | Final Tier: Q%d | Mean Conf: %.2f | Fallback: %.1f%%\n",
           st.gpu_time_ms_avg, st.gpu_time_ms_p99, st.current_tier,
           st.mean_confidence, st.fallback_ratio * 100.0f);

    for (auto pb : frames) CVPixelBufferRelease(pb);
    mf_engine_destroy(eng);
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("Usage:\n"
               "  mfbench synth\n"
               "  mfbench eval <video.mp4> [--backend mflow|vtfrc|blend] [--preset film|anime|sports] [--pairs N]\n"
               "  mfbench perf <video.mp4> [--fps 120] [--backend mflow|vtfrc] [--preset film|anime|sports] [--frames N]\n");
        return 1;
    }

    std::string sub = argv[1];
    if (sub == "synth") {
        return cmd_synth();
    }

    if (argc < 3) {
        fprintf(stderr, "Missing input video file path\n");
        return 1;
    }
    const char *path = argv[2];
    std::string backend = "mflow";
    std::string preset = "film";
    double fps = 120.0;
    int count = 40;

    for (int i = 3; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--backend" && i + 1 < argc) backend = argv[++i];
        else if (arg == "--preset" && i + 1 < argc) preset = argv[++i];
        else if (arg == "--fps" && i + 1 < argc) fps = std::stod(argv[++i]);
        else if ((arg == "--pairs" || arg == "--frames") && i + 1 < argc) count = std::stoi(argv[++i]);
    }

    if (sub == "eval") {
        return cmd_eval(path, backend, preset, count);
    } else if (sub == "perf") {
        return cmd_perf(path, fps, backend, preset, count);
    }

    fprintf(stderr, "Unknown command: %s\n", sub.c_str());
    return 1;
}
