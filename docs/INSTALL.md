# Installation & Uninstallation Guide

## Requirements
- **macOS 15.0+** on Apple Silicon (**M1 / M2 / M3 / M4**)
  - *Note*: The `vtfrc` ML backend requires macOS 15.4+; the default `mflow` Metal backend works on all Apple Silicon macOS versions.
- **IINA 1.4.x** (bundled with FFmpeg 7.0.x `libavfilter.10.dylib`).

## Installing into IINA

1. **Using the One-Click Script**:
   Double-click `Install MacFrame.command` or run:
   ```bash
   ./installer/macframe-install.sh /Applications/IINA.app
   ```
2. **What the Installer Does**:
   - Verifies ABI & symbol compatibility (`scripts/verify-abi.sh`) against your IINA bundle before touching any file.
   - Backs up your original `libavfilter.10.dylib`, `IINA` binary, and `_CodeSignature` to `~/Library/Application Support/MacFrame/backup/<IINA_VERSION>/` with SHA-256 verification.
   - Installs `libmacframe.dylib` and the patched universal `libavfilter.10.dylib` into `IINA.app/Contents/Frameworks/`.
   - Ad-hoc signs the updated binaries so macOS Gatekeeper / launch validation succeeds.
   - Installs `io.github.pseudoomer.macframe.iinaplugin` into `~/Library/Application Support/com.colliderli.iina/plugins/`.

## Uninstalling

Double-click `Uninstall MacFrame.command` or run:
```bash
./installer/macframe-uninstall.sh /Applications/IINA.app
```
This restores the original `libavfilter.10.dylib` and IINA's original Apple Developer ID signature byte-for-byte.
