# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the quality reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because there is nothing substantive to implement from a code quality perspective.

## 2026-03-25 — Issue #157
Three blockers raised: (1) ownership shape for health state vs. recording state machine, (2) static vs. measured latency signal, (3) explicit update trigger list. CaptureHealthSnapshot belongs in SpeakApp, not SpeakCore. Test surface is SpeakAppTests unit tests.

## 2026-03-25 — Issue #157 — Capture health HUD
- Confirmed: `CaptureHealthSnapshot` as plain struct on `HUDManager` in `SpeakApp` only
- Static `LatencyTier` sufficient for v1; measured latency is a v2 concern
- Event-driven refreshes on exactly three publishers (permissions, device, model) — no polling
- Dedicated `updateCaptureHealth(_:)` method enforces clean call sites
- Key quality rule: plain struct with value semantics = trivially unit-testable without mocking
