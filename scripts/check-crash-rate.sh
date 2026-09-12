#!/usr/bin/env bash
# Check measured Sentry session health for an exact release identity.
# Usage: ./scripts/check-crash-rate.sh 'justspeaktoit-mac@<version>+<build>'
# Exit 0: measured pass; 1: below threshold; 2: unavailable/invalid evidence.
# This standalone check is not automatically run by the release workflow.
set -euo pipefail

RELEASE_ID="${1:?Usage: $0 <exact-sentry-release-id>}"
THRESHOLD="${CRASH_FREE_THRESHOLD:-99}"
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  echo "::error::SENTRY_AUTH_TOKEN is required; crash-free rate is unknown." >&2
  exit 2
fi
if [[ ! "$RELEASE_ID" =~ ^justspeaktoit-mac@[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
  echo "::error::Use the full Sentry release identity: justspeaktoit-mac@<version>+<build>." >&2
  exit 2
fi

# Release-health sessions use the organization endpoint and an explicit project
# filter. URL-encode the release query so '+' remains part of the build identity.
API="https://de.sentry.io/api/0/organizations/${SENTRY_ORG:-tally-lz}/sessions/"
RESPONSE=$(curl --fail --silent --show-error --get --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
  --data-urlencode "project=${SENTRY_PROJECT:-justspeaktoit}" \
  --data-urlencode 'field=crash_free_rate(session)' \
  --data-urlencode 'field=sum(session)' \
  --data-urlencode "query=release:$RELEASE_ID" \
  --data-urlencode 'statsPeriod=24h' "$API") || {
  echo "::error::Sentry API request failed; crash-free rate is unknown." >&2
  exit 2
}

printf '%s' "$RESPONSE" | python3 -c '
import json, math, sys
try:
    threshold = float(sys.argv[1])
    if not math.isfinite(threshold) or not 0 <= threshold <= 100:
        raise ValueError("threshold must be between 0 and 100")
    groups = json.load(sys.stdin)["groups"]
    if len(groups) != 1:
        raise ValueError("expected one aggregate with measured session data")
    totals = groups[0]["totals"]
    rate = totals["crash_free_rate(session)"]
    sessions = totals["sum(session)"]
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or not 0 <= rate <= 1:
        raise ValueError("invalid or absent crash-free rate")
    if isinstance(sessions, bool) or not isinstance(sessions, (int, float)) or not math.isfinite(sessions) or sessions <= 0:
        raise ValueError("no measured sessions")
except (KeyError, TypeError, ValueError) as error:
    print(f"::error::Crash-free evidence unavailable: {error}", file=sys.stderr)
    sys.exit(2)
print(f"Crash-free rate for {sys.argv[2]}: {rate * 100:.3f}% over {sessions:g} sessions (threshold: {threshold:g}%)")
if rate * 100 < threshold:
    print("::error::Measured crash-free rate is below threshold.", file=sys.stderr)
    sys.exit(1)
print("Measured crash-free rate meets threshold.")
' "$THRESHOLD" "$RELEASE_ID"
