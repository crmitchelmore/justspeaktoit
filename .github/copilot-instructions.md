# Copilot instructions

Follow [AGENTS.md](../AGENTS.md); it is the authoritative guide for this repository.

## Before every PR or push

1. Run `scripts/pre-pr` (or `make pre-pr`). It runs what the CI Gate's
   pull-request jobs run for the paths changed against `origin/main`, with the
   same commands: `make ci-lint`, the portable Linux tests in the CI image, and
   the macOS build and affected unit tests. It never runs UI tests or foreground
   automation.
2. Fix every failure and re-run until it passes. Do not open or push a PR on a
   failing run; if a failure is genuinely unrelated, say so in the PR body.
3. Paste the output of `scripts/pre-pr --markdown` (also saved to
   `.build/pre-pr/summary.md`) into the PR body's **Pre-PR checks** section,
   keeping its hidden `pre-pr-summary` marker. Re-run and update it after
   material changes.
