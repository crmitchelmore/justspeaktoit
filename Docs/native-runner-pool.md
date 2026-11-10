# Reviewed native runner pool

The non-UI macOS CI jobs (Debug and Release tests, lint, the core-journey contract and API compatibility), the iOS SwiftPM library build, unsigned iOS keyboard/watch builds, Portable Swift on macOS and the local-transcription benchmark package can use the native pool.

## Routing

Every guarded job uses one expression (`scripts/tests/self-hosted-routing.test.mjs` enforces it):

| Source | Route |
| --- | --- |
| `push` or `schedule` on `refs/heads/main` of this repository | Self-hosted pool automatically. No manual SHA. |
| Same-repository `pull_request` whose head equals `JSTI_NATIVE_APPROVED_SHA` | Self-hosted pool (per-SHA owner review). |
| Any other PR, forks, `workflow_dispatch`, `workflow_run`, `workflow_call` from those, tags and other branches | Hosted fallback. |

Merged `main` commits have already passed review and the required gates, which is what AGENTS.md permits ("main pushes and approved same-repo SHAs"). Dispatch stays hosted because any writer, including an agent session, can start it with arbitrary inputs.

Controls (repository variables, or `scripts/runner-admission/pool.sh`):

- `JSTI_SELF_HOSTED_MAIN=off` returns all `main` jobs, Mac and Linux, to hosted runners (`pool.sh main-off`; `main-on` deletes it). Self-hosted jobs never fall back on their own, so switch this off before taking a whole pool offline.
- `JSTI_NATIVE_RUNNER_LABELS` (default `["jsti-reviewed-local","macOS"]`) and `JSTI_LINUX_RUNNER_LABELS` (default `["self-hosted","Linux","X64","omarchy-local"]`) select the pools. Set either to a hosted label such as `["macos-latest"]` to return just that pool.
- `JSTI_NATIVE_APPROVED_SHA` admits one reviewed PR head, as before.

The pool defaults to `["jsti-reviewed-local","macOS"]`. Never use `jsti-macos-build` as a pool label: mac-mini-3, the owner's active Mac, also carries it. Every native-routed job is architecture-neutral, so the pool spans both architectures; add `ARM64` or `X64` only to restrict the whole pool. Labels and variables are scheduling controls, not a security boundary: each runner must independently enforce its admission hook before any job step runs.

Release, Alpha, Stable and publication jobs stay on hosted runners. They hold signing, notarisation, App Store or write tokens, and a persistent machine must not hold those (a job could leave code behind for the next). Those Alpha/release coordination jobs run on Ubuntu, where hosted capacity is not the bottleneck. The gain comes from moving the main-push Mac jobs, about half of all hosted macOS demand, off the hosted queue so PRs get those slots.

## Machines

| Runner | Labels today | Role | Change needed |
| --- | --- | --- | --- |
| `macbook-intel-justspeaktoit` | macOS, X64, jsti-macos-build, macbook-intel-local, jsti-reviewed-local | Reviewed Mac pool (X64) | Install the new hook (`install.sh … mac`). |
| `bravo-mini-justspeaktoit` | macOS, ARM64, jsti-macos-build, bravo-mini-local | Reviewed Mac pool (ARM64) once labelled | Install the hook, then `pool.sh add-reviewed-label bravo-mini-justspeaktoit`. |
| `mac-mini-3-justspeaktoit` | macOS, ARM64, jsti-macos-build, self-hosted, mac-mini-3-local | Owner's active Mac (agent sessions run here). Never in a pool. | None. Never add `jsti-reviewed-local`; `install.sh` and `pool.sh` refuse it. |
| `omarchy-justspeaktoit` | self-hosted, Linux, X64, omarchy-local | Linux pool | Install the hook (`install.sh … linux`). Needs Docker, git and python3. |

After bravo-mini carries `jsti-reviewed-local` and admits main jobs, clear the X64 pin with `pool.sh use-default-mac-labels` so both Macs share the work.

## Admission hook

`scripts/runner-admission/job-started.sh` replaces the per-SHA-only hook. It is the runner's `ACTIONS_RUNNER_HOOK_JOB_STARTED` and fails closed. It admits a job only when the repository is `crmitchelmore/justspeaktoit`, the job id is in the runner's `allowed-jobs` list, and one of these holds:

- **Main:** the event is `push` or `schedule`, `GITHUB_REF` is `refs/heads/main`, `GITHUB_WORKFLOW_REF` names a workflow on `refs/heads/main`, and `GITHUB_SHA` is main's tip or an ancestor of it. The hook checks this by fetching main's commit graph from GitHub into a private mirror (`admission/main.git`, a tree-less fetch of about 2 MB, under a second). Unreachable GitHub means a denial.
- **Approved PR:** a same-repository `pull_request` whose head SHA is listed in `admission/approved-shas`, unchanged from the old hook.

Tools, the remote and the policy files are fixed paths, so job-level environment cannot redirect the checks. `allowed-jobs-mac` and `allowed-jobs-linux` must list exactly the jobs routed to each pool; a test keeps them in sync with the workflows.

Owner steps, run on each machine from a `main` checkout:

1. `scripts/runner-admission/install.sh ~/actions-runner-justspeaktoit mac` (bravo-mini, macbook-intel) or `… linux` (omarchy). Use `--dry-run` first. It backs up the old hook and `.env`, installs read-only policy files and keeps `approved-shas`.
2. Restart the runner service (`./svc.sh stop && ./svc.sh start`).
3. On bravo-mini only: `scripts/runner-admission/pool.sh add-reviewed-label bravo-mini-justspeaktoit`, then `pool.sh use-default-mac-labels`.
4. `pool.sh status`, then confirm the next `main` CI run's jobs name the expected runners and log "Admission accepted: main push".

Hardening (recommended): make `admission/` root-owned (`sudo chown -R root admission && sudo chmod -R go-w admission`) so a job running as the runner user cannot rewrite the policy for later jobs.

## Capacity and warm caches

Each machine runs one job at a time, so main CI's six Mac jobs share two Macs rather than six hosted slots. Main runs are not on the PR critical path, and Alpha picks the newest successful main run, so a short backlog delays only Alpha. If merges outpace the pool, switch main to hosted with `pool.sh main-off`.

Self-hosted runners are warm-cache hosts by construction: SwiftPM's shared cache, `Tooling/.build`, Docker image layers and the per-host build caches persist between jobs, keyed by `runner.arch`, runner name and workspace. Do not run a LAN download mirror for hosted runners. They cannot reach the home network, and exposing a mirror publicly would add an unauthenticated supply-chain hop.

## Automated PR approval (proposal, not enabled)

PRs stay hosted unless the owner approves a head SHA. A safe automation would keep that per-SHA guarantee:

1. A `pull_request_review` workflow (hosted, no checkout) triggers when `crmitchelmore` approves a same-repository PR, and records the reviewed `commit_id`.
2. A small owner-run service on each reviewed runner (not GitHub) polls the PR reviews API with a read-only token and appends a SHA to `approved-shas` only when the owner's approval targets that exact head, the PR is from this repository and no newer commit exists.
3. The workflow sets `JSTI_NATIVE_APPROVED_SHA` (needs a variables-write token in a `main`-only environment) or, better, the routing reads a per-PR label applied by the same review event.

Agent sessions push and comment as the owner, so the trust root has to be a human review event, not the actor. A pushed commit after approval invalidates it because the SHA changes. This needs a fine-grained token with Variables write and a decision from the owner, so it is not implemented.

## Build caches, UI jobs and hosted fallbacks

Build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation does not use the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered Macs lack unattended UI automation setup. Portable iOS test products also stay hosted: the producer exports both simulator architectures with source/Xcode/SDK provenance, and the consumer verifies that exact provenance before the unchanged unit/UI selections run. Native Macs may have different Xcode versions and must not exchange those products.

For any other source, Debug, API compatibility and the core contract fall back to hosted Intel (`macos-26-intel`); lint, Release and iOS compilation fall back to hosted ARM (`macos-latest`). Native iOS keyboard/watch compilation requires matching installed SDKs and preinstalled Tuist. The toolchain action verifies native Tuist without installing Homebrew; hosted setup retains its Homebrew mechanism. Ubuntu lanes use the separate Linux pool described below.

## Self-hosted Linux pool (Omarchy)

The same routing (a `main` push or schedule, or `JSTI_NATIVE_APPROVED_SHA` matching a same-repository PR head) routes these Linux jobs to `vars.JSTI_LINUX_RUNNER_LABELS`, default `["self-hosted","Linux","X64","omarchy-local"]`, and otherwise to their original hosted image: Paid Access Worker; Dependabot policy checks; desktop icon invariants; Linux desktop (GTK 4); the pinned whisper.cpp runtime build; and Portable Swift on Linux. Fork PRs, `workflow_dispatch` and other events always stay hosted. Setting `JSTI_LINUX_RUNNER_LABELS` to a hosted label such as `["ubuntu-24.04"]` returns every Linux job to hosted runners without touching the Mac pool.

The GTK, whisper runtime and portable Linux jobs run in their pinned Ubuntu containers, so the runner needs Docker access but no distribution packages. Those containers run as root against the runner's persistent `/__w` bind mount; each records the host owner first and restores it in a final `always()` step so later host jobs can clean the checkout. Host-level jobs need `git`, `python3` and outbound network; Node is installed by `actions/setup-node`.

These stay hosted: CI and CodeQL change detection and the `Build & Test (macOS)` aggregate (Omarchy is one runner, so these short critical-path gates must not queue behind a long Linux job), the Flatpak build and retest (they require a privileged disposable container), CodeQL analysis (it selects Xcode globally), the Windows cross-compile/bundle jobs (secret-bearing on push, ARM-only LLVM), UI capture and simulator jobs, and every release, qualification and publication workflow. Self-hosted jobs receive no secrets.

The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause both laptop runners; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

Initial Intel evidence: Xcode 26.3 / Apple Swift 6.2.4 built Alpha `a43520a51e4b0a9dbcfd40fa5b0222645b3101f6` locally in 229 seconds. The separate pinned GitHub verification is https://github.com/crmitchelmore/justspeaktoit/actions/runs/34463783833; inspect its final result before enabling the pool. PR #1038 has merged; historical commissioning evidence does not establish current runner readiness.

## Keychain isolation on native and hosted runners

Both flows run the complete test gates. On hosted Macs, `with-test-keychain.py` retains the disposable account-wide Keychain and journalled recovery. On native Macs (and explicit local opt-in), it creates a private file Keychain through Security.framework without changing the account default or search list. Its path and an ephemeral random unlock password are passed only to the command's environment. `SpeakCore.KeychainAccess` scopes every app/fixture SecItem operation to that file; normal app launches retain the OS behaviour. Missing/invalid native scopes fail closed, never falling back to desktop or iCloud items. Synchronizable/data-protection requests report unsupported entitlements in the scoped flow.

Native cancellation cannot strand a temporary default because no preferences were swapped. SIGTERM stops the owned child group; SIGKILL can leave only job-owned temporary files, subject to normal Storage Guard retention. The private Keychain is unlocked noninteractively for each operation; test processes disable Security UI instead of prompting. The integration gate checks real create/read/update/delete, attempted alternate search lists, broad deletes, invalid scopes and SIGTERM/SIGKILL while preserving a separate sentinel Keychain and the desktop default/search list. Never print the ephemeral password.

The environment redirect compiles only when SpeakCore is built with `JSTI_TEST_KEYCHAIN_REDIRECT=1`. The macOS Debug, Core Journey and Release test jobs set it at job level, and the release workflow sets it only on its test step. Distribution builds never set it, so shipped apps and CLIs ignore `JSTI_TEST_KEYCHAIN_PATH`, `JSTI_TEST_KEYCHAIN_PASSWORD` and `RUNNER_ENVIRONMENT`. `scripts/verify-no-test-keychain-redirect.sh` fails packaging if any shipped Mach-O file contains those names. The private-Keychain wrapper refuses to run without the flag.

All macOS app and credential-fixture SecItem calls must go through `KeychainAccess`; do not introduce a raw Security call that could bypass the scoped native flow. Archived workflows predating this implementation must not be admitted to native tests. Keep exact-source admission and update the local approval only after reviewing the scoped implementation. For an old account-wide swap left by a previous runner, stop its tests and use `python3 scripts/with-test-keychain.py --repair` before resuming.
