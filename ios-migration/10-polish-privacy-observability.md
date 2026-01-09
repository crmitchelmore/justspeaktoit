# 10 — Polish: Privacy, Reliability, Observability

## Goal
Ship-quality behavior: resilient sessions, clear privacy story, and debuggability.

## Scope
- Handle edge cases (permissions, interruptions, route changes).
- Add lightweight logging.
- Add user-facing privacy notes.

## Steps
1. Add consistent user messaging for:
   - missing permissions
   - offline/network errors
   - missing API keys
2. Implement session resilience:
   - auto-reconnect for Deepgram (bounded)
   - clean shutdown on interruption
3. Add logging:
   - unify on `os.Logger`
   - add toggled debug mode in settings
4. Document privacy:
   - what audio is captured
   - what is sent to providers

## Deliverables
- Robust UX with fewer “mystery failures”.

## Acceptance criteria

> **BLOCKING REQUIREMENT**: Do not proceed to the next task until ALL acceptance criteria above are verified and passing.
- Common failure modes are explained with actionable steps.
- Logs are sufficient to diagnose provider/network issues.
