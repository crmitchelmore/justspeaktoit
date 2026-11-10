#!/usr/bin/env bash
# The Public API compatibility CI job. ci.yml and scripts/pre-pr both run this,
# so a pre-pr pass means the job passes.
#
#   scripts/ci-api-compatibility.sh <baseline-treeish>
#
# PR_TITLE: the pull request title. A conventional '!' marker declares an
# intentional break (scripts/check-api-compatibility.sh). When PR_TITLE is
# unset or JSTI_API_TITLE_FROM_COMMITS=1 (pushes, merge batches, local runs
# without an open PR), any breaking subject in <baseline>..HEAD declares it.
set -euo pipefail
cd "$(dirname "$0")/.."
BASELINE="${1:?usage: ci-api-compatibility.sh <baseline-treeish>}"

python3 -B -m unittest discover -s scripts/tests -p test_api_compatibility.py
scripts/retry-network.sh swift package resolve

if [ -z "${PR_TITLE:-}" ] || [ "${JSTI_API_TITLE_FROM_COMMITS:-}" = 1 ]; then
    PR_TITLE=$(git log --format=%s "$BASELINE..HEAD" | grep -E '^[a-z]+(\([^)]*\))?!:' | head -n 1 || true)
fi
PR_TITLE="$PR_TITLE" bash scripts/check-api-compatibility.sh "$BASELINE"
