#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"

# Validate dependency resolution using SwiftPM's exit status directly.
echo "→ Resolving Swift package dependencies..."
swift package resolve
echo "✓ Package resolution OK"

benchmark_package="Benchmarks/LocalTranscription"
benchmark_manifest="$benchmark_package/Package.swift"
echo "→ Resolving local-transcription benchmark dependencies..."
swift package --package-path "$benchmark_package" resolve
echo "✓ Benchmark package resolution OK"

# Extract the complete multiline CTranscribe target declaration.
target_block=$(
  awk '
    /[.]binaryTarget[[:space:]]*[(]/ { capture = 1; block = $0 ORS; next }
    capture {
      block = block $0 ORS
      if ($0 ~ /^[[:space:]]*[)][,]?[[:space:]]*$/) {
        if (block ~ /name:[[:space:]]*"CTranscribe"/) { printf "%s", block }
        capture = 0
        block = ""
      }
    }
  ' "$benchmark_manifest"
)

binary_url=$(
  printf '%s' "$target_block" \
    | awk '/url:/ { capture = 1 } /checksum:/ { capture = 0 } capture' \
    | grep -o '"[^"]*"' \
    | tr -d '"\n'
)
declared_checksum=$(
  printf '%s' "$target_block" \
    | awk -F'"' '/checksum:/ { print $2; exit }'
)

if [[ -z "$binary_url" || ! "$declared_checksum" =~ ^[0-9a-f]{64}$ ]]; then
  echo "✗ Could not extract CTranscribe URL and checksum from $benchmark_manifest" >&2
  exit 1
fi

archive=$(mktemp "${TMPDIR:-/tmp}/CTranscribe.XXXXXX.zip")
trap 'rm -f "$archive"' EXIT
echo "→ Downloading CTranscribe artifact..."
curl --fail --location --silent --show-error --connect-timeout 30 --max-time 600 --retry 3 \
  "$binary_url" --output "$archive"
actual_checksum=$(swift package compute-checksum "$archive")
if [[ "$actual_checksum" != "$declared_checksum" ]]; then
  echo "✗ CTranscribe checksum mismatch" >&2
  echo "  declared: $declared_checksum" >&2
  echo "  actual:   $actual_checksum" >&2
  exit 1
fi
echo "✓ CTranscribe checksum verified: ${declared_checksum:0:12}..."

# SwiftLint runs with no baseline; a reintroduced one is debt the lint gate would hide.
if [ -f .swiftlint-baseline.json ]; then
  echo "✗ .swiftlint-baseline.json must not exist; fix the violations instead" >&2
  exit 1
fi

echo "✓ Checksum verification complete"
