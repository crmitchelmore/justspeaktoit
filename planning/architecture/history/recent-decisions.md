# Recent Decisions

## 2026-04-07 — Issue #169 (AudioBufferPool tests)
Issue #169 is not a pull request — it was created by the Daily Test Improver workflow and describes new tests for `AudioBufferPool`. The PR lane workflow was triggered by an `issue_comment` on this issue, but the trigger condition requires the comment to belong to a PR. No action taken. Architecture review does not apply here.

## 2026-04-07 — PR #209
PR #209 is not accessible via the GitHub API (returns empty results for all methods: get, get_diff, get_files, get_comments, get_reviews). It does not appear in the open or closed PR list. It is likely merged, deleted, or converted. No action taken per protocol: cannot verify live PR context.

## 2026-04-07 — Issue #260 ([Test Improver] Codable round-trips)
Issue #260 carries only `automation`, `testing`, and `agentic-workflows` labels — no `planning:` labels and no Planning Kickoff comment. Architecture review does not apply per the do-nothing rule.

## 2026-04-07 — PR #252
PR #252 is not accessible via the GitHub API (all read methods: get, get_comments, get_diff, get_files return empty results). It does not appear in the open or closed PR list. Cannot verify live PR context or linked planning issue. No action taken per protocol.

## 2026-04-07 — Issue #212 ([Test Improver] Add AudioBufferPool unit tests)
Issue #212 is not a pull request — it's a test-improver automation issue with labels `automation`, `testing`, `agentic-workflows`. The workflow was triggered by an `issue_comment` on this issue. Per protocol, no action taken: comment belongs to an issue, not a PR.

## 2026-04-08 — Issue #270 (Apple live transcription clears text after speech pause)
Approved. Fix is scoped to `iOSLiveTranscriber.swift` only. Existing `committedText` accumulation pattern is the right seam; two gaps to close: (1) error callback path needs to commit `lastFormattedString` before returning, (2) `commitIfImplicitReset` threshold (>= 10 chars) doesn't protect short utterances. No cross-module changes needed.

## 2026-04-08 — Issue/PR #272 (trigger: issue_comment)
Item #272 is not accessible via the GitHub API — not found as an open or closed PR (highest seen: #267), and not retrievable as an issue. The comment trigger (comment-id: 4204431736) points to a non-existent or inaccessible item. Per protocol, architecture review cannot proceed without verifiable PR context. No action taken.
