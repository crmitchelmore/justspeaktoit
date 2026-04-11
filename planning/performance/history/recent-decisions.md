# Recent Decisions

## 2026-03-25 — PR #177 approved
docs(agentic-workflows): pure documentation-only PR. Plan issue #176 fully approved. No performance concern. Auto-approved immediately.

## 2026-03-25 — Issue #180 (ignore closed-PR comments in plan-review workflows)
Pure CI guard change. Adds open-PR state check to prevent spurious workflow runs on closed PRs. No runtime code. Approved immediately — reduces workflow fan-out waste, consistent with prior agentic-workflow pattern approvals (#174, #176).

## 2026-03-25 — PR #181 (ignore closed PR comments — implementation)
Pure CI guard change linked to approved issue #180. Approved immediately — same pattern as PR #175/#177. All agentic-workflow CI-only PRs are outside app performance scope.

## 2026-03-26 — PR #186 (AgenTek planning team improvements)
Pure CI/agentic-workflow change (new planning roles, persona enrichment, inter-agent memory). No runtime code. Blocked only on missing linked planning issue — PR body has no Closes/Fixes/Refs link to a planning:ready-for-dev issue. Same class as approved PRs #175/#177/#181 but those had explicit issue links.

## 2026-03-26 — PR #188 (add Riley Tan Design/UX role)
Pure CI/agentic-workflow change. No runtime code. Blocked on missing linked planning issue — same as PR #186. Fan-out increases 7→8 workflow runs/event; acceptable. Will approve immediately once a planning:ready-for-dev issue link is provided.

## 2026-03-26 — PR #191 (disable failure issue creation on all workflows)
Pure CI/workflow change. No runtime code. Blocked on missing linked planning issue — same class as PR #186/#188. Will approve immediately once planning:ready-for-dev issue link is provided. No app performance concern.

## 2026-04-08 — PR #128 (docs: release and transcription troubleshooting notes)
Pure documentation-only PR. No runtime code changes. Blocked on missing linked planning issue — PR body has no Closes/Fixes/Refs link. Same class as PRs #186/#188/#191. No app performance concern whatsoever. Will approve immediately once a planning:ready-for-dev issue link is provided.

## 2026-04-08 — Issue #270 (iOS Apple live transcription text reset)
Approved. Fix is confined to `iOSLiveTranscriber.swift`: threshold adjustment and error-path commit. Both changes are O(1) on the existing hot path. Restart latency is pre-existing. Three roles (Architecture, Reliability, Quality) converged on error-path commit as the key gap — performance confirms it's cheap to fix.

## 2026-04-08 — Issue #271 (fix: burger menu on landing page mobile)
Pure landing-page CSS/JS fix. No app code. Approved immediately — entirely cold path. Pattern: all `landing-page/` changes are outside app performance scope.

## 2026-04-08 — PR #282 (fix(ios): add missing SpeakCore import)
One-line compile fix. No runtime cost. PR already merged before plan-review ran. No action taken per closed-PR protocol. Pattern: trivial import-scope compile fixes have zero app performance concern.

## 2026-04-08 — Issue #283
One-line import fix (compile-time only). Approved without questions. Pattern: compile-only changes with no runtime path touched are instant approvals from the performance lane.

## 2026-04-08 — Issue #256 (test(core): error description, header redactor, API validation tests)
Pure test-only additions to SpeakCoreTests. 40 value-type assertions, no runtime code. Approved immediately. Pattern: test-only issues with no production code changes have zero app performance concern — approve without questions.

## 2026-04-09 — Issue #270 (re-approval after /doit label reset)
Same issue, same fix, same approval reasoning as 2026-04-08. A second /doit reset all labels; re-approved immediately. Pattern: when /doit resets a previously fully-approved issue with no content changes, re-approval requires no new analysis — just confirm issue is unchanged and re-state prior rationale.

## 2026-04-10 — PR #298 (fix(mac): disable HUD glass effect on macOS 26)
Merged before plan-review completed. `issue_comment` trigger on merged PR → noop per protocol. Notable: commit 2 adds `static let isGlassEffectEnabled` to cache `canUseGlassEffect()` — correct hot-path optimization (HUD renders per frame during recording; avoiding repeated `ProcessInfo.processInfo.operatingSystemVersion` reads is the right call). No linked planning issue in PR body. Pattern: hot-path `static let` caches for OS-version gates are always acceptable without a planning issue.

## 2026-04-10 — Issue #283 (re-approval after /doit label reset)
Same as prior run. One-line compile-time import fix. /doit reset all labels on 2026-04-09. Re-approved immediately on 2026-04-10. All 7 roles had already approved. Re-approval triggered ready-for-dev. Pattern: identical to issue #270 reset pattern — no new analysis needed.

## 2026-04-11 — PR #300 (chore(agentic-workflows): sync improved planning flow)
Pure agentic-workflow infra sync. 89 files changed, all in .github/ and Docs/agentic-workflows.md. Zero app runtime code. Per custom instructions, agentic-workflow surface PRs stay out of the specialist review lane by default — approved without requiring a linked planning issue. New retry workflows (issue-agent-retry.yml, pr-plan-review-rate-limit-retry.yml) use concurrency groups correctly (idempotent fan-out control). Pattern: large agentic-workflow sync PRs touching only .github/ are auto-approved from performance lens without planning issue requirement.
