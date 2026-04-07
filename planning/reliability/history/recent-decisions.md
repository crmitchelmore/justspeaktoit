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
