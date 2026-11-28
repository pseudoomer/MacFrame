#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Remove macOS Gatekeeper quarantine attribute if extracted from a downloaded zip
xattr -dr com.apple.quarantine . 2>/dev/null || true

./installer/macframe-install.sh "$@"

# Open MacFrame.app automatically for immediate out-of-the-box use
if [[ -d "/Applications/MacFrame.app" ]]; then
    open -a "/Applications/MacFrame.app" || true
elif [[ -d "${HOME}/Applications/MacFrame.app" ]]; then
    open -a "${HOME}/Applications/MacFrame.app" || true
fi
