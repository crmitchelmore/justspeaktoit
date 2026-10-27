#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH="${1:?Usage: retry-staple.sh <artifact-path>}"
MAX_ATTEMPTS="${STAPLE_MAX_ATTEMPTS:-6}"
RETRY_DELAY="${STAPLE_RETRY_DELAY_SECONDS:-10}"

if [[ ! -e "$ARTIFACT_PATH" ]]; then
    echo "Artifact does not exist: $ARTIFACT_PATH" >&2
    exit 2
fi

if ! [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    echo "STAPLE_MAX_ATTEMPTS must be a positive integer" >&2
    exit 2
fi

if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]] || (( RETRY_DELAY > 300 )); then
    echo "STAPLE_RETRY_DELAY_SECONDS must be an integer between 0 and 300" >&2
    exit 2
fi

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if xcrun stapler staple "$ARTIFACT_PATH" && xcrun stapler validate "$ARTIFACT_PATH"; then
        exit 0
    fi

    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo "Stapling or validation failed after $MAX_ATTEMPTS attempts" >&2
        exit 1
    fi

    echo "Stapling or ticket validation failed; retrying in ${RETRY_DELAY}s (${attempt}/${MAX_ATTEMPTS})..."
    sleep "$RETRY_DELAY"
done
