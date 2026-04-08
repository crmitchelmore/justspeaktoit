# Recent Decisions

## 2026-04-07 — Memory seeded
Initialized reliability memory from repository inspection. Key facts verified:
- macOS release pipeline: fully automated via conventional commits → `mac-v*` tags → Sparkle appcast.
- No staging environment between merge and production for macOS.
- iOS has App Store review delay as natural gate.
- Sentry EU is the error monitoring layer.
- Issue #255 could not be read via GitHub MCP API (returned empty array); noop taken.

## 2026-04-07 — Issue #202 unreadable
GitHub MCP API returned empty arrays for issue #202 (get, get_comments, get_labels all returned []). Cannot verify planning labels or kickoff comment. Noop taken per operating constraints. Same pattern as issue #255.

## 2026-04-07 — Issue #209 skipped (no planning labels)
Issue #209 is a closed automated bot issue (Daily Test Improver) with labels `automation`, `testing`, `agentic-workflows`. No `planning:` labels and no planning kickoff comment. Noop taken per operating constraints.

## 2026-04-07 — Issue #152 unreadable
GitHub MCP API returned empty arrays for issue #152 (get, get_comments, get_labels all returned []). Same recurring pattern as issues #202, #255, #209. Cannot verify planning labels or kickoff comment. Noop taken per operating constraints.

## 2026-04-07 — Issue #246 unreadable
GitHub MCP API returned empty arrays for issue #246 (get, get_comments, get_labels all returned []). Same recurring pattern as issues #152, #202, #255. Cannot verify planning labels or kickoff comment. Noop taken per operating constraints — cannot approve or comment without verifiable issue context.

## 2026-04-07 — Issue #201 unreadable (integrity-filtered)
GitHub MCP API returned empty arrays for issue #201 (get, get_comments, get_labels all returned []). Confirmed integrity-filtered via search_issues. This is the 6th consecutive issue (after #152, #202, #246, #255, and one other) that has been unreadable. Noop taken per operating constraints — cannot approve or comment without verifiable issue context.

## 2026-04-08 — Issue #270 (iOS transcription text loss on silence)
Approved immediately at kickoff. iOS-only bug fix extending an existing pattern (`commitIfImplicitReset`, `restartRecognitionTask`). TestFlight provides natural staging gate. Key guardrails: address short-text threshold (< 10 chars), gradual-reset threshold, and add Sentry breadcrumb for observability. Task cancellation race in `restartRecognitionTask` appears safe due to `isShuttingDownRecognitionTask` flag, but flagged for implementation review.

## 2026-04-08 — Issue #157 (HUD capture health panel, macOS)
Approved. Purely additive read-only UI feature. Blast radius: HUD display layer only — no audio/transcription logic touched. Failure mode is graceful (stale display, not crash). Rollback: standard mac-v* re-tag. Combine subscriptions follow established setupBindings() pattern in MainManager. Static LatencyTier means zero measurement infrastructure. Security's categorical label guardrail is enforced by the type boundary (CaptureHealthSnapshot plain struct), which also bounds blast radius. No new monitoring surface needed.

## 2026-04-08 — Issue #277 skipped (no planning labels, closed, automated CI issue)
Issue #277 is a "CI Failure Doctor" automated issue (github-actions[bot]) about sentry-cocoa 9.8.0 → 9.9.0 bump failing CI. Labels: `automation`, `ci` — no `planning:` labels. Issue is already closed (state_reason: completed). No planning kickoff comment present. Noop per operating constraints. Notable content: sentry-cocoa minor bump (9.8→9.9) caused a transient CI failure likely due to SPM cache invalidation on a cold-cache run; no breaking API changes found. The CI failure investigation recommends: (1) manual re-run as first step, (2) `swift package resolve` pre-fetch with timeout-minutes guard, (3) stronger dependabot auto-merge gates for minor version bumps.

## 2026-04-08 — Issue #279 skipped (automated Perf Improver, no planning labels)
Issue #279 is a closed "Daily Perf Improver" automated bot issue (github-actions[bot]) proposing O(1) incremental stats and WAL write fix in HistoryManager. Labels: `automation`, `performance`, `agentic-workflows` — no `planning:` labels and no planning kickoff comment. Closed as `not_planned`. Noop per operating constraints.

## 2026-04-08 — Issue #283 (fix missing SpeakCore import, iOS)
Approved immediately. Compile-time-only fix (add `import SpeakCore` to SpeakiOSApp.swift). Verified OpenClawClient is in SpeakCore and usage is at line 93. No behavior change, no new failure modes. iOS TestFlight gate provides natural staging. Side note: fix(ios): commit type will trigger macOS auto-release (version bump, no behavior change) — acceptable known behavior.

## 2026-04-08 — Issue #263 (O(1) WAL + stats fix in HistoryManager)
Approved with guardrail. WAL fix removes a defensive disk re-read that matters in one edge case: `replayWAL` fails due to storage write IO error (WAL file persists with valid entries, `pendingWrites = []`). Implementation must handle this case: check `pendingWrites.isEmpty && walURL exists` → fall back to disk read. Stats fix is safe (all three helpers guard against nil cachedStatistics). Pre-existing `flushImmediatelySync` deadlock pattern noted but not introduced here.
