# Repository Context

## Project
JustSpeakToIt — macOS + iOS speech-to-text / voice assistant app (SwiftUI, Swift Package Manager, Tuist)

## Planning cadence
- Issues labelled `planning:*` trigger the multi-role review workflow
- Automated agents (Test Improver, Perf Improver, Coordination, Repo Status) create many issues — these use `automation` label and rarely receive planning-team reviews
- Conventional commits drive auto-release: feat/fix/perf → mac-v* tag

## Team roles
- Alex → Product
- Priya → Security
- Theo → Performance
- Casey → Code Quality
- Morgan → Architecture
- Jordan → Reliability
- Riley → Design

## Observed issue patterns (seeded 2026-04-07)
- Most open issues are automation-generated (test improver, perf improver, coordination)
- Human-initiated planning issues tend to be feature or fix proposals with platform scope
- Integrity filtering occasionally prevents reading older/lower-trust issues
