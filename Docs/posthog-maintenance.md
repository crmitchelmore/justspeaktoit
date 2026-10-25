# PostHog maintenance

VS Code/Copilot uses `posthog` in `.vscode/mcp.json`. Start that MCP server and
complete its OAuth prompt; select the JustSpeakToIt organization/project and
verify its identity before reading data. The hosted endpoint routes US/EU from
the authenticated account. Keep OAuth tokens in the client's credential store.

Other MCP clients can add `https://mcp.posthog.com/mcp` using their HTTP/OAuth
configuration. If OAuth is unavailable, use a scoped personal API key through
the client's secret input/environment and an Authorization header; never put
the key in this repository, arguments, URLs or logs. Resolve keys from the
authorized credential vault when needed.

For an authorized maintenance or release check:

1. Inspect top errors and new exceptions since the previous shipped version;
   retain issue links, affected versions/counts and the query's time window.
   Reproduce actionable defects and deduplicate GitHub/Beads issues before filing.
2. Inspect stale and fully rolled-out flags against current callers; propose
   removal with evidence before changing production flag behavior.
3. Compare key event/insight trends across the release boundary. Verify event
   names, consent coverage and sample size first; absent telemetry is unknown.

Report observations separately from installed-app and release acceptance.
Do not enable telemetry, change consent or create scheduled jobs implicitly.
MCP access is free, but underlying usage and AI-powered tools can incur PostHog
charges; avoid unneeded AI analysis and report any unavailable scopes.

Sources: [VS Code setup](https://posthog.com/docs/model-context-protocol/vscode),
[authentication and billing](https://posthog.com/docs/model-context-protocol/faq).
