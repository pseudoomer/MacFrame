#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FF_TAG="n9.0.1"
FF_SRC="${MACFRAME_FFMPEG_SRC:-${ROOT_DIR}/ffmpeg-src-n9.0.1}"
FF_BUILD="${ROOT_DIR}/ffmpeg-build"
DIST_DIR="${ROOT_DIR}/dist"
IINA_APP="${1:-/Applications/IINA.app}"
FW_DIR="${IINA_APP}/Contents/Frameworks"

if [[ ! -f "${FW_DIR}/libavfilter.12.dylib" || ! -f "${FW_DIR}/libavutil.61.dylib" ]]; then
    echo "[ERROR] Expected IINA 1.5.x (FFmpeg 9.0.x: libavfilter.12.dylib / libavutil.61.dylib) in ${FW_DIR}"
    exit 1
fi

mkdir -p "${DIST_DIR}" "${FF_BUILD}"

if [[ ! -d "${FF_SRC}" ]]; then
    echo "Cloning FFmpeg ${FF_TAG}..."
    git clone --depth 1 -b "${FF_TAG}" https://git.ffmpeg.org/ffmpeg.git "${FF_SRC}"
fi

echo "Applying MacFrame patch and copying vf_macframe.c..."
git -C "${FF_SRC}" checkout -- .
git -C "${FF_SRC}" apply "${ROOT_DIR}/ffmpeg/patches/${FF_TAG}/0001-avfilter-add-macframe.patch"
cp "${ROOT_DIR}/ffmpeg/vf_macframe.c" "${FF_SRC}/libavfilter/vf_macframe.c"

# Create a staging lib directory that symlinks IINA's bundled dylibs so linker binds to IINA's exact SOVERSIONs
IINA_LIB_STAGE="${FF_BUILD}/iina-lib"
rm -rf "${IINA_LIB_STAGE}"
mkdir -p "${IINA_LIB_STAGE}"
for dylib in "${FW_DIR}"/*.dylib; do
    base="$(basename "${dylib}")"
    ln -sf "${dylib}" "${IINA_LIB_STAGE}/${base}"
    # Also create unversioned symlink: e.g. libass.9.dylib -> libass.dylib
    stem="$(echo "${base}" | sed -E 's/\.[0-9]+(\.[0-9]+)*\.dylib$/.dylib/')"
    if [[ "${stem}" != "${base}" && ! -e "${IINA_LIB_STAGE}/${stem}" ]]; then
        ln -sf "${dylib}" "${IINA_LIB_STAGE}/${stem}"
    fi
done

BREW_PREFIX="$(brew --prefix)"
export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET="26.0"

cd "${FF_SRC}"
NEED_CONFIGURE=0
if [[ ! -f config.h ]]; then
    NEED_CONFIGURE=1
elif ! grep -q "mmacosx-version-min=26.0" ffbuild/config.mak 2>/dev/null || \
     ! grep -q "dead_strip_dylibs" ffbuild/config.mak 2>/dev/null; then
    echo "Existing FFmpeg config is outdated; reconfiguring..."
    rm -f config.h ffbuild/config.mak libavfilter/*.o libavfilter/*.d libavfilter/*.dylib libavfilter/*/*.o libavfilter/*/*.d
    NEED_CONFIGURE=1
fi

if [[ "${NEED_CONFIGURE}" -eq 1 ]]; then
    echo "Configuring FFmpeg 9.0.1 (matching IINA 1.5.1 build flags + macframe, deployment target 26.0)..."
    ./configure \
        --prefix="${FF_BUILD}/install" \
        --arch=arm64 \
        --target-os=darwin \
        --enable-gpl \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-lzma \
        --disable-xlib \
        --disable-libxcb \
        --disable-sdl2 \
        --enable-network \
        --enable-securetransport \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libspeex \
        --enable-libvorbis \
        --enable-libdav1d \
        --enable-libass \
        --enable-libwebp \
        --enable-libjxl \
        --enable-libsvtav1 \
        --enable-libbs2b \
        --enable-libsoxr \
        --enable-librubberband \
        --enable-libzimg \
        --enable-libfontconfig \
        --enable-libfreetype \
        --enable-libfribidi \
        --enable-libharfbuzz \
        --enable-filter=macframe \
        --enable-neon \
        --extra-cflags="-arch arm64 -I${BREW_PREFIX}/include -mmacosx-version-min=26.0" \
        --extra-ldflags="-arch arm64 -L${IINA_LIB_STAGE} -L${BREW_PREFIX}/lib -mmacosx-version-min=26.0 -Wl,-dead_strip_dylibs -Wl,-headerpad_max_install_names -Wl,-rpath,${FW_DIR}"
fi

echo "Building libavfilter objects and linking against IINA's bundled libraries..."
# Pre-stage IINA's existing sibling FFmpeg dylibs so make only compiles libavfilter/*.o
for sub in "libavutil:libavutil.61.dylib:libavutil.dylib" \
           "libswscale:libswscale.10.dylib:libswscale.dylib" \
           "libswresample:libswresample.7.dylib:libswresample.dylib" \
           "libavcodec:libavcodec.63.dylib:libavcodec.dylib" \
           "libavformat:libavformat.63.dylib:libavformat.dylib"; do
    IFS=":" read -r dir ver unv <<< "${sub}"
    cp -f "${FW_DIR}/${ver}" "${FF_SRC}/${dir}/${ver}"
    ln -sf "${ver}" "${FF_SRC}/${dir}/${unv}"
    touch -t 203801010000 "${FF_SRC}/${dir}/${ver}" "${FF_SRC}/${dir}/${unv}"
done

make -j"$(sysctl -n hw.ncpu)" \
    -o libavutil/libavutil.61.dylib \
    -o libswscale/libswscale.10.dylib \
    -o libswresample/libswresample.7.dylib \
    -o libavcodec/libavcodec.63.dylib \
    -o libavformat/libavformat.63.dylib \
    libavfilter/libavfilter.12.dylib

ARM64_DYLIB="${FF_BUILD}/libavfilter.12.arm64.dylib"
cp -f "${FF_SRC}/libavfilter/libavfilter.12.dylib" "${ARM64_DYLIB}"
chmod u+w "${ARM64_DYLIB}"

# Rewrite install_name and all third-party/FFmpeg dylib references to @rpath/<IINA filename>
install_name_tool -id "@rpath/libavfilter.12.dylib" "${ARM64_DYLIB}"

DEPS=$(otool -arch arm64 -L "${ARM64_DYLIB}" | tail -n +2 | awk '{print $1}')
for dep in ${DEPS}; do
    base="$(basename "${dep}")"
    if [[ "${dep}" == "${FF_BUILD}"* || "${dep}" == /opt/homebrew/* || "${dep}" == /usr/local/* ]]; then
        if [[ -f "${FW_DIR}/${base}" ]]; then
            install_name_tool -change "${dep}" "@rpath/${base}" "${ARM64_DYLIB}"
        else
            # Map by library prefix if Homebrew has a newer minor/major suffix than IINA
            prefix="$(echo "${base}" | sed -E 's/\.[0-9]+(\.[0-9]+)*\.dylib$//')"
            match="$(ls "${FW_DIR}/${prefix}".*.dylib 2>/dev/null | head -1 || true)"
            if [[ -n "${match}" ]]; then
                mbase="$(basename "${match}")"
                install_name_tool -change "${dep}" "@rpath/${mbase}" "${ARM64_DYLIB}"
            fi
        fi
    fi
done

# Remove temporary build rpath if present
install_name_tool -delete_rpath "${FW_DIR}" "${ARM64_DYLIB}" 2>/dev/null || true

# Combine with original x86_64 slice from IINA so universal fat binary structure is preserved
ORIG_DYLIB="${FW_DIR}/libavfilter.12.dylib"
if lipo -archs "${ORIG_DYLIB}" | grep -q "x86_64"; then
    X86_DYLIB="${FF_BUILD}/libavfilter.12.x86_64.dylib"
    lipo "${ORIG_DYLIB}" -thin x86_64 -output "${X86_DYLIB}"
    lipo -create "${ARM64_DYLIB}" "${X86_DYLIB}" -output "${DIST_DIR}/libavfilter.12.dylib"
else
    cp -f "${ARM64_DYLIB}" "${DIST_DIR}/libavfilter.12.dylib"
fi

codesign --force -s - "${DIST_DIR}/libavfilter.12.dylib"
rm -f "${DIST_DIR}/libavfilter.10.dylib"

# Keep embedded payload inside any already-built MacFrame.app bundle in sync
for app_bundle in "${ROOT_DIR}/build/MacFrame.app" "${DIST_DIR}/MacFrame.app"; do
    if [[ -d "${app_bundle}/Contents/Resources" ]]; then
        mkdir -p "${app_bundle}/Contents/Resources/dist"
        rm -f "${app_bundle}/Contents/Resources/dist/libavfilter.10.dylib"
        cp -f "${DIST_DIR}/libavfilter.12.dylib" "${app_bundle}/Contents/Resources/dist/libavfilter.12.dylib"
        xattr -cr "${app_bundle}" 2>/dev/null || true
        codesign --force --sign - "${app_bundle}" >/dev/null 2>&1 || true
    fi
done

echo "Built universal ${DIST_DIR}/libavfilter.12.dylib"
"${ROOT_DIR}/scripts/verify-abi.sh" "${DIST_DIR}/libavfilter.12.dylib" "${IINA_APP}"
