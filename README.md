# MacFrame

[中文文档 (README.zh-CN.md)](./README.zh-CN.md) | [Architecture](./docs/ARCHITECTURE.md) | [Algorithm & Artifact Guard](./docs/ALGORITHM.md) | [Install Guide](./docs/INSTALL.md) | [Tuning](./docs/TUNING.md) | [FAQ](./docs/FAQ.md)

**MacFrame** is an open-source (**GPL-3.0**) real-time video frame interpolation engine and **IINA** plugin built natively for **Apple Silicon (M1 / M2 / M3 / M4)** using **Metal** and **VideoToolbox**.

Designed as a zero-copy, lightweight, native alternative to SVP 4 Pro on macOS, MacFrame eliminates the need for Python, VapourSynth, or CPU copy-back (`hwdec=auto-copy`) by operating directly on `CVPixelBuffer` (`IOSurface`) hardware frames inside IINA's `libavfilter` pipeline.

---

## Key Features

- **Standalone Native Control App (`MacFrame.app`) & Zero-Intrusion Native Fallback**:
  - Dedicated SwiftUI + AppKit desktop control center (with main window + `MenuBarExtra` status bar item) to toggle frame interpolation on/off, choose **Frame Rate Caps (`60 / 90 / 120 / 144 / 240 fps`)** and **Target Modes**, adjust **Smoothness** and **Artifact Repair (`artifact_guard`)** sliders in real time without rebuilding the filter graph, and inspect live GPU telemetry.
  - **Strict Native IINA Behavior When Disabled**: Turning off interpolation in `MacFrame.app` leaves IINA running 100% with the user's original settings (`hwdec`, `video-sync`, `interpolation`, and custom `vf` filters are preserved or restored, while `vf_macframe` immediately enters zero-overhead passthrough).
- **100% Zero-Copy Apple Silicon Pipeline**: Reads VideoToolbox hardware-decoded `NV12` / `P010` (10-bit HDR) frames directly via `CVMetalTextureCache` and outputs `IOSurface`-backed hardware frames straight to IINA's renderer.
- **Hybrid Dual Backends**:
  - **MF-Flow (Default)**: In-house Metal compute optical flow engine combining a 6-level Gaussian pyramid, 3D Recursive Search (3DRS), zero-mean + gradient-weighted patch matching, bilateral vector median filtering, and Dense Inverse Search (DIS) sub-pixel Lucas-Kanade refinement.
  - **Apple VT-FRC**: Hardware-accelerated Machine Learning frame rate conversion via `VTFrameProcessor` (`VTFrameRateConversionConfiguration`, macOS 15.4+), wrapped with MacFrame's Unified Artifact Guard.
- **Unified Artifact Mitigation Layer**:
  1. **Occlusion-Aware Bidirectional Synthesis**: Forward-backward flow consistency check derives per-pixel visibility maps $(v_0, v_1)$ so occluded backgrounds never ghost or halo around moving foreground objects.
  2. **Scene Cut Detection**: Dual Luma-histogram L1 distance + block SAD detector suppresses interpolation across cuts (zero scene-cut ghosting).
  3. **Anime 2s/3s Cadence Reconstruction (`dedup`)**: Collapses duplicate drawings in 24fps animation (12fps/8fps effective cadence) onto a uniform 120Hz timeline while snapping low-confidence regions to crisp source frames so ink lines never double.
  4. **Static HUD / Logo / Subtitle Lock (`static_lock`)**: Locks stationary high-contrast overlays (channel logos, sports scoreboards, game HUDs, burned-in subtitles) to zero motion so fast background pans never tear them.
  5. **Letterbox Boundary Guard (`letterbox`)**: Auto-detects cinemascope black bars and clamps vectors at bar borders.
  6. **Adaptive Performance Governor (`Q4..Q0`)**: Monitors per-frame GPU time against the frame budget (e.g. `8.33 ms` at 120Hz) and dynamically adjusts internal quality tiers so playback never stutters.

---

## Benchmarks (Apple M4, macOS, 1080p)

| Test Suite | Metric | Linear Blend | Apple VT-FRC | **MacFrame MF-Flow** |
|---|---|---|---|---|
| Synthetic Sub-Pixel Pan | Optical Flow EPE | — | — | **0.021 – 0.066 px** |
| Synthetic Sub-Pixel Pan | PSNR / SSIM | 44.79 dB / 0.9968 | 54.74 dB / 0.9990 | **56.46 dB / 0.9992** |
| Occlusion + Static HUD Logo | Logo Region PSNR | 31.20 dB | 48.10 dB | **55.65 dB** |
| Letterbox Cinema Bars | Bar Region PSNR | 99.00 dB | 99.00 dB | **99.00 dB** |
| Real Video (*Big Buck Bunny* 1080p60 Held-Out) | Mean PSNR / SSIM | 44.98 dB / 0.9866 | 47.15 dB / 0.9868 | **47.72 dB / 0.9869** |
| 1080p 24fps → 120fps Throughput | Effective Output FPS | >1000 fps | ~105 fps | **468.1 fps (2.47 ms/frame)** |

---

## Quick Start

### 1. Build & Install into IINA
```bash
# Build core Metal engine, CLI benchmark, and patched libavfilter.10.dylib
./scripts/build-engine.sh
./scripts/build-ffmpeg-iina.sh

# Install into IINA (automatically backs up original files and installs MacFrame.iinaplugin)
./installer/macframe-install.sh /Applications/IINA.app
```
Or double-click **`Install MacFrame.command`** in Finder.

### 2. Use in IINA
- Open any video in IINA.
- From the menu bar, choose **Plugin → MacFrame**:
  - **⌘⇧M**: Enable / Disable MacFrame Interpolation
  - **⌘⇧1**: Preset: Film / Cinema (24p Smooth)
  - **⌘⇧2**: Preset: Anime (2s/3s Dedup + Line Guard)
  - **⌘⇧3**: Preset: Sports / 120Hz High-Speed
  - **⌘⇧O**: Toggle Live Performance & Confidence HUD

### 3. Uninstall / Restore Original IINA
```bash
./installer/macframe-uninstall.sh /Applications/IINA.app
```
Or double-click **`Uninstall MacFrame.command`**. Restores the byte-identical original `libavfilter.10.dylib` and IINA's original Apple Developer ID signature.

---

## License

MacFrame is released under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**, matching IINA and mpv. See [LICENSE](./LICENSE).
