#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" -j

# Build standalone macOS control application: MacFrame.app
# Assemble and sign in /tmp first to avoid iCloud Desktop FinderInfo extended attributes during codesign
STAGE_DIR="/tmp/macframe_app_stage"
STAGE_BUNDLE="${STAGE_DIR}/MacFrame.app"
APP_BUNDLE="${BUILD_DIR}/MacFrame.app"
rm -rf "${STAGE_DIR}" "${APP_BUNDLE}"
mkdir -p "${STAGE_BUNDLE}/Contents/MacOS"
mkdir -p "${STAGE_BUNDLE}/Contents/Frameworks"
mkdir -p "${STAGE_BUNDLE}/Contents/Resources"

cp "${ROOT_DIR}/app/Info.plist" "${STAGE_BUNDLE}/Contents/Info.plist"
if [[ ! -f "${ROOT_DIR}/app/Resources/AppIcon.icns" ]]; then
    swift "${ROOT_DIR}/tools/make-icon/make_icon.swift" "${ROOT_DIR}/app/Resources/AppIcon.icns" "${ROOT_DIR}/docs/images/icon-1024.png"
fi
cp "${ROOT_DIR}/app/Resources/AppIcon.icns" "${STAGE_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${BUILD_DIR}/libmacframe.1.0.0.dylib" "${STAGE_BUNDLE}/Contents/Frameworks/libmacframe.1.0.0.dylib"
ln -sf "libmacframe.1.0.0.dylib" "${STAGE_BUNDLE}/Contents/Frameworks/libmacframe.1.dylib"
ln -sf "libmacframe.1.dylib" "${STAGE_BUNDLE}/Contents/Frameworks/libmacframe.dylib"

# Prepare prebuilt portable dylibs for dist/ and self-contained app payload
mkdir -p "${DIST_DIR}"
cp -f "${BUILD_DIR}/libmacframe.1.0.0.dylib" "${DIST_DIR}/libmacframe.dylib"
chmod u+w "${DIST_DIR}/libmacframe.dylib"
install_name_tool -id "@rpath/libmacframe.dylib" "${DIST_DIR}/libmacframe.dylib"
codesign --force --sign - "${DIST_DIR}/libmacframe.dylib"
cp -f "${DIST_DIR}/libmacframe.dylib" "${DIST_DIR}/libmacframe.1.dylib"

# Embed installer, ABI verifier, IINA plugin, and prebuilt dylibs inside MacFrame.app
# so /Applications/MacFrame.app can inject, auto-reinject, and restore IINA completely standalone
PAYLOAD_DIR="${STAGE_BUNDLE}/Contents/Resources"
mkdir -p "${PAYLOAD_DIR}/installer" "${PAYLOAD_DIR}/scripts" "${PAYLOAD_DIR}/iina-plugin" "${PAYLOAD_DIR}/dist"
cp -f "${ROOT_DIR}/installer/macframe-install.sh" "${PAYLOAD_DIR}/installer/macframe-install.sh"
cp -f "${ROOT_DIR}/installer/macframe-uninstall.sh" "${PAYLOAD_DIR}/installer/macframe-uninstall.sh"
chmod +x "${PAYLOAD_DIR}/installer/macframe-install.sh" "${PAYLOAD_DIR}/installer/macframe-uninstall.sh"
cp -f "${ROOT_DIR}/scripts/verify-abi.sh" "${PAYLOAD_DIR}/scripts/verify-abi.sh"
chmod +x "${PAYLOAD_DIR}/scripts/verify-abi.sh"
rm -rf "${PAYLOAD_DIR}/iina-plugin/MacFrame.iinaplugin"
cp -R "${ROOT_DIR}/iina-plugin/MacFrame.iinaplugin" "${PAYLOAD_DIR}/iina-plugin/MacFrame.iinaplugin"
cp -f "${DIST_DIR}/libmacframe.dylib" "${PAYLOAD_DIR}/dist/libmacframe.dylib"
if [[ -f "${DIST_DIR}/libavfilter.12.dylib" ]]; then
    cp -f "${DIST_DIR}/libavfilter.12.dylib" "${PAYLOAD_DIR}/dist/libavfilter.12.dylib"
fi

swiftc -O -parse-as-library -target arm64-apple-macosx26.0 "${ROOT_DIR}/app/MacFrameApp.swift" \
    -import-objc-header "${ROOT_DIR}/engine/include/macframe/mf_ipc.h" \
    -I "${ROOT_DIR}/engine/include" \
    -L "${BUILD_DIR}" -lmacframe \
    -framework Carbon -framework ServiceManagement \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "${STAGE_BUNDLE}/Contents/MacOS/MacFrame"

xattr -cr "${STAGE_BUNDLE}"
codesign --force --sign - "${STAGE_BUNDLE}/Contents/Frameworks/libmacframe.1.0.0.dylib"
codesign --force --sign - "${STAGE_BUNDLE}/Contents/Resources/dist/libmacframe.dylib"
if [[ -f "${STAGE_BUNDLE}/Contents/Resources/dist/libavfilter.12.dylib" ]]; then
    codesign --force --sign - "${STAGE_BUNDLE}/Contents/Resources/dist/libavfilter.12.dylib"
fi
codesign --force --sign - "${STAGE_BUNDLE}"

cp -R "${STAGE_BUNDLE}" "${APP_BUNDLE}"
rm -rf "${DIST_DIR}/MacFrame.app"
cp -R "${STAGE_BUNDLE}" "${DIST_DIR}/MacFrame.app"
echo "[MacFrame] Built engine + standalone self-contained MacFrame.app -> ${APP_BUNDLE}"
