#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH="${1:?Usage: retry-staple.sh <artifact-path>}"
MAX_ATTEMPTS="${STAPLE_MAX_ATTEMPTS:-6}"
RETRY_DELAY="${STAPLE_RETRY_DELAY_SECONDS:-10}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if xcrun stapler staple "$ARTIFACT_PATH"; then
        xcrun stapler validate "$ARTIFACT_PATH"
        exit 0
    fi

    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo "Stapling failed after $MAX_ATTEMPTS attempts" >&2
        exit 1
    fi

    echo "Notarization ticket is not available yet; retrying in ${RETRY_DELAY}s (${attempt}/${MAX_ATTEMPTS})..."
    sleep "$RETRY_DELAY"
done
