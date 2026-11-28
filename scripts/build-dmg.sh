#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/MacFrame.app"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "[ERROR] ${APP_BUNDLE} not found. Run ./scripts/build-engine.sh first."
    exit 1
fi

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    PLIST_VER="$(defaults read "${APP_BUNDLE}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.2.2")"
    VERSION="v${PLIST_VER}"
fi

OUT_DMG="${2:-${DIST_DIR}/MacFrame-${VERSION}-macos.dmg}"
STAGE_DIR="/tmp/macframe_dmg_stage_$$"
trap 'rm -rf "${STAGE_DIR}"' EXIT

rm -rf "${STAGE_DIR}" "${OUT_DMG}"
mkdir -p "${STAGE_DIR}"

# Copy self-contained MacFrame.app preserving internal symlinks and signatures
cp -a "${APP_BUNDLE}" "${STAGE_DIR}/MacFrame.app"
xattr -cr "${STAGE_DIR}/MacFrame.app" 2>/dev/null || true
codesign --verify --deep --strict "${STAGE_DIR}/MacFrame.app"
ln -s /Applications "${STAGE_DIR}/Applications"

echo "[MacFrame] Creating compressed DMG -> ${OUT_DMG}"
hdiutil create \
    -volname "MacFrame ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${OUT_DMG}" >/dev/null

echo "[MacFrame] Built DMG: ${OUT_DMG} ($(du -h "${OUT_DMG}" | awk '{print $1}'))"
