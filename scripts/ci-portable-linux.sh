#!/usr/bin/env bash
# The Portable Swift (Linux) CI job's checks. ci.yml, .github/workflows/precheck.yml
# and scripts/linux-precheck all run this, so a local pass means the CI job passes.
# Runs inside the swift:6.2.3-jammy image; JSTI_SCRATCH_PATH keeps a container run's
# build products away from the host's .build.
# JSTI_SWIFT_TEST_PARALLEL=1 (scripts/linux-precheck's container mode) runs the tests across
# processes, then reruns only the failures one at a time; a test that fails again fails the run.
# A few timing-sensitive tests can fail under parallel load, so CI keeps the plain serial run.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=()
if [ -n "${JSTI_SCRATCH_PATH:-}" ]; then scratch=(--scratch-path "$JSTI_SCRATCH_PATH"); fi
python3 scripts/ci/verify-portable-core-boundary.py
swift --version
scripts/ci/retry-network.sh swift package resolve "${scratch[@]}"
swift build --build-tests --jobs 4 "${scratch[@]}"
if [ "${JSTI_SWIFT_TEST_PARALLEL:-0}" != 1 ]; then
  swift test --skip-build "${scratch[@]}"
  exit 0
fi
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if swift test --skip-build --parallel --num-workers "${JSTI_SWIFT_TEST_WORKERS:-$(nproc)}" "${scratch[@]}" 2>&1 | tee "$log"; then
  exit 0
fi
# XCTest names a failure "Test Case 'Class.method' failed"; rerun those serially. Anything else
# (a Swift Testing failure or a crashed worker) reruns the whole suite serially.
filters=()
while IFS= read -r name; do
  filters+=(--filter "\\b${name%%.*}/${name#*.}\$")
done < <(sed -nE "s/^Test Case '([A-Za-z0-9_]+\.[A-Za-z0-9_]+)' failed.*/\1/p" "$log" | sort -u)
if [ ${#filters[@]} -eq 0 ] || grep -qE '✘|Fatal error|signal [0-9]+|exited with' "$log"; then
  echo "ci-portable-linux: the parallel run failed; rerunning every test serially" >&2
  swift test --skip-build "${scratch[@]}"
else
  echo "ci-portable-linux: rerunning $(( ${#filters[@]} / 2 )) failed test(s) serially: ${filters[*]}" >&2
  swift test --skip-build "${filters[@]}" "${scratch[@]}"
fi
