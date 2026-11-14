# MacFrame Architecture

## Overview

MacFrame is split into three decoupled layers:

1. **`libmacframe.dylib` (`engine/`)**: Standalone Objective-C++20 + Metal Shading Language (MSL) interpolation engine with a strict, versioned C ABI (`engine/include/macframe/macframe.h`).
2. **`vf_macframe.c` (`ffmpeg/`)**: Thin (~600 lines) FFmpeg `libavfilter` hardware-aware filter (`FF_FILTER_FLAG_HWFRAME_AWARE`) that dynamically loads `libmacframe.dylib` via `dlopen` and passes `AV_PIX_FMT_VIDEOTOOLBOX` (`CVPixelBufferRef`) frames zero-copy.
3. **`MacFrame.iinaplugin` (`iina-plugin/`)**: IINA JavaScript plugin providing menu items, hotkeys (`⌘⇧M`, `⌘⇧1/2/3`, `⌘⇧O`), automatic refresh-rate matching (`display-fps`), and a live WebView HUD overlay.

## Why Single-Dylib `libavfilter` Injection?

IINA 1.4.3 ships with `libmpv.2.dylib` (mpv 0.38.0) compiled **without** VapourSynth (`vf_vapoursynth` is absent) and **with** `AV_PIX_FMT_VIDEOTOOLBOX` hardware interop enabled in `f_lavfi.c`. By building FFmpeg 7.0.1's `libavfilter.10.dylib` with the exact configure flags embedded in IINA's binary and linking directly against IINA's bundled sibling libraries (`libavutil.59.dylib`, `libavcodec.61.dylib`, etc.), MacFrame:

- Requires **zero external dependencies** at runtime (no Homebrew, no Python, no VapourSynth).
- Preserves **100% zero-copy GPU execution** (`videotoolbox[nv12]` / `videotoolbox[p010]`).
- Allows hot-swapping `libmacframe.dylib` when upgrading the algorithm without rebuilding FFmpeg.
