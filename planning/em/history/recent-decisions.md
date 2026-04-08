# Recent Facilitation Decisions

## 2026-04-07 — Issue #236
- Triggered by issue_comment (comment-id: 4200738149)
- Issue #236 not accessible via GitHub MCP API (returned empty)
- Cannot read issue body, labels, or comments — cannot facilitate
- Action: noop

## 2026-04-07 — Issue #247
- Triggered by issue_comment (comment-id: 4200740525)
- Issue #247 not accessible via GitHub MCP API (returned empty)
- Cannot read issue body, labels, or comments — cannot facilitate
- Action: noop
- Pattern: Same MCP API issue as #236 — persistent infrastructure limitation

## 2026-04-07 — Issue #263
- Triggered by issue_comment from bravostation (comment-id: 4200757943)
- Comment contained `/doit` — manual planning command workflow owns this path
- No `planning:` labels on issue; no planning kickoff comment present
- 0 of 7 technical roles commented
- Action: noop

## 2026-04-07 — Issue #246
- Triggered by issue_comment (comment-id: 4201795567) from bravostation
- Issue: [Perf Improver] O(N) map+join → O(1) incremental append in DeepgramLiveController
- Issue body accessible via search; comments API returned empty
- Labels confirm: only Jordan (Reliability) has approved so far
- 1 of 7 technical roles commented — below EM threshold (≥3 required)
- Action: noop

## 2026-04-08 — Issue #201
- Triggered by issue_comment (comment-id: 4202947672) from bravostation
- Issue: [Perf Improver] perf(mac): replace lowercased+distance with caseInsensitive search in TranscriptionTextProcessor
- Labels: automation, performance, agentic-workflows — NO planning: labels
- This is an automated Perf Improver bot issue, not a planning discussion
- Comments API returned empty (persistent MCP infrastructure issue)
- Per protocol: no planning: labels + cannot confirm planning kickoff = do nothing
- Action: noop
