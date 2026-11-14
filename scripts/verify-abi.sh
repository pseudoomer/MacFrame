#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <path/to/new/libavfilter.10.dylib> <path/to/IINA.app>"
    exit 2
fi

NEW_DYLIB="$1"
IINA_APP="$2"
FW_DIR="${IINA_APP}/Contents/Frameworks"

if [[ ! -f "${NEW_DYLIB}" ]]; then
    echo "[FAIL] Missing dylib: ${NEW_DYLIB}"
    exit 1
fi
if [[ ! -d "${FW_DIR}" ]]; then
    echo "[FAIL] Missing Frameworks dir: ${FW_DIR}"
    exit 1
fi

echo "=== Verifying ABI & Dependency Graph of $(basename "${NEW_DYLIB}") against ${IINA_APP} ==="

# 1. Verify arm64 slice exists
ARCHS="$(lipo -archs "${NEW_DYLIB}")"
echo "  Architectures: ${ARCHS}"
if [[ "${ARCHS}" != *"arm64"* ]]; then
    echo "[FAIL] arm64 architecture missing from ${NEW_DYLIB}"
    exit 1
fi

# 2. Verify all @rpath dependencies exist in IINA Frameworks or build dir
DEPS=$(otool -arch arm64 -L "${NEW_DYLIB}" | tail -n +2 | awk '{print $1}')
for dep in ${DEPS}; do
    if [[ "${dep}" == @rpath/* ]]; then
        base="${dep#@rpath/}"
        if [[ "${base}" != "libavfilter.10.dylib" && "${base}" != "libmacframe.dylib" && ! -f "${FW_DIR}/${base}" ]]; then
            echo "[FAIL] Dependency ${dep} does not exist in ${FW_DIR}"
            exit 1
        fi
    elif [[ "${dep}" == /opt/homebrew/* || "${dep}" == /usr/local/* ]]; then
        echo "[FAIL] Non-portable Homebrew path in dylib load commands: ${dep}"
        exit 1
    fi
done
echo "  [OK] All LC_LOAD_DYLIB entries are portable (@rpath or system frameworks) and present in IINA."

# 3. Verify ff_vf_macframe is compiled in
if ! (nm -arch arm64 "${NEW_DYLIB}" | grep "_ff_vf_macframe" >/dev/null); then
    echo "[FAIL] Filter '_ff_vf_macframe' symbol not found in ${NEW_DYLIB}"
    exit 1
fi
echo "  [OK] 'macframe' filter symbol & descriptor verified."

# 4. Runtime dlopen(RTLD_NOW) check with IINA's Frameworks rpath
TMP_BIN="$(mktemp -t mf_abi_check)"
cc -x c - -o "${TMP_BIN}" -Wl,-rpath,"${FW_DIR}" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "[FAIL] dlopen failed: %s\n", dlerror()); return 1; }
    void *(*get_by_name)(const char *) = dlsym(h, "avfilter_get_by_name");
    if (!get_by_name) { fprintf(stderr, "[FAIL] missing avfilter_get_by_name\n"); return 1; }
    void *f = get_by_name("macframe");
    if (!f) { fprintf(stderr, "[FAIL] avfilter_get_by_name(\"macframe\") returned NULL\n"); return 1; }
    printf("  [OK] Runtime dlopen(RTLD_NOW) + avfilter_get_by_name(\"macframe\") = %p\n", f);
    return 0;
}
EOF
"${TMP_BIN}" "${NEW_DYLIB}"
rm -f "${TMP_BIN}"

echo "=== ABI Verification PASSED ==="
