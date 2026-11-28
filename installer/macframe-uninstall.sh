#!/usr/bin/env bash
set -euo pipefail

TARGET_APP="${1:-/Applications/IINA.app}"
if [[ ! -d "${TARGET_APP}/Contents/Frameworks" ]]; then
    echo "[ERROR] IINA app bundle not found at: ${TARGET_APP}"
    exit 1
fi

IINA_VER="$(defaults read "${TARGET_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
BACKUP_DIR="${HOME}/Library/Application Support/MacFrame/backup/${IINA_VER}"
FW_DIR="${TARGET_APP}/Contents/Frameworks"

echo "=== MacFrame Uninstaller (Target: ${TARGET_APP}, Version: ${IINA_VER}) ==="

PLIST_PATH="${HOME}/Library/LaunchAgents/io.github.pseudoomer.macframe.autoinject.plist"
if [[ -f "${PLIST_PATH}" ]]; then
    launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    rm -f "${PLIST_PATH}"
    echo "Removed auto-reinject LaunchAgent."
fi
rm -f "${HOME}/Library/Application Support/MacFrame/auto-reinject.sh"

if [[ ! -f "${BACKUP_DIR}/libavfilter.10.dylib.orig" ]]; then
    if [[ ! -f "${FW_DIR}/libmacframe.dylib" ]]; then
        echo "IINA does not appear to have MacFrame injected, and no backup is needed."
        exit 0
    fi
    echo "[ERROR] Backup not found at ${BACKUP_DIR}/libavfilter.10.dylib.orig"
    echo "Please reinstall official IINA from https://iina.io to restore original binaries."
    exit 1
fi

if [[ ! -w "${FW_DIR}" ]]; then
    echo "[ERROR] No write permission to ${FW_DIR}"
    exit 1
fi

echo "Restoring original IINA binaries and Developer ID signature..."
cp -pf "${BACKUP_DIR}/libavfilter.10.dylib.orig" "${FW_DIR}/libavfilter.10.dylib"
if [[ -f "${BACKUP_DIR}/IINA.orig" ]]; then
    cp -pf "${BACKUP_DIR}/IINA.orig" "${TARGET_APP}/Contents/MacOS/IINA"
    cp -pf "${BACKUP_DIR}/iina-cli.orig" "${TARGET_APP}/Contents/MacOS/iina-cli"
    cp -pf "${BACKUP_DIR}/iina-plugin.orig" "${TARGET_APP}/Contents/MacOS/iina-plugin"
fi
if [[ -d "${BACKUP_DIR}/_CodeSignature.orig" ]]; then
    rm -rf "${TARGET_APP}/Contents/_CodeSignature"
    cp -Rp "${BACKUP_DIR}/_CodeSignature.orig" "${TARGET_APP}/Contents/_CodeSignature"
fi
rm -f "${FW_DIR}/libmacframe.dylib" "${FW_DIR}/libmacframe.1.dylib" "${FW_DIR}/libmacframe.1.0.0.dylib"

PLUGIN_DST="${HOME}/Library/Application Support/com.colliderli.iina/plugins/io.github.pseudoomer.macframe.iinaplugin"
if [[ -d "${PLUGIN_DST}" ]]; then
    rm -rf "${PLUGIN_DST}"
    echo "Removed plugin ${PLUGIN_DST}"
fi

ORIG_SHA="$(awk '{print $1}' "${BACKUP_DIR}/sha256.txt")"
RESTORED_SHA="$(shasum -a 256 "${FW_DIR}/libavfilter.10.dylib" | awk '{print $1}')"
if [[ "${ORIG_SHA}" != "${RESTORED_SHA}" ]]; then
    echo "[ERROR] SHA-256 mismatch after restore!"
    exit 1
fi
codesign --verify --deep --strict "${TARGET_APP}"
echo "  [OK] Original libavfilter.10.dylib & original Apple Developer ID signature restored byte-for-byte (SHA-256: ${RESTORED_SHA:0:16}...)."

RUNNING_PID="$(pgrep -f "${TARGET_APP}/Contents/MacOS/IINA" | head -n 1 || true)"
if [[ -n "${RUNNING_PID}" ]]; then
    echo "Note: IINA is currently running (PID ${RUNNING_PID}). Restart IINA to unload MacFrame completely."
fi

echo "=== MacFrame Uninstallation Complete ==="
