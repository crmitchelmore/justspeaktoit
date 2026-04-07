# Recent Decisions

## 2026-04-07 — Memory seeded
Initialized reliability memory from repository inspection. Key facts verified:
- macOS release pipeline: fully automated via conventional commits → `mac-v*` tags → Sparkle appcast.
- No staging environment between merge and production for macOS.
- iOS has App Store review delay as natural gate.
- Sentry EU is the error monitoring layer.
- Issue #255 could not be read via GitHub MCP API (returned empty array); noop taken.
