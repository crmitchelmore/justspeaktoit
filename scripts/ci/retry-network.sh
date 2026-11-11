#!/usr/bin/env bash
# Run an idempotent network-bound command (package resolution, toolchain
# install) with bounded retries. GitHub release assets used by SwiftPM binary
# targets and Homebrew casks intermittently return 5xx on hosted runners.
#
# Usage: scripts/ci/retry-network.sh <command> [arguments...]
# RETRY_NETWORK_DELAYS overrides the space-separated backoff (seconds).
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [arguments...]" >&2
    exit 64
fi

read -r -a delays <<< "${RETRY_NETWORK_DELAYS:-10 30 60 120}"
attempt=1
total=$((${#delays[@]} + 1))
while true; do
    "$@"
    status=$?
    [[ $status -eq 0 ]] && exit 0
    if [[ $attempt -ge $total ]]; then
        echo "::error::Network-bound command failed after $total attempts: $*" >&2
        exit "$status"
    fi
    delay="${delays[$((attempt - 1))]}"
    echo "::warning::Attempt $attempt/$total failed (exit $status); retrying in ${delay}s: $*" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
done
