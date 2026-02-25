#!/bin/bash
# Check Sentry crash-free rate as a release quality gate.
# Usage: ./scripts/check-crash-rate.sh <version>
# Env: SENTRY_AUTH_TOKEN (required), SENTRY_ORG, SENTRY_PROJECT, CRASH_FREE_THRESHOLD
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
THRESHOLD="${CRASH_FREE_THRESHOLD:-99}"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "⚠️  SENTRY_AUTH_TOKEN not set — skipping crash-rate check"; exit 0
fi

API="https://sentry.io/api/0/projects/${SENTRY_ORG:-justspeaktoit}/${SENTRY_PROJECT:-macos}"
RESPONSE=$(curl -sf -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
  "${API}/sessions/?field=crash_free_rate(session)&query=release:${VERSION}&statsPeriod=24h") || {
  echo "⚠️  Sentry API request failed — skipping check"; exit 0
}

RATE=$(echo "$RESPONSE" | python3 -c "
import sys,json; g=json.load(sys.stdin).get('groups',[])
print('N/A' if not g else g[0]['totals']['crash_free_rate(session)']*100)
" 2>/dev/null || echo "N/A")

if [ "$RATE" = "N/A" ]; then
  echo "ℹ️  No session data for v${VERSION} yet — passing"; exit 0
fi

echo "Crash-free rate for v${VERSION}: ${RATE}% (threshold: ${THRESHOLD}%)"
if python3 -c "exit(0 if $RATE >= $THRESHOLD else 1)"; then
  echo "✅ Crash-free rate meets threshold"
else
  echo "❌ Crash-free rate ${RATE}% is below ${THRESHOLD}% — blocking rollout"; exit 1
fi
