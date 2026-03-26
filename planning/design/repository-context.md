# Repository Context for Design

## App structure
- **macOS**: SwiftUI app in `Sources/SpeakApp/` — menu bar / HUD style
- **iOS**: SwiftUI views in `Sources/SpeakiOS/` + `SpeakiOSApp/`
- No web frontend, no CSS design tokens

## Design system reference
- Apple HIG is the design standard for both platforms
- Liquid Glass (iOS 26+) — see `.copilot/skills/liquid-glass.md`
- 8px spacing grid expected (from SwiftUI system defaults)
- SF Symbols for icons

## Agentic workflows
- Agent personas: `.github/agents/planning-*.agent.md`
- Workflows: `.github/workflows/issue-planning-*.yml`, `pr-plan-review-*.yml`
- Design role added in PR #188: `planning-design.agent.md`, `issue-planning-design.lock.yml`, `pr-plan-review-design.lock.yml`
- Issue planning requires 7 approvals (post PR #188)
- PR plan review requires 6 approvals (post PR #188)

## Labels (plan-review)
- `plan-review:needs-design` / `plan-review:design-approved`
- `plan-review:in-discussion` / `plan-review:ready-to-merge`
