# Copilot instructions

Follow [AGENTS.md](../AGENTS.md); it is the authoritative guide for this repository.

## Before every PR or push

1. Run `scripts/pre-pr` (or `make pre-pr`). It selects the fast lint, build and
   unit-test checks for the paths changed against `origin/main`. It never runs UI
   tests or foreground automation.
2. Fix every failure and re-run until it passes. Do not open or push a PR on a
   failing run; if a failure is genuinely unrelated, say so in the PR body.
3. Paste the output of `scripts/pre-pr --markdown` (also saved to
   `.build/pre-pr/summary.md`) into the PR body's **Pre-PR checks** section,
   keeping its hidden `pre-pr-summary` marker. Re-run and update it after
   material changes.
