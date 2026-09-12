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

# Reruns keep their run ID/number and increment run_attempt; the listing is
# runs, not an attempt history. Select a run without filtering by success,
# then read that run directly so its current attempt decides the gate.
RUN_ID=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs" \
  -f "head_sha=$RELEASE_SHA" -f branch=main -f event=push -f per_page=100 \
  --jq '.workflow_runs | sort_by([.run_number, (.run_attempt // 1)]) | last | .id // empty')
if [[ ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "::error::No CI run found for release commit $RELEASE_SHA." >&2
  exit 1
fi

RUN_STATE=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID" \
  --jq '[.head_sha, .event, .head_branch, .status, (.conclusion // "missing"), .run_attempt] | @tsv')
IFS=$'\t' read -r RUN_SHA RUN_EVENT RUN_BRANCH RUN_STATUS CONCLUSION RUN_ATTEMPT <<< "$RUN_STATE"
if [[ "$RUN_SHA" != "$RELEASE_SHA" || "$RUN_EVENT" != push || "$RUN_BRANCH" != main ]]; then
  echo "::error::CI run $RUN_ID does not match the requested main push commit." >&2
  exit 1
fi
if [[ "$RUN_STATUS" != completed || "$CONCLUSION" != success || ! "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::CI run $RUN_ID for $RELEASE_SHA has not succeeded (attempt: $RUN_ATTEMPT, status: $RUN_STATUS, conclusion: $CONCLUSION)." >&2
  exit 1
fi
echo "Verified successful main CI for $RELEASE_SHA (run $RUN_ID, attempt $RUN_ATTEMPT)."
