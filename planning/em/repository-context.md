# Repository Context

## Project
`crmitchelmore/justspeaktoit` — macOS + iOS voice-to-text app (JustSpeakToIt).

## Tech stack
- Swift, SwiftUI, SwiftPM, Tuist
- macOS (SpeakApp target) + iOS (SpeakiOSLib target) + SpeakCore (shared)
- AssemblyAI for live transcription, OpenAI for post-processing
- Automated releases via conventional commits → `mac-v*` tags

## Planning conventions
- Planning labels: `planning:*` signal active planning conversations
- Conventional commits drive automated mac releases (`feat:`, `fix:`, `perf:`)
- Automated/agentic issues (label: `agentic-workflows`) are not planning issues

## First EM run
2026-04-07: First run observed issue #208 (closed, automated test-improver bot PR — no planning labels, no kickoff comment). No facilitation needed.
