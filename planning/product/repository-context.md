# Repository Context

<!-- changelog: 2026-04-01 — added note on active automated improvement agents; updated issue #157 status; Sources/ verified accurate -->

## Durable facts for this role
- Just Speak to It is a SwiftUI voice-transcription product spanning macOS and iOS, with macOS as the richer primary surface.
- Core user moments are capture, live transcript, post-processing, smart output, and history/settings review.
- The product promise includes privacy-sensitive usage patterns, including on-device Apple Speech and explicit user control of cloud providers.
- Users manage API keys locally, so features should not assume app-managed accounts or hidden back-end state.
- Platform scope matters because hotkeys and accessibility-driven output are macOS-specific while iOS has different constraints.
- Good product issues in this repo should name the platform, the user moment, and whether the value is privacy, speed, accuracy, or workflow convenience.
- Issue #157 (live capture health HUD, macOS-only) is open as of 2026-04-01 — still pending an implementation PR.
- Automated improvement agents are now active: Test Improver (XCTest additions), Perf Improver (performance micro-optimisations), and daily repo-status + coordination issues flood the tracker. These are all agentic-workflow automation issues, not human product requests. Product should treat them as out of scope for planning validation.
