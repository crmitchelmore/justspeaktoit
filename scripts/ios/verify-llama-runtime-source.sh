#!/usr/bin/env bash
# Checks every vendored file in Sources/CLlamaRuntime/upstream against the
# pinned llama.cpp archive (see Sources/CLlamaRuntime/PROVENANCE.md).
set -euo pipefail

TAG="b11425"
SHA256="3bf5a64c06ecfac21fcf3d44b180177a1ced2b170a9d9a98dfe435d71c83c92a"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDORED="$ROOT/Sources/CLlamaRuntime/upstream"
WORK="$ROOT/.build/llama-runtime-verify"
ARCHIVE="$WORK/llama.cpp-$TAG.tar.gz"

mkdir -p "$WORK"
if [[ ! -f "$ARCHIVE" ]]; then
  curl -fsSL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz" -o "$ARCHIVE"
fi
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
  echo "Archive SHA-256 is $actual, expected $SHA256" >&2
  exit 1
fi
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
tar -xzf "$ARCHIVE" -C "$WORK/src" --strip-components 1

status=0
count=0
while IFS= read -r -d '' file; do
  relative="${file#"$VENDORED"/}"
  if ! cmp -s "$file" "$WORK/src/$relative"; then
    echo "Differs from the pinned archive: upstream/$relative" >&2
    status=1
  fi
  count=$((count + 1))
done < <(find "$VENDORED" -type f -not -path "$VENDORED/generated/*" -print0)

if [[ $status -eq 0 ]]; then
  echo "All $count vendored files match llama.cpp $TAG."
fi
exit "$status"
