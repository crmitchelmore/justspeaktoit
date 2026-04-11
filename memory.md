# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox
Full build/test blocked by Sentry firewall.
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
safeoutputs MCP: HTTP JSON-RPC http://host.docker.internal:80/mcp/safeoutputs; auth from mcp-config.json

## Backlog
1. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive regex
2. MEDIUM #252: NSRegex cache (PersonalLexiconService + PronunciationManager)
3. LOW #246: DeepgramLiveController O(N) rebuild

## Monthly: #228 April 2026. Updated 2026-04-11.

## Round-Robin
Last (2026-04-11 run 5): Tasks 3,7
Next: Tasks 2,5,6,7

## Open PRs
- #258: worddifer-measure-baselines-v2 (2026-04-09)
- #263: historymanager-o1-stats-wal-v2 (2026-04-09)
- NEW: worddifer-lcs-precompute-v3 (2026-04-11, draft)

## Notes
GitHub MCP read tools return empty (non-functional). Use safeoutputs HTTP MCP directly.
Duplicate tracking: #215→#240, #204→#201, #152/#216/#227→#252
