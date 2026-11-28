# Installation & Uninstallation Guide

## Requirements
- **macOS 15.0+** on Apple Silicon (**M1 / M2 / M3 / M4**)
  - *Note*: The `vtfrc` ML backend requires macOS 15.4+; the default `mflow` Metal backend works on macOS 15.0+.
- **IINA 1.5.x** (bundled with FFmpeg 9.0.x `libavfilter.12.dylib`).
- Prebuilt releases require **no Homebrew, no Python, no VapourSynth, and no Xcode Command Line Tools**.

## Installing into IINA (Out-of-Box Release)

### Option A: DMG Installer (Recommended)
1. Download the latest **`MacFrame-v*-macos.dmg`** from GitHub Releases and double-click to mount it.
2. Drag **`MacFrame.app`** into **`Applications`**.
3. Open **`MacFrame.app`** — because it embeds the prebuilt engine, patched `libavfilter.12.dylib`, and installer scripts, it automatically injects MacFrame into `/Applications/IINA.app` and enables the background auto-reinject watcher on launch.
   - *First-launch Gatekeeper note*: If macOS warns that the app is not notarized, run `xattr -dr com.apple.quarantine /Applications/MacFrame.app` once in Terminal or click **Open Anyway** in **System Settings → Privacy & Security**.

### Option B: ZIP Archive (CLI & Script Installer)
1. Download and extract `MacFrame-v*-macos.zip` from GitHub Releases.
2. Double-click **`Install MacFrame.command`** (or run `./installer/macframe-install.sh /Applications/IINA.app`).
3. **What the Installer Does**:
   - Checks ABI & FFmpeg library compatibility (`scripts/verify-abi.sh`) against your IINA bundle before modifying anything.
   - Backs up your original `libavfilter.12.dylib`, `IINA` binaries, and `_CodeSignature` to `~/Library/Application Support/MacFrame/backup/<IINA_VERSION>/` with SHA-256 verification.
   - Installs `libmacframe.dylib` and the patched universal `libavfilter.12.dylib` into `IINA.app/Contents/Frameworks/`.
   - Ad-hoc signs the updated binaries so macOS launch validation succeeds.
   - Installs the optional HUD companion plugin (`io.github.pseudoomer.macframe.iinaplugin`) into IINA's plugins folder.
   - Copies the self-contained **`MacFrame.app`** into `/Applications/MacFrame.app` (or `~/Applications/MacFrame.app`) and registers a background `LaunchAgent` that uses `/Applications/MacFrame.app` to auto-reinject when IINA updates.
   - After installation, you can safely delete the extracted release folder.

## Building from Source

```bash
./scripts/build-ffmpeg-iina.sh /Applications/IINA.app
./scripts/build-engine.sh
./installer/macframe-install.sh /Applications/IINA.app
```

## Uninstalling

Double-click **`Uninstall MacFrame.command`**, click **Restore Original IINA** inside `MacFrame.app`, or run:
```bash
./installer/macframe-uninstall.sh /Applications/IINA.app
```
This removes the auto-reinject watcher and restores the original `libavfilter.12.dylib` and IINA's original Apple Developer ID signature byte-for-byte.
