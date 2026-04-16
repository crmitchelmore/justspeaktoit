# Copilot Instructions

Use `AGENTS.md` as the primary source of repository-specific guidance.

## Agentic workflow maintenance

- PRs that only change agentic workflow/runtime surfaces (`.github/workflows/**`, `.github/aw/**`, `.github/agents/**`, `.github/copilot-instructions.md`, `Docs/agentic-workflows.md`, `.vscode/*`, `.gitattributes`) should stay out of the full PR plan-review specialist lane by default.
- For those infra PRs, treat the normal verification lanes as the merge gate and only request deeper specialist review when a maintainer explicitly wants it.
- For scheduled or reporting workflows, prefer updating a rolling issue or an existing thread over opening a fresh issue every run.
- Only create automated issues for durable maintainer action; suppress no-op, status-only, and transient-failure issue output where possible.
- Keep automated issue bodies concise: problem, evidence, next action, done when.
- For scheduled improver workflows, maintain existing automation PRs/issues before opening new ones; cap new PR creation to one item at a time and pause new PRs entirely when that workflow already has a small backlog.
