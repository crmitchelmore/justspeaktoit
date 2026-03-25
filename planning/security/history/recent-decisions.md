# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the security reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because the issue adds no new product attack surface and exists to verify that secret rotation restored automation.

## 2026-03-25 — Issue #157 (capture health HUD)
Approved. Low attack surface: all new HUD fields are categorical labels (permission bool, device name, provider name, latency bucket). Non-blocking caution: ensure health-state error text uses categorical labels, not raw provider API error bodies. HUDManager already exposes `subheadline` from raw `message` strings — implementation must guard this path.
