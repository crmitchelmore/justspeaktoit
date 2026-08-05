#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

# Validate dependency resolution using SwiftPM's exit status directly.
echo "→ Resolving Swift package dependencies..."
swift package resolve
echo "✓ Package resolution OK"

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
  ' Package.swift
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
  echo "✗ Could not extract CTranscribe URL and checksum from Package.swift" >&2
  exit 1
fi

archive=$(mktemp "${TMPDIR:-/tmp}/CTranscribe.XXXXXX.zip")
trap 'rm -f "$archive"' EXIT
echo "→ Downloading CTranscribe artifact..."
curl --fail --location --silent --show-error "$binary_url" --output "$archive"
actual_checksum=$(swift package compute-checksum "$archive")
if [[ "$actual_checksum" != "$declared_checksum" ]]; then
  echo "✗ CTranscribe checksum mismatch" >&2
  echo "  declared: $declared_checksum" >&2
  echo "  actual:   $actual_checksum" >&2
  exit 1
fi
echo "✓ CTranscribe checksum verified: ${declared_checksum:0:12}..."

# Enforce the current SwiftLint debt ceiling rather than merely warning.
if [ -f .swiftlint-baseline.json ]; then
  baseline_count=$(grep -o '"ruleIdentifier"' .swiftlint-baseline.json | wc -l | tr -d ' ')
  baseline_ceiling=780
  echo "→ SwiftLint baseline entries: $baseline_count (ceiling: $baseline_ceiling)"
  if [ "$baseline_count" -gt "$baseline_ceiling" ]; then
    echo "✗ SwiftLint baseline exceeds the allowed debt ceiling" >&2
    exit 1
  else
    echo "✓ SwiftLint baseline is within the debt ceiling"
  fi
fi

echo "✓ Checksum verification complete"
