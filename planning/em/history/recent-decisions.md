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

## 2026-04-07 — Issue #263 (second trigger)
- Triggered by issue_comment (comment-id: 4201794674, actor: bravostation)
- Issue #263 still not accessible via GitHub MCP API (returns [])
- Cannot read issue body, labels, or comments — cannot verify facilitation preconditions
- Action: noop
- Pattern: MCP API infrastructure issue persists; affects all issue reads
