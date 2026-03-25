# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the architecture reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because the issue exists to validate the planning-system architecture, not to modify the application architecture.

## 2026-03-25 — Issue #157 (HUD capture health)
All data sources (PermissionsManager, AudioInputDeviceManager, AppSettings, ModelCatalog.LatencyTier) are SpeakApp-only. CaptureHealth struct belongs in HUDManager.Snapshot, not SpeakCore. MainManager is the right aggregation driver. Static LatencyTier is the safe latency signal — avoid runtime sampling.
