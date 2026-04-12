# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox
Full build/test blocked by Sentry firewall.
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
safeoutputs MCP: HTTP JSON-RPC http://host.docker.internal:80/mcp/safeoutputs; auth from mcp-config.json

## Backlog
1. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive regex
2. MEDIUM #252: NSRegex cache (PersonalLexiconService + PronunciationManager)

## Monthly: New issue created April 2026 (2026-04-12 run). #228 was closed by maintainer.

## Round-Robin
Last (2026-04-12 run 6): Tasks 3,7
Next: Tasks 1,2,5,6,7

## Open PRs
- NEW: perf-assist/incremental-transcript-append (2026-04-12, draft) — closes #246

## Notes
GitHub MCP read tools return empty (non-functional). Use safeoutputs HTTP MCP directly.
Previous PRs #258/#263 deleted by maintainer. Issue #228 closed by maintainer.
Issue #246 had /doit from bravostation + planning:ready-for-dev — implemented and PR submitted.
