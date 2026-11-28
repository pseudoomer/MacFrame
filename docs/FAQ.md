# Frequently Asked Questions (FAQ)

### Q: Why does MacFrame replace `libavfilter.12.dylib` inside IINA?
Standard releases of IINA ship with an internal `libmpv` compiled without VapourSynth and without runtime native video filter plugins. By adding the `macframe` filter to a drop-in build of IINA's exact FFmpeg 9.0.1 `libavfilter.12.dylib`, MacFrame receives `AV_PIX_FMT_VIDEOTOOLBOX` hardware frames directly on the GPU with zero CPU copy-back and zero external runtime dependencies.

### Q: Do I need to set `hwdec=auto-copy` like SVP 4 Mac?
**No!** Keep IINA's default hardware decoding (`hwdec=videotoolbox` / `auto`). MacFrame operates directly on `CVPixelBuffer` hardware surfaces on the GPU.

### Q: What happens when IINA updates?
By default, MacFrame installs a lightweight `LaunchAgent` that watches `/Applications/IINA.app/Contents/Frameworks` and automatically re-injects the engine using the self-contained payload inside `/Applications/MacFrame.app` whenever IINA updates (you can safely delete the downloaded zip folder after installation). You can also toggle **Auto-Reinject on Update** or click **Inject into IINA** manually inside `MacFrame.app`.

### Q: Do I need Xcode Command Line Tools or Homebrew to install a Release build?
**No.** Prebuilt Release archives include both `libmacframe.dylib` and the patched universal `libavfilter.12.dylib`, and only rely on built-in macOS utilities.

### Q: Which backend should I choose: `mflow` or `vtfrc`?
- **`mflow` (Default)** is recommended for all real-time 120Hz playback: it runs in ~2.4 ms/frame at 1080p on Apple M4 (~468 fps throughput), has zero YUV↔RGB conversion overhead, and supports anime 2s/3s deduplication and preset tuning.
- **`vtfrc`** uses Apple's VideoToolbox ML optical flow & frame rate conversion engine (`VTFrameRateConversionConfiguration`) combined with MacFrame's Artifact Guard. It requires macOS 15.4+ and is great for 60fps cinema playback or offline transcoding.
