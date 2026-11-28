# MacFrame Architecture

## Overview

MacFrame is split into four decoupled layers connected via zero-latency `mmap` shared memory (`~/Library/Application Support/MacFrame/ipc_state.bin`):

1. **`MacFrame.app` (`app/MacFrameApp.swift`)**: Standalone, self-contained native macOS GUI application (SwiftUI + AppKit + `MenuBarExtra`) for enabling/disabling interpolation in IINA, configuring the frame rate cap (`60 / 90 / 120 / 144 / 240 fps`) and target mode, tuning smoothness and artifact repair sliders in real time, monitoring live GPU telemetry, and one-click installing/restoring IINA. It embeds the installer scripts, IINA plugin, and prebuilt dylibs inside `Contents/Resources/` so it continues to work even after the downloaded archive folder is deleted.
2. **`libmacframe.dylib` (`engine/`)**: Standalone Objective-C++20 + Metal Shading Language (MSL) interpolation engine with a strict, versioned C ABI (`engine/include/macframe/macframe.h`), shared-memory IPC layer (`engine/include/macframe/mf_ipc.h`), and in-process libmpv controller (`engine/src/mf_autohook.mm`).
   - Hot-reloads smoothness, artifact repair, preset, backend, and feature guards on every frame when `ipc_state->config_seq` increments.
   - `mf_autohook.mm` hooks IINA's Mach-O GOT entries for `libmpv` so MacFrame automatically attaches `@macframe:lavfi=[macframe=...]` without requiring manual filter setup or IINA plugins. When MacFrame is disabled, it snapshots and restores the user's original `hwdec`, `video-sync`, and `interpolation` properties so IINA runs 100% natively.
3. **`vf_macframe.c` (`ffmpeg/`)**: Thin FFmpeg `libavfilter` hardware-aware filter (`FF_FILTER_FLAG_HWFRAME_AWARE`) that autoloads `libmacframe.dylib` via `dlopen`, passes `AV_PIX_FMT_VIDEOTOOLBOX` (`CVPixelBufferRef`) frames zero-copy, enforces `max_fps_cap`, and immediately switches to zero-overhead passthrough when `ipc_state->enabled == 0`.
4. **`MacFrame.iinaplugin` (`iina-plugin/`)**: Lightweight optional IINA JavaScript companion plugin that adds a menu shortcut to open `MacFrame.app` and an on-screen live HUD (`Cmd+Shift+O`).

## Why Single-Dylib `libavfilter` Injection?

IINA 1.4.3 ships with `libmpv.2.dylib` (mpv 0.38.0) compiled **without** VapourSynth (`vf_vapoursynth` is absent) and **with** `AV_PIX_FMT_VIDEOTOOLBOX` hardware interop enabled in `f_lavfi.c`. By building FFmpeg 7.0.1's `libavfilter.10.dylib` with the exact configure flags embedded in IINA's binary and linking directly against IINA's bundled sibling libraries (`libavutil.59.dylib`, `libavcodec.61.dylib`, etc.), MacFrame:

- Requires **zero external dependencies** at runtime (no Homebrew, no Python, no VapourSynth, no Xcode Command Line Tools).
- Preserves **100% zero-copy GPU execution** (`videotoolbox[nv12]` / `videotoolbox[p010]`).
- Allows hot-swapping `libmacframe.dylib` when upgrading the algorithm without rebuilding FFmpeg.
