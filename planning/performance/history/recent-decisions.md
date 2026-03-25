# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the performance reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved immediately because no runtime code path or UX latency is changing.

## 2026-03-25 — Issue #157 (HUD capture health)
HUDManager is push-based (no polling); TranscriptionManager has session duration but no latency-bucket signal published to HUD. Latency signal design and update-rate cap are the two open performance items. Not yet approved.
