#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKIP_APP_COPY=0
TARGET_APP="/Applications/IINA.app"

for arg in "$@"; do
    case "${arg}" in
        --skip-app-copy)
            SKIP_APP_COPY=1
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-app-copy] [/Applications/IINA.app]"
            exit 0
            ;;
        *)
            TARGET_APP="${arg}"
            ;;
    esac
done

if [[ ! -d "${TARGET_APP}/Contents/Frameworks" ]]; then
    echo "[ERROR] IINA app bundle not found at: ${TARGET_APP}"
    echo "Please install IINA (https://iina.io) to /Applications/IINA.app first."
    exit 1
fi

if [[ ! -w "${TARGET_APP}/Contents/Frameworks" ]]; then
    echo "[ERROR] No write permission to ${TARGET_APP}/Contents/Frameworks"
    exit 1
fi

IINA_VER="$(defaults read "${TARGET_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
echo "=== MacFrame Installer for IINA (Target: ${TARGET_APP}, Version: ${IINA_VER}) ==="

FW_DIR="${TARGET_APP}/Contents/Frameworks"
if [[ ! -f "${FW_DIR}/libavfilter.12.dylib" || ! -f "${FW_DIR}/libavutil.61.dylib" ]]; then
    echo "[ERROR] Unsupported IINA FFmpeg ABI in ${FW_DIR} (expected IINA 1.5.x / libavfilter.12.dylib). Please update IINA to the latest version."
    exit 1
fi

# Locate prebuilt libmacframe.dylib (dist -> build -> embedded Frameworks -> build from source)
LIBMACFRAME_SRC=""
for cand in \
    "${ROOT_DIR}/dist/libmacframe.dylib" \
    "${ROOT_DIR}/dist/libmacframe.1.dylib" \
    "${ROOT_DIR}/build/libmacframe.1.0.0.dylib" \
    "${ROOT_DIR}/../Frameworks/libmacframe.1.0.0.dylib"; do
    if [[ -f "${cand}" ]]; then
        LIBMACFRAME_SRC="${cand}"
        break
    fi
done

if [[ -z "${LIBMACFRAME_SRC}" ]]; then
    if [[ -x "${ROOT_DIR}/scripts/build-engine.sh" ]]; then
        echo "Building MacFrame Metal engine from source..."
        "${ROOT_DIR}/scripts/build-engine.sh"
        LIBMACFRAME_SRC="${ROOT_DIR}/dist/libmacframe.dylib"
    else
        echo "[ERROR] Prebuilt libmacframe.dylib not found under ${ROOT_DIR}."
        exit 1
    fi
fi

# Locate prebuilt patched libavfilter.12.dylib (dist -> build from source)
AVFILTER_SRC=""
if [[ -f "${ROOT_DIR}/dist/libavfilter.12.dylib" ]]; then
    AVFILTER_SRC="${ROOT_DIR}/dist/libavfilter.12.dylib"
elif [[ -x "${ROOT_DIR}/scripts/build-ffmpeg-iina.sh" ]]; then
    echo "Building patched FFmpeg 9.0.1 libavfilter.12.dylib from source..."
    "${ROOT_DIR}/scripts/build-ffmpeg-iina.sh" "${TARGET_APP}"
    AVFILTER_SRC="${ROOT_DIR}/dist/libavfilter.12.dylib"
else
    echo "[ERROR] Prebuilt dist/libavfilter.12.dylib not found under ${ROOT_DIR}."
    echo "Please download a complete MacFrame release archive or build from source."
    exit 1
fi

# Verify ABI compatibility before touching IINA
if [[ -x "${ROOT_DIR}/scripts/verify-abi.sh" ]]; then
    "${ROOT_DIR}/scripts/verify-abi.sh" "${AVFILTER_SRC}" "${TARGET_APP}"
fi

# 1. Backup original files before modifying signature (never overwrite existing pristine backup)
BACKUP_DIR="${HOME}/Library/Application Support/MacFrame/backup/${IINA_VER}"
mkdir -p "${BACKUP_DIR}"
if [[ ! -f "${BACKUP_DIR}/libavfilter.12.dylib.orig" ]]; then
    echo "Backing up original IINA files to ${BACKUP_DIR}..."
    cp -p "${FW_DIR}/libavfilter.12.dylib" "${BACKUP_DIR}/libavfilter.12.dylib.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/IINA" "${BACKUP_DIR}/IINA.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/iina-cli" "${BACKUP_DIR}/iina-cli.orig"
    cp -p "${TARGET_APP}/Contents/MacOS/iina-plugin" "${BACKUP_DIR}/iina-plugin.orig"
    cp -Rp "${TARGET_APP}/Contents/_CodeSignature" "${BACKUP_DIR}/_CodeSignature.orig"
    shasum -a 256 "${BACKUP_DIR}/libavfilter.12.dylib.orig" > "${BACKUP_DIR}/sha256.txt"
else
    echo "Existing pristine backup found at ${BACKUP_DIR}"
fi

# 2. Install libmacframe.dylib and patched libavfilter.12.dylib into IINA Frameworks
echo "Installing libmacframe.dylib and patched libavfilter.12.dylib..."
cp -f "${LIBMACFRAME_SRC}" "${FW_DIR}/libmacframe.dylib"
chmod 755 "${FW_DIR}/libmacframe.dylib"
xattr -c "${FW_DIR}/libmacframe.dylib" 2>/dev/null || true
if xcode-select -p >/dev/null 2>&1; then
    CUR_ID="$(otool -D "${FW_DIR}/libmacframe.dylib" 2>/dev/null | tail -n 1 || true)"
    if [[ "${CUR_ID}" != "@rpath/libmacframe.dylib" ]]; then
        install_name_tool -id "@rpath/libmacframe.dylib" "${FW_DIR}/libmacframe.dylib"
    fi
fi
ln -sf "libmacframe.dylib" "${FW_DIR}/libmacframe.1.dylib"

cp -f "${AVFILTER_SRC}" "${FW_DIR}/libavfilter.12.dylib"
chmod 755 "${FW_DIR}/libavfilter.12.dylib"
xattr -c "${FW_DIR}/libavfilter.12.dylib" 2>/dev/null || true

# 3. Re-sign modified binaries and top-level bundle (without touching unmodified Frameworks)
echo "Re-signing ${TARGET_APP} (ad-hoc signature)..."
codesign --force -s - "${FW_DIR}/libmacframe.dylib"
codesign --force -s - "${FW_DIR}/libavfilter.12.dylib"
codesign --force -s - "${TARGET_APP}/Contents/MacOS/iina-cli"
codesign --force -s - "${TARGET_APP}/Contents/MacOS/iina-plugin"
codesign --force -s - "${TARGET_APP}"
codesign --verify "${TARGET_APP}"
echo "  [OK] codesign verification passed."

# 4. Install MacFrame IINA Plugin (optional HUD & quick menu)
PLUGIN_SRC="${ROOT_DIR}/iina-plugin/MacFrame.iinaplugin"
if [[ -d "${PLUGIN_SRC}" ]]; then
    PLUGIN_DST_DIR="${HOME}/Library/Application Support/com.colliderli.iina/plugins"
    PLUGIN_DST="${PLUGIN_DST_DIR}/io.github.pseudoomer.macframe.iinaplugin"
    mkdir -p "${PLUGIN_DST_DIR}"
    rm -rf "${PLUGIN_DST}"
    cp -R "${PLUGIN_SRC}" "${PLUGIN_DST}"
    defaults write com.colliderli.iina iinaEnablePluginSystem -bool true 2>/dev/null || true
    defaults write com.colliderli.iina "PluginEnabled.io.github.pseudoomer.macframe" -bool true 2>/dev/null || true
    echo "  [OK] Installed IINA plugin to ${PLUGIN_DST}"
fi

# 5. Install standalone MacFrame.app control center (skip when invoked from inside installed app)
APP_DST_DIR="$(dirname "${TARGET_APP}")"
if [[ ! -w "${APP_DST_DIR}" ]]; then
    APP_DST_DIR="${HOME}/Applications"
    mkdir -p "${APP_DST_DIR}"
fi
INSTALLED_APP="${APP_DST_DIR}/MacFrame.app"

APP_SRC=""
if [[ "${SKIP_APP_COPY}" -eq 0 ]]; then
    for cand in "${ROOT_DIR}/dist/MacFrame.app" "${ROOT_DIR}/build/MacFrame.app"; do
        if [[ -d "${cand}" ]]; then
            APP_SRC="${cand}"
            break
        fi
    done
    # If invoked from inside a standalone MacFrame.app (e.g. launched directly from a mounted DMG)
    if [[ -z "${APP_SRC}" && "$(basename "${ROOT_DIR}")" == "Resources" ]]; then
        CAND_APP="$(cd "${ROOT_DIR}/../.." 2>/dev/null && pwd -P || true)"
        if [[ -n "${CAND_APP}" && "${CAND_APP}" == *.app && -d "${CAND_APP}/Contents/MacOS" ]]; then
            APP_SRC="${CAND_APP}"
        fi
    fi
fi

if [[ -n "${APP_SRC}" ]]; then
    APP_SRC_REAL="$(cd "${APP_SRC}" && pwd -P)"
    APP_DST_REAL=""
    if [[ -d "${INSTALLED_APP}" ]]; then
        APP_DST_REAL="$(cd "${INSTALLED_APP}" && pwd -P)"
    fi
    if [[ "${APP_SRC_REAL}" != "${APP_DST_REAL}" && "${ROOT_DIR}" != "${INSTALLED_APP}"* ]]; then
        rm -rf "${INSTALLED_APP}"
        cp -R "${APP_SRC}" "${INSTALLED_APP}"
        xattr -cr "${INSTALLED_APP}" 2>/dev/null || true
        codesign --force --sign - "${INSTALLED_APP}/Contents/Frameworks/libmacframe.1.0.0.dylib"
        if [[ -f "${INSTALLED_APP}/Contents/Resources/dist/libmacframe.dylib" ]]; then
            codesign --force --sign - "${INSTALLED_APP}/Contents/Resources/dist/libmacframe.dylib"
        fi
        if [[ -f "${INSTALLED_APP}/Contents/Resources/dist/libavfilter.12.dylib" ]]; then
            codesign --force --sign - "${INSTALLED_APP}/Contents/Resources/dist/libavfilter.12.dylib"
        fi
        codesign --force --sign - "${INSTALLED_APP}"
        echo "  [OK] Installed standalone control app to ${INSTALLED_APP}"
    fi
fi

# 6. Install persistent Auto-Heal LaunchAgent so IINA updates automatically re-inject MacFrame
# Prefer the self-contained installer inside /Applications/MacFrame.app so deleting the download folder won't break auto-heal
PERSISTENT_INSTALLER="${ROOT_DIR}/installer/macframe-install.sh"
if [[ -x "${INSTALLED_APP}/Contents/Resources/installer/macframe-install.sh" ]]; then
    PERSISTENT_INSTALLER="${INSTALLED_APP}/Contents/Resources/installer/macframe-install.sh"
fi

WATCHER_DIR="${HOME}/Library/Application Support/MacFrame"
WATCHER_SH="${WATCHER_DIR}/auto-reinject.sh"
mkdir -p "${WATCHER_DIR}"
cat > "${WATCHER_SH}" <<EOF
#!/usr/bin/env bash
if [[ -d "${TARGET_APP}/Contents/Frameworks" && ! -f "${TARGET_APP}/Contents/Frameworks/libmacframe.dylib" ]]; then
    if [[ -x "${PERSISTENT_INSTALLER}" ]]; then
        "${PERSISTENT_INSTALLER}" --skip-app-copy "${TARGET_APP}" >/dev/null 2>&1 || true
    fi
fi
EOF
chmod +x "${WATCHER_SH}"

LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS_DIR}/io.github.pseudoomer.macframe.autoinject.plist"
mkdir -p "${LAUNCH_AGENTS_DIR}"
cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.pseudoomer.macframe.autoinject</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WATCHER_SH}</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>${TARGET_APP}/Contents/Frameworks</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl unload "${PLIST_PATH}" 2>/dev/null || true
launchctl load "${PLIST_PATH}" 2>/dev/null || true
echo "  [OK] Enabled auto-reinject watcher for IINA updates (${PLIST_PATH})"

# 7. If target IINA is currently running without libmacframe.dylib loaded, stop it so next launch uses the injected engine
RUNNING_PID="$(pgrep -f "${TARGET_APP}/Contents/MacOS/IINA" | head -n 1 || true)"
if [[ -n "${RUNNING_PID}" ]]; then
    if ! lsof -p "${RUNNING_PID}" 2>/dev/null | grep -q "libmacframe.dylib"; then
        echo "Stopping stale un-injected IINA process (PID ${RUNNING_PID})..."
        kill "${RUNNING_PID}" 2>/dev/null || true
    fi
fi

echo "=== MacFrame Installation Complete! ==="
echo "Launch MacFrame.app to control frame interpolation, frame rate cap, and repair features."
