#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

xattr -dr com.apple.quarantine . 2>/dev/null || true
./installer/macframe-uninstall.sh "$@"
