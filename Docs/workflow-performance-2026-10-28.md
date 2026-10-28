# Workflow failure and efficiency review — 28 October 2026

Reviewed the 500 most recent GitHub Actions runs through the connected GitHub
API and inspected representative failed job logs. This is a bounded recent
sample, including experimental branches and cancellations, not a reliability
SLO. Elapsed workflow time includes runner queues and job dependencies; it must
not be reported as billed execution time.

| Workflow | Runs | Failed | Cancelled | Observation and change |
| --- | ---: | ---: | ---: | --- |
| Apple reconciliation | 2 | 1 | 0 | Failed job ran 14.2 minutes, revisiting historical rejected uploads and receiving Apple HTTP 500s. Select active Alpha manifests, retain Stable publication observation, retry transient reads, bound HTTP timeouts, shallow-fetch the release ledger, and use Ubuntu instead of a Mac. |
| CodeQL | 35 | 1 | 13 | Successful sampled job ran 40.6 minutes; average successful workflow elapsed time was 85.6 minutes including queues. Failed run had dependency clone/network errors. Cache dependency sources, retry resolution, pin Xcode 26.2 and the hosted runner, and skip compilation for unrelated PR paths using a cheap job. Keep full main/weekly scans and the existing check name. |
| Tessl review | 31 | 13 | 1 | Repeated advisory service/action failures. Make invocation explicit through the existing trusted comment or manual dispatch paths; preserve the action and author checks. |
| Dependabot auto-merge | 182 | 0 | 25 | Most wakeups in this sample were unrelated to dependency PRs. Filter workflow/status wakeups to dependency branches; retain manual and daily reconciliation and all merge-policy gates. |
| CI | 42 | 6 | 28 | Sampled successful jobs include 23.2-minute iOS compilation, 22.2-minute Mac Debug and 18-minute simulator execution. Latest failed sample failed simulator execution. Keep required gates and existing superseded-PR cancellation; do not hide product/test failures or enlarge timeouts. |
| Windows ARM64 | 24 | 11 | 7 | Latest failed sample is an experimental diagnostic branch: build and tests passed, native window smoke failed. Keep native execution acceptance. |
| Windows cross proof | 22 | 5 | 10 | Failed sample hit a 30-second PowerShell packaging fixture deadline. More recent sampled runs passed. Keep bundle/MSIX lifecycle acceptance. |
| Windows and portable Swift | 27 | 0 | 16 | Keep native and portable coverage; cancellations are already limited to superseded PR work. |
| Linux Desktop / Flatpak | 25 each | 0 | 5 each | Different acceptance surfaces: GTK/native integration versus installed sandbox runtime. Retain both. |
| Desktop icons | 22 | 0 | 0 | Cheap resource validation; retain. |
| Local transcription benchmark | 12 | 0 | 4 | Distinct performance qualification; retain. |

Evidence: [Apple reconciliation](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40697423564),
[successful CodeQL](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40758356143),
[failed CodeQL](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40693500970),
[successful CI](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40720340189),
[ARM64 diagnostic branch](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40755915577),
[packaging fixture failure](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40706474187).

## Reconciliation behavior

Scheduled runs select the newest Alpha by numeric ordinal, plus Alphas selected
by frozen Stable candidates, excluding expired Alphas. Every Stable candidate
remains observable for its independent Apple publication boundary. A historical
rejection no longer poisons every hourly run unless it is still selected for a
Stable candidate. `workflow_dispatch` accepts an optional immutable `tag` for
explicit historical troubleshooting, including expired builds.

API GETs retry HTTP 429/500/502/503/504 at most three attempts. Authentication,
validation errors and writes are not replayed. All Apple HTTP calls have finite
connect/read/write timeouts. Current-build rejection and identity mismatches
remain failures; processing and beta review remain pending. In particular,
`BETA_APPROVED` alone still does not manufacture a verified public-beta receipt.

The reconciliation workflow keeps one active run and the newest pending request,
rather than queueing every stale scheduled snapshot. Test and review gates remain
unchanged for publication. Speedups require hosted measurements after merge;
local tests do not establish Apple readiness or native-platform success.
