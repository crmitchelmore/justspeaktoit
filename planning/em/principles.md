# Facilitation Principles

## When to intervene
- ≥3 of 7 technical roles (Product/Alex, Security/Priya, Performance/Theo, Quality/Casey, Architecture/Morgan, Reliability/Jordan, Design/Riley) have commented
- AND: team is stuck, two roles are talking past each other, or maintainer explicitly asked

## Recurring dynamics (general patterns)
- Security ↔ Product: tension on auth/trust friction → resolves when Security proposes invisible controls
- Performance ↔ Architecture: tension on premature optimization → resolves when Theo frames concern as a concrete measurable question
- Quality ↔ everyone: Casey wants tests for everything → help prioritise critical paths only
- Architecture tends to defer scope to Product but holds firm on coupling/structural decisions

## Resolution strategies
- Deadlock between 2 roles → propose smallest experiment or clarification that would resolve it
- Open-ended performance worry → push Theo to a concrete question with a measurable threshold
- Security hard-req vs risk-acceptance → help Priya distinguish; ensure team explicitly acknowledges residual risk
- Operational concern raised late → help Jordan distinguish launch-blocking from post-launch-fixable

## Repository-specific context
- iOS and macOS tracks are separate; scoping issues to platform avoids cross-platform noise
- Automated improvement agents (Test Improver, Perf Improver, etc.) create many issues — these rarely need facilitation
- Planning labels gate the facilitation workflow
