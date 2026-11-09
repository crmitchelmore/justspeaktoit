#!/usr/bin/env bash
# Registers each TESTFLIGHT_TESTER_EMAILS entry (as given and lowercased) as a
# log mask; the whole secret is masked by Actions, its parts are not.
set -euo pipefail
IFS=',' read -ra entries <<< "${TESTFLIGHT_TESTER_EMAILS:-}"
for entry in ${entries[@]+"${entries[@]}"}; do
  entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
  [ -n "$entry" ] || continue
  echo "::add-mask::$entry"
  echo "::add-mask::$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
done
