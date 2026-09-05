#!/usr/bin/env bash
# Fail closed unless this exact commit is current main and its latest push CI
# succeeded. Used for both automatic releases and manual Auto Release retries.
set -euo pipefail

RELEASE_SHA="${1:?Usage: $0 <release-commit-sha>}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
if [[ ! "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Release commit must be a full Git SHA." >&2
  exit 1
fi

MAIN_SHA=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq '.object.sha')
if [[ "$MAIN_SHA" != "$RELEASE_SHA" ]]; then
  echo "::error::Release commit is no longer current main; wait for CI on the new main commit." >&2
  exit 1
fi

# Do not filter by success: an older successful run must not hide a newer
# failed, cancelled, or still-running CI run for the same commit.
CONCLUSION=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs" \
  -f "head_sha=$RELEASE_SHA" -f branch=main -f event=push -f per_page=100 \
  --jq '.workflow_runs | sort_by(.run_number) | last | .conclusion // "missing"')
if [[ "$CONCLUSION" != success ]]; then
  echo "::error::CI for release commit $RELEASE_SHA has not succeeded (latest conclusion: $CONCLUSION)." >&2
  exit 1
fi
echo "Verified successful main CI for $RELEASE_SHA."
