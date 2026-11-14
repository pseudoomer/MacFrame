#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_APP="${1:-/Applications/IINA.app}"

if [[ ! -d "${TARGET_APP}/Contents/Frameworks" ]]; then
    echo "[ERROR] IINA app bundle not found at: ${TARGET_APP}"
    exit 1
fi

IINA_VER="$(defaults read "${TARGET_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
echo "=== MacFrame Installer for IINA (Target: ${TARGET_APP}, Version: ${IINA_VER}) ==="

FW_DIR="${TARGET_APP}/Contents/Frameworks"
if [[ ! -f "${FW_DIR}/libavfilter.10.dylib" || ! -f "${FW_DIR}/libavutil.59.dylib" ]]; then
    echo "[ERROR] Unsupported IINA FFmpeg ABI in ${FW_DIR} (expected libavfilter.10.dylib / FFmpeg 7.0.x)."
    exit 1
fi

if [[ ! -f "${ROOT_DIR}/build/libmacframe.dylib" ]]; then
    echo "Building MacFrame Metal engine..."
    "${ROOT_DIR}/scripts/build-engine.sh"
fi
if [[ ! -f "${ROOT_DIR}/dist/libavfilter.10.dylib" ]]; then
    echo "Building patched FFmpeg 7.0.1 libavfilter.10.dylib..."
    "${ROOT_DIR}/scripts/build-ffmpeg-iina.sh" "${TARGET_APP}"
fi

"${ROOT_DIR}/scripts/verify-abi.sh" "${ROOT_DIR}/dist/libavfilter.10.dylib" "${TARGET_APP}"

# 1. Backup original files before modifying signature (never overwrite existing pristine backup)
BACKUP_DIR="${HOME}/Library/Application Support/MacFrame/backup/${IINA_VER}"
mkdir -p "${BACKUP_DIR}"
if [[ ! -f "${BACKUP_DIR}/libavfilter.10.dylib.orig" ]]; then
    echo "Backing up original IINA files to ${BACKUP_DIR}..."
    cp -p "${FW_DIR}/libavfilter.10.dylib" "${BACKUP_DIR}/libavfilter.10.dylib.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/IINA" "${BACKUP_DIR}/IINA.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/iina-cli" "${BACKUP_DIR}/iina-cli.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/iina-plugin" "${BACKUP_DIR}/iina-plugin.orig"
    cp -Rp "${TARGET_APP}/Contents/_CodeSignature" "${BACKUP_DIR}/_CodeSignature.orig"
    shasum -a 256 "${BACKUP_DIR}/libavfilter.10.dylib.orig" > "${BACKUP_DIR}/sha256.txt"
else
    echo "Existing pristine backup found at ${BACKUP_DIR}"
fi

# 2. Install libmacframe.dylib and patched libavfilter.10.dylib into IINA Frameworks
echo "Installing libmacframe.dylib and patched libavfilter.10.dylib..."
cp -f "${ROOT_DIR}/build/libmacframe.1.0.0.dylib" "${FW_DIR}/libmacframe.dylib"
install_name_tool -id "@rpath/libmacframe.dylib" "${FW_DIR}/libmacframe.dylib"
ln -sf "libmacframe.dylib" "${FW_DIR}/libmacframe.1.dylib"
cp -f "${ROOT_DIR}/dist/libavfilter.10.dylib" "${FW_DIR}/libavfilter.10.dylib"

# 3. Re-sign modified binaries and top-level bundle (without touching unmodified Frameworks)
echo "Re-signing ${TARGET_APP} (ad-hoc signature)..."
codesign --force -s - "${FW_DIR}/libmacframe.dylib"
codesign --force -s - "${FW_DIR}/libavfilter.10.dylib"
codesign --force -s - "${TARGET_APP}/Contents/MacOS/iina-cli"
codesign --force -s - "${TARGET_APP}/Contents/MacOS/iina-plugin"
codesign --force -s - "${TARGET_APP}"
codesign --verify "${TARGET_APP}"
echo "  [OK] codesign verification passed."

# 4. Install MacFrame IINA Plugin
PLUGIN_DST_DIR="${HOME}/Library/Application Support/com.colliderli.iina/plugins"
PLUGIN_DST="${PLUGIN_DST_DIR}/io.github.pseudoomer.macframe.iinaplugin"
mkdir -p "${PLUGIN_DST_DIR}"
rm -rf "${PLUGIN_DST}"
cp -R "${ROOT_DIR}/iina-plugin/MacFrame.iinaplugin" "${PLUGIN_DST}"
defaults write com.colliderli.iina iinaEnablePluginSystem -bool true 2>/dev/null || true
echo "  [OK] Installed IINA plugin to ${PLUGIN_DST}"

# 5. Install standalone MacFrame.app control center
if [[ -d "${ROOT_DIR}/build/MacFrame.app" ]]; then
    APP_DST_DIR="$(dirname "${TARGET_APP}")"
    if [[ ! -w "${APP_DST_DIR}" ]]; then
        APP_DST_DIR="${HOME}/Applications"
        mkdir -p "${APP_DST_DIR}"
    fi
    rm -rf "${APP_DST_DIR}/MacFrame.app"
    cp -R "${ROOT_DIR}/build/MacFrame.app" "${APP_DST_DIR}/MacFrame.app"
    xattr -cr "${APP_DST_DIR}/MacFrame.app" 2>/dev/null || true
    codesign --force --sign - "${APP_DST_DIR}/MacFrame.app/Contents/Frameworks/libmacframe.1.0.0.dylib"
    codesign --force --sign - "${APP_DST_DIR}/MacFrame.app"
    echo "  [OK] Installed standalone control app to ${APP_DST_DIR}/MacFrame.app"
fi

echo "=== MacFrame Installation Complete! ==="
echo "Launch MacFrame.app to control frame interpolation, frame rate cap, and repair features."
