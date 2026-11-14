#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" -j

# Build standalone macOS control application: MacFrame.app
APP_BUNDLE="${BUILD_DIR}/MacFrame.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${ROOT_DIR}/app/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${BUILD_DIR}/libmacframe.1.0.0.dylib" "${APP_BUNDLE}/Contents/Frameworks/libmacframe.1.0.0.dylib"
ln -sf "libmacframe.1.0.0.dylib" "${APP_BUNDLE}/Contents/Frameworks/libmacframe.1.dylib"
ln -sf "libmacframe.1.dylib" "${APP_BUNDLE}/Contents/Frameworks/libmacframe.dylib"

swiftc -O -parse-as-library "${ROOT_DIR}/app/MacFrameApp.swift" \
    -import-objc-header "${ROOT_DIR}/engine/include/macframe/mf_ipc.h" \
    -I "${ROOT_DIR}/engine/include" \
    -L "${BUILD_DIR}" -lmacframe \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "${APP_BUNDLE}/Contents/MacOS/MacFrame"

xattr -cr "${APP_BUNDLE}"
codesign --force --sign - "${APP_BUNDLE}/Contents/Frameworks/libmacframe.1.0.0.dylib"
codesign --force --sign - "${APP_BUNDLE}"

mkdir -p "${DIST_DIR}"
rm -rf "${DIST_DIR}/MacFrame.app"
cp -R "${APP_BUNDLE}" "${DIST_DIR}/MacFrame.app"
cp -f "${BUILD_DIR}/libmacframe.1.0.0.dylib" "${DIST_DIR}/libmacframe.1.dylib"
echo "[MacFrame] Built engine + standalone MacFrame.app -> ${APP_BUNDLE}"
