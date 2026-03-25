# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the architecture reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because the issue exists to validate the planning-system architecture, not to modify the application architecture.

## 2026-03-25 — Issue #157 (HUD capture health)
All data sources (PermissionsManager, AudioInputDeviceManager, AppSettings, ModelCatalog.LatencyTier) are SpeakApp-only. CaptureHealth struct belongs in HUDManager.Snapshot, not SpeakCore. MainManager is the right aggregation driver. Static LatencyTier is the safe latency signal — avoid runtime sampling.

## 2026-03-25 — Issue #149: portable planning-memory topology

Maintainer raised the bar from "workflow validation" to "portable pattern for orgs with signed-commit rulesets". Architecture position: prefer Contents API writes (GitHub-verified by default) over branch exemptions or dedicated repos for single-repo cases. Dedicated repo is the right upgrade path at ≥3 repos. Decision rule: switch persistence mechanism before topology.

## 2026-03-25 — Issue #157: architecture approval confirmed, awaiting Code Quality

Architecture approved the HUD capture-health plan after maintainer confirmed three Combine-based refresh triggers (no polling) and plain-struct value semantics. Maintainer then directed Code Quality to respond. Architecture stance unchanged — no follow-up comment needed.
