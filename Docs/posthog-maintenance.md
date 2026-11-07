# PostHog maintenance

VS Code/Copilot uses `posthog` in `.vscode/mcp.json`. Start that MCP server and
complete its OAuth prompt; select the organization's approved **Production**
project and verify its identity before reading data. Do not create or fund a
Development project; see the [analytics audit](analytics-implementation-audit.md).
The hosted endpoint routes US/EU from
the authenticated account. Keep OAuth tokens in the client's credential store.

Other MCP clients can add `https://mcp.posthog.com/mcp` using their HTTP/OAuth
configuration. If OAuth is unavailable, use a scoped personal API key through
the client's secret input/environment and an Authorization header; never put
the key in this repository, arguments, URLs or logs. Resolve keys from the
authorized credential vault when needed.

For an authorized maintenance or release check:

1. Inspect production crashes and exceptions in **Sentry** (`tally-lz`, project
   `justspeaktoit`, EU region), using the reliability-monitoring configuration
   in `AGENTS.md`. The app's PostHog transport excludes error capture. For Sentry,
   retain issue links, affected versions/counts and the query's time window.
   Reproduce actionable defects and deduplicate GitHub/Beads issues before filing.
2. Inspect stale and fully rolled-out flags against current callers; propose
   removal with evidence before changing production flag behavior.
3. In PostHog, compare consented product-event trends across the release boundary. Verify event
   names, consent coverage and sample size first; absent telemetry is unknown.

Report observations separately from installed-app and release acceptance.
Do not enable telemetry, change consent or create scheduled jobs implicitly.
MCP access is free, but underlying usage and AI-powered tools can incur PostHog
charges; avoid unneeded AI analysis and report any unavailable scopes.

Sources: [VS Code setup](https://posthog.com/docs/model-context-protocol/vscode),
[authentication and billing](https://posthog.com/docs/model-context-protocol/faq).

## 12-month retention purge

The owner chose a scheduled purge (#776) to enforce the published promise that
raw product events are kept for no more than 12 months.
[`posthog-retention-purge.yml`](../.github/workflows/posthog-retention-purge.yml)
runs `.github/scripts/posthog-retention-purge.mjs` on the 1st of each month
(and on manual dispatch, `main` only). It uses PostHog's self-service
[Data Deletion Requests API](https://posthog.com/docs/api/data-deletion-requests):
it previews a HogQL query selecting the UUIDs of events whose `timestamp` is
before midnight UTC 365 days ago, then submits one idempotent deletion request.
It prints counts and request statuses only, and is a no-op until configured.

What it does not guarantee: PostHog processes requests asynchronously, so a
successful run means "submitted", not "erased"; check later runs' status
counts. With a monthly cadence an event can be up to about a month older than
the window before the next run catches it. Set the environment variable
`POSTHOG_RETENTION_DAYS` (for example `330`) if a strict 12-month ceiling is
needed. PostHog's plan-level [events retention](https://posthog.com/docs/data/events-retention)
is a backstop only: it deletes expired events "at any point". Person profiles
are not events and are not removed by this job.

Owner setup:

1. In PostHog EU, create a personal API key scoped to the **Production**
   project only, with **Data deletion: Write** (read is needed for status) and
   no other scopes.
2. In GitHub, create environment `posthog-purge` with a deployment branch
   policy allowing `main` only.
3. In that environment add secret `POSTHOG_PURGE_API_KEY` and variable
   `POSTHOG_PROJECT_ID` (the numeric Production project ID).
4. Run **PostHog retention purge** with `dry_run` true and check the count,
   then once with `dry_run` false. The schedule then runs live.

GeoIP one-off: the seven historical test events carrying GeoIP city/postcode
data are deleted with the same API. Run the workflow with mode
`geoip-test-events`, first with `dry_run` true (expect `Matching events: 7`),
then false. The script selects events whose properties contain
`$geoip_city_name` or `$geoip_postal_code` and refuses if more than seven
match.
