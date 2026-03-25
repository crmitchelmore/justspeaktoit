# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the quality reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because there is nothing substantive to implement from a code quality perspective.

## 2026-03-25 — Issue #157
Three blockers raised: (1) ownership shape for health state vs. recording state machine, (2) static vs. measured latency signal, (3) explicit update trigger list. CaptureHealthSnapshot belongs in SpeakApp, not SpeakCore. Test surface is SpeakAppTests unit tests.
