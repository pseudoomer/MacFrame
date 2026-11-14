#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FF_SRC="${ROOT_DIR}/ffmpeg-src"
FF_BUILD="${ROOT_DIR}/ffmpeg-build"
DIST_DIR="${ROOT_DIR}/dist"
IINA_APP="${1:-/Applications/IINA.app}"
FW_DIR="${IINA_APP}/Contents/Frameworks"

mkdir -p "${DIST_DIR}" "${FF_BUILD}"

if [[ ! -d "${FF_SRC}" ]]; then
    echo "Cloning FFmpeg n7.0.1..."
    git clone --depth 1 -b n7.0.1 https://git.ffmpeg.org/ffmpeg.git "${FF_SRC}"
fi

echo "Applying MacFrame patch and copying vf_macframe.c..."
git -C "${FF_SRC}" checkout -- .
git -C "${FF_SRC}" apply "${ROOT_DIR}/ffmpeg/patches/n7.0.1/0001-avfilter-add-macframe.patch"
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

cd "${FF_SRC}"
if [[ ! -f config.h ]]; then
    echo "Configuring FFmpeg 7.0.1 (matching IINA 1.4.3 build flags + macframe)..."
    ./configure \
        --prefix="${FF_BUILD}/install" \
        --enable-shared \
        --disable-static \
        --enable-pthreads \
        --enable-version3 \
        --enable-gpl \
        --enable-gnutls \
        --enable-libbluray \
        --enable-libdav1d \
        --enable-librubberband \
        --enable-libsnappy \
        --enable-libvidstab \
        --enable-libxml2 \
        --enable-libfontconfig \
        --enable-libfreetype \
        --enable-frei0r \
        --enable-libass \
        --enable-libspeex \
        --enable-libsoxr \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libzmq \
        --enable-libzimg \
        --enable-libwebp \
        --enable-libjxl \
        --enable-filter=macframe \
        --enable-neon \
        --extra-cflags="-I${BREW_PREFIX}/include" \
        --extra-ldflags="-L${IINA_LIB_STAGE} -L${BREW_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-rpath,${FW_DIR}"
fi

echo "Building libavfilter objects and linking against IINA's bundled libraries..."
# Pre-stage IINA's existing sibling FFmpeg dylibs so make only compiles libavfilter/*.o
for sub in "libavutil:libavutil.59.dylib:libavutil.dylib" \
           "libswscale:libswscale.8.dylib:libswscale.dylib" \
           "libswresample:libswresample.5.dylib:libswresample.dylib" \
           "libpostproc:libpostproc.58.dylib:libpostproc.dylib" \
           "libavcodec:libavcodec.61.dylib:libavcodec.dylib" \
           "libavformat:libavformat.61.dylib:libavformat.dylib"; do
    IFS=":" read -r dir ver unv <<< "${sub}"
    cp -f "${FW_DIR}/${ver}" "${FF_SRC}/${dir}/${ver}"
    ln -sf "${ver}" "${FF_SRC}/${dir}/${unv}"
    touch -t 203801010000 "${FF_SRC}/${dir}/${ver}" "${FF_SRC}/${dir}/${unv}"
done

make -j"$(sysctl -n hw.ncpu)" -o libavutil/libavutil.59.dylib -o libswscale/libswscale.8.dylib \
    -o libswresample/libswresample.5.dylib -o libpostproc/libpostproc.58.dylib \
    -o libavcodec/libavcodec.61.dylib -o libavformat/libavformat.61.dylib \
    libavfilter/libavfilter.10.dylib

ARM64_DYLIB="${FF_BUILD}/libavfilter.10.arm64.dylib"
cp -f "${FF_SRC}/libavfilter/libavfilter.10.dylib" "${ARM64_DYLIB}"
chmod u+w "${ARM64_DYLIB}"

# Rewrite install_name and all third-party/FFmpeg dylib references to @rpath/<IINA filename>
install_name_tool -id "@rpath/libavfilter.10.dylib" "${ARM64_DYLIB}"

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
ORIG_DYLIB="${FW_DIR}/libavfilter.10.dylib"
if lipo -archs "${ORIG_DYLIB}" | grep -q "x86_64"; then
    X86_DYLIB="${FF_BUILD}/libavfilter.10.x86_64.dylib"
    lipo "${ORIG_DYLIB}" -thin x86_64 -output "${X86_DYLIB}"
    lipo -create "${ARM64_DYLIB}" "${X86_DYLIB}" -output "${DIST_DIR}/libavfilter.10.dylib"
else
    cp -f "${ARM64_DYLIB}" "${DIST_DIR}/libavfilter.10.dylib"
fi

codesign --force -s - "${DIST_DIR}/libavfilter.10.dylib"

echo "Built universal ${DIST_DIR}/libavfilter.10.dylib"
"${ROOT_DIR}/scripts/verify-abi.sh" "${DIST_DIR}/libavfilter.10.dylib" "${IINA_APP}"
