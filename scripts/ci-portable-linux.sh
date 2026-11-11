#!/usr/bin/env bash
# The Portable Swift (Linux) CI job's checks. ci.yml, .github/workflows/precheck.yml
# and scripts/linux-precheck all run this, so a local pass means the CI job passes.
# Runs inside the swift:6.2.3-jammy image; JSTI_SCRATCH_PATH keeps a container run's
# build products away from the host's .build.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=()
if [ -n "${JSTI_SCRATCH_PATH:-}" ]; then scratch=(--scratch-path "$JSTI_SCRATCH_PATH"); fi
python3 scripts/ci/verify-portable-core-boundary.py
swift --version
scripts/ci/retry-network.sh swift package resolve "${scratch[@]}"
swift build --build-tests --jobs 4 "${scratch[@]}"
swift test --skip-build "${scratch[@]}"
