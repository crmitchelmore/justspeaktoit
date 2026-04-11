# Copilot Instructions

Use `AGENTS.md` as the primary source of repository-specific guidance.

## Agentic workflow maintenance

- PRs that only change agentic workflow/runtime surfaces (`.github/workflows/**`, `.github/aw/**`, `.github/agents/**`, `.github/copilot-instructions.md`, `Docs/agentic-workflows.md`, `.vscode/*`, `.gitattributes`) should stay out of the full PR plan-review specialist lane by default.
- For those infra PRs, treat the normal verification lanes as the merge gate and only request deeper specialist review when a maintainer explicitly wants it.
