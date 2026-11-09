#!/usr/bin/env bash
# Install the pinned Tuist release on a hosted runner and print its directory.
#
# Tuist's release download URL (and therefore `brew install tuist`) returned
# HTTP 504 on every request while the same asset was served through the GitHub
# REST asset endpoint. Fetch through that endpoint first, fall back to the
# release URL, retry with backoff, and verify the pinned SHA-256 before use.
#
# Usage: dir="$(scripts/install-tuist.sh)"; export PATH="$dir:$PATH"
# With GITHUB_PATH set, the directory is also added for later workflow steps.
# GITHUB_TOKEN, when present, is sent only to api.github.com to avoid the
# shared hosted-runner rate limit.
set -euo pipefail

VERSION="4.214.1"
ASSET_ID="691940861"
SHA256="c9fb90582126d30380e9348da2c84d9c4ab08d59cded454f6bd8ef60bd93c759"
read -r -a DELAYS <<< "${TUIST_INSTALL_DELAYS:-10 30 60}"

root="${TUIST_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}/jsti-tuist-$VERSION"
if [[ -x "$root/tuist" ]] && [[ "$("$root/tuist" version 2>/dev/null | tr -d '[:space:]')" == "$VERSION" ]]; then
    [[ -n "${GITHUB_PATH:-}" ]] && echo "$root" >> "$GITHUB_PATH"
    echo "$root"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="$work/tuist.zip"

fetch() {
    local headers=(-H "Accept: application/octet-stream")
    [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --retry 0 --connect-timeout 20 --max-time 300 "${headers[@]}" -o "$archive" \
        "https://api.github.com/repos/tuist/tuist/releases/assets/$ASSET_ID" && return 0
    curl -fsSL --retry 0 --connect-timeout 20 --max-time 300 -o "$archive" \
        "https://github.com/tuist/tuist/releases/download/$VERSION/tuist.zip"
}

attempt=1
until fetch && [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$SHA256" ]]; do
    if [[ $attempt -gt ${#DELAYS[@]} ]]; then
        echo "::error::Could not download a verified Tuist $VERSION after $attempt attempts" >&2
        exit 1
    fi
    delay="${DELAYS[$((attempt - 1))]}"
    echo "::warning::Tuist $VERSION download attempt $attempt failed or did not verify; retrying in ${delay}s" >&2
    rm -f "$archive"
    sleep "$delay"
    attempt=$((attempt + 1))
done

rm -rf "$root"
mkdir -p "$root"
ditto -x -k "$archive" "$root"
installed="$("$root/tuist" version | tr -d '[:space:]')"
if [[ "$installed" != "$VERSION" ]]; then
    echo "::error::Installed Tuist reports $installed, expected $VERSION" >&2
    exit 1
fi
echo "Installed Tuist $VERSION at $root" >&2
[[ -n "${GITHUB_PATH:-}" ]] && echo "$root" >> "$GITHUB_PATH"
echo "$root"
