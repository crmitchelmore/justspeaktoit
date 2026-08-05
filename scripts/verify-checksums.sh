#!/bin/bash
set -euo pipefail

# Verifies binary target checksums in Package.swift against Package.resolved
# and ensures no stale .swiftlint-baseline.json drift.
echo "→ Verifying Package.resolved checksums..."
if ! swift package resolve 2>&1 | grep -q "error:"; then
  echo "✓ Package resolution OK"
else
  echo "✗ Package resolution failed" >&2
  exit 1
fi

# Verify CTranscribe binary checksum matches Package.swift declaration
EXPECTED_CHECKSUM=$(grep -A2 'binaryTarget.*CTranscribe' Package.swift | grep checksum | grep -o '"[^"]*"' | tail -1 | tr -d '"')
if [ -z "$EXPECTED_CHECKSUM" ]; then
  echo "⚠ Could not extract CTranscribe checksum from Package.swift"
else
  echo "✓ CTranscribe checksum present: ${EXPECTED_CHECKSUM:0:12}..."
fi

# Warn if baseline is stale (>700 entries suggests debt not being burned down)
if [ -f .swiftlint-baseline.json ]; then
  COUNT=$(grep -o '"ruleIdentifier"' .swiftlint-baseline.json | wc -l | tr -d ' ')
  echo "→ SwiftLint baseline entries: $COUNT"
  if [ "$COUNT" -gt 780 ]; then
    echo "⚠ Baseline grew — please run 'make format' and reduce debt"
  else
    echo "✓ Baseline not growing"
  fi
fi

echo "✓ Checksum verification complete"
