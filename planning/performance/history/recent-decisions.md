# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the performance reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved immediately because no runtime code path or UX latency is changing.

## 2026-03-25 — Issue #157 (HUD capture health)
HUDManager is push-based (no polling); TranscriptionManager has session duration but no latency-bucket signal published to HUD. Latency signal design and update-rate cap are the two open performance items. Not yet approved.

## 2026-03-25 — Issue #149 re-opened design debate
Maintainer asked for concrete cost analysis on repo-memory persistence portability.
Decision: GitHub API signed commits (+1-3s/write) is the cheapest portable fallback that avoids org-level branch exemptions.
Key guardrail: cap memory file sizes (recent-decisions.md to ~10 entries) to keep read/write time constant regardless of mechanism.
External stores (Gist, artifact) are disproportionate for small text files.

## 2026-03-25 — Issue #157 performance-approved confirmed
Labels confirmed: planning:performance-approved already set. Only planning:needs-quality remains.
Guardrails for implementation: rate-limit health updates to state-transitions or ~1 Hz; KVO-driven device enumeration; latency shown as bucket not live average.

## 2026-03-25 — Issue #149: Contents API correction

Live throwaway-branch test showed `PUT /repos/{owner}/{repo}/contents/{path}` produced `verified: false`, `reason: unsigned` here. Do not treat Contents API writes as a signed-commit-safe default. For strict repos, prefer workflow commit signing as the portable default, with branch exemption as a repo-local fallback when governance allows it.

## 2026-03-25 — Issue #149 re-approved after explicit maintainer re-review request
Memory was already correct (Contents API = verified: false). Both remaining options (branch exemption, workflow commit signing) are cost-acceptable from Performance lens. Approved on maintainer's explicit ask. Note: Architecture's reply 4122824374 still cites Contents API as signed-safe — flagged for Architecture to correct.
