# Recent Decisions

## 2026-03-25 — Issues #162, #174, #180
Approved after maintainer provided concrete decisions. Pattern: concrete deterministic decisions required before approval. Workflow-only PRs that match scope approve on first pass.

## 2026-03-26 — PRs #186, #189, #191: Blocked
Pattern: always require explicit plan link even for small/hotfix PRs.

## 2026-04-07 — Issue #246: First pass
Raised: (1) scope ambiguity on AssemblyAI, (2) measure{} proves perf not correctness.

## 2026-04-08 — Issue #270: First pass
Three failure modes: commitIfImplicitReset too coarse, error path discards latestResult, silent task termination. Structural: no SpeakiOSTests in Package.swift — iOS commit logic untestable via make test.

## 2026-04-08 — Issue #246: Approved (second pass)
Scope resolved (Files = Deepgram only). Correctness test deferred to PR as non-negotiable guardrail: XCTAssertEqual for final transcript text must accompany measure{}.

## 2026-04-08 — PR #128: Blocked (docs-only, missing plan link)
Pattern continues: plan link required even for docs-only PRs.

## 2026-04-08 — Issues #271, #283, #256: Approved (first pass)
#271: landing-page CSS/JS, manual browser verification appropriate. #283: one-line import fix, compiler-enforced. #256: test-only addition for pure value types.

## 2026-04-09 — Issue #246: Re-confirmed approval (label state repair)
Labels showed needs-quality despite prior approval. Architecture since approved (was last blocker). Re-applied quality-approved. Pattern: when memory and label state diverge, re-confirm stance explicitly.
