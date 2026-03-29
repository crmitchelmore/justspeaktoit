# Repository Context

<!-- changelog: 2026-03-29 — verified tech stack still accurate; Sources/ now includes SpeakHotKeys/SpeakSync but product context unchanged; Docs/ has new team-personalities.md and IOS_DISTRIBUTION_AND_TRANSCRIPTION_HUD.md -->

## Durable facts for this role
- Just Speak to It is a SwiftUI voice-transcription product spanning macOS and iOS, with macOS as the richer primary surface.
- Core user moments are capture, live transcript, post-processing, smart output, and history/settings review.
- The product promise includes privacy-sensitive usage patterns, including on-device Apple Speech and explicit user control of cloud providers.
- Users manage API keys locally, so features should not assume app-managed accounts or hidden back-end state.
- Platform scope matters because hotkeys and accessibility-driven output are macOS-specific while iOS has different constraints.
- Good product issues in this repo should name the platform, the user moment, and whether the value is privacy, speed, accuracy, or workflow convenience.
- Issue #157 (live capture health HUD, macOS-only) is open as of 2026-03-29 — the first product-feature issue tracked in memory. Watch for implementation PR.
