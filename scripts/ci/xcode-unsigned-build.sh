#!/usr/bin/env bash
# CI's unsigned device builds (ci-ios.yml's Build iOS Keyboard job): generate the
# Tuist workspace, resolve its packages, both with network retries, then build
# one scheme unsigned and keep the last 30 lines of xcodebuild's output. Tuist
# reads its TUIST_* feature flags from the environment.
#
# Usage: scripts/ci/xcode-unsigned-build.sh [--no-generate] <scheme> <destination>
# --no-generate builds another scheme of the workspace an earlier call generated.
set -eo pipefail

generate=1
if [[ "${1:-}" == --no-generate ]]; then
    generate=0
    shift
fi
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 [--no-generate] <scheme> <destination>" >&2
    exit 64
fi
scheme="$1"
destination="$2"
workspace="Just Speak to It.xcworkspace"
retry="$(dirname "$0")/retry-network.sh"

if [[ $generate -eq 1 ]]; then
    "$retry" tuist generate --no-open
    "$retry" xcodebuild -resolvePackageDependencies -skipPackagePluginValidation \
        -workspace "$workspace" -scheme "$scheme"
fi
xcodebuild build \
    -workspace "$workspace" \
    -scheme "$scheme" \
    -destination "$destination" \
    CODE_SIGNING_ALLOWED=NO \
    -skipPackagePluginValidation \
    -quiet \
    2>&1 | tail -30
