# Reviewed native runner pool

The non-UI macOS CI jobs (Debug and Release tests, lint, the core-journey contract and API compatibility), the iOS SwiftPM library build, unsigned iOS keyboard/watch builds, Portable Swift on macOS and the local-transcription benchmark package can use the native pool. The pool is opt-in for one reviewed revision via the repository Actions variable `JSTI_NATIVE_APPROVED_SHA`. An unset or nonmatching value retains GitHub-hosted routing.

The pool defaults to `["jsti-reviewed-local","macOS"]`, which selects only the reviewed bravo-mini (ARM64) and Intel MacBook (X64) runners. Never use `jsti-macos-build` as a pool label: the owner's active Mac also carries it. Set the repository variable `JSTI_NATIVE_RUNNER_LABELS` to a JSON label array (for example `["jsti-reviewed-local","macOS","X64"]`) to pin approved jobs to runners whose admission hooks accept the revision. Every native-routed job is architecture-neutral, so the pool spans both architectures; add `ARM64` or `X64` here only to restrict the whole pool.

For a pull request, the source repository must be this repository and the variable must match its exact head SHA. Fork pull requests never match this route. For a push, only `refs/heads/main` with its exact commit SHA can match. Labels and this variable are scheduling controls, not a security boundary: each Mac must independently enforce its local admission policy before any job step runs.

Before activating a revision:

1. Review the source and workflow. Confirm native architecture support and the checkout revision; do not execute arbitrary fork code.
2. Configure the admission hook on every runner selected by `JSTI_NATIVE_RUNNER_LABELS` for the exact intended revision, event and jobs. Merely setting the repository variable does not enable a runner's hook.
3. Verify every selected runner is online and carries every configured label. Retain accurate X64/ARM64 labels; never assign ARM64 to an Intel runner.
4. Set `JSTI_NATIVE_APPROVED_SHA` to the reviewed source SHA, then start a fresh CI run and verify its named runner and hook acceptance. A rerun of an existing job may retain its original routing.
5. Clear the variable to return future jobs to hosted routing. Changing a source revision requires a fresh admission review and matching configuration.

Build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation does not use the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered Macs lack unattended UI automation setup. Portable iOS test products also stay hosted: the producer exports both simulator architectures with source/Xcode/SDK provenance, and the consumer verifies that exact provenance before the unchanged unit/UI selections run. Native Macs may have different Xcode versions and must not exchange those products.

For an unapproved source, every native-eligible job falls back to hosted ARM (`macos-latest`). Hosted macOS concurrency is a per-account cap shared by Intel and ARM images, so the former Intel split (#1347) added no capacity and ran each job more slowly. Native iOS keyboard/watch compilation requires matching installed SDKs and preinstalled Tuist. The toolchain action verifies native Tuist without installing Homebrew; hosted setup retains its Homebrew mechanism. Ubuntu lanes use the separate Linux pool described below.

## Self-hosted Linux pool (Omarchy)

The same approval (`JSTI_NATIVE_APPROVED_SHA` matching a same-repository PR head or a `main` push) routes these Linux jobs to `vars.JSTI_LINUX_RUNNER_LABELS`, default `["self-hosted","Linux","X64","omarchy-local"]`, and otherwise to their original hosted image: Paid Access Worker; Dependabot policy checks; desktop icon invariants; Linux desktop (GTK 4); the pinned whisper.cpp runtime build; and Portable Swift on Linux. Fork PRs, `workflow_dispatch`, schedules and other events always stay hosted. Setting `JSTI_LINUX_RUNNER_LABELS` to a hosted label such as `["ubuntu-24.04"]` returns every Linux job to hosted runners without touching the Mac pool.

The GTK, whisper runtime and portable Linux jobs run in their pinned Ubuntu containers, so the runner needs Docker access but no distribution packages. Those containers run as root against the runner's persistent `/__w` bind mount; each records the host owner first and restores it in a final `always()` step so later host jobs can clean the checkout. Host-level jobs need `git`, `python3` and outbound network; Node is installed by `actions/setup-node`.

These stay hosted: CI and CodeQL change detection and the `CI Gate` aggregate (and its legacy `Build & Test (macOS)` mirror) (Omarchy is one runner, so these short critical-path gates must not queue behind a long Linux job), the Flatpak build and retest (they require a privileged disposable container), CodeQL analysis (it selects Xcode globally), the Windows cross-compile/bundle jobs (secret-bearing on push, ARM-only LLVM), UI capture and simulator jobs, and every release, qualification and publication workflow. Self-hosted jobs receive no secrets.

The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause both laptop runners; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

Initial Intel evidence: Xcode 26.3 / Apple Swift 6.2.4 built Alpha `a43520a51e4b0a9dbcfd40fa5b0222645b3101f6` locally in 229 seconds. The separate pinned GitHub verification is https://github.com/crmitchelmore/justspeaktoit/actions/runs/34463783833; inspect its final result before enabling the pool. PR #1038 has merged; historical commissioning evidence does not establish current runner readiness.

## Keychain isolation on native and hosted runners

Both flows run the complete test gates. On hosted Macs, `with-test-keychain.py` retains the disposable account-wide Keychain and journalled recovery. On native Macs (and explicit local opt-in), it creates a private file Keychain through Security.framework without changing the account default or search list. Its path and an ephemeral random unlock password are passed only to the command's environment. `SpeakCore.KeychainAccess` scopes every app/fixture SecItem operation to that file; normal app launches retain the OS behaviour. Missing/invalid native scopes fail closed, never falling back to desktop or iCloud items. Synchronizable/data-protection requests report unsupported entitlements in the scoped flow.

Native cancellation cannot strand a temporary default because no preferences were swapped. SIGTERM stops the owned child group; SIGKILL can leave only job-owned temporary files, subject to normal Storage Guard retention. The private Keychain is unlocked noninteractively for each operation; test processes disable Security UI instead of prompting. The integration gate checks real create/read/update/delete, attempted alternate search lists, broad deletes, invalid scopes and SIGTERM/SIGKILL while preserving a separate sentinel Keychain and the desktop default/search list. Never print the ephemeral password.

The environment redirect compiles only when SpeakCore is built with `JSTI_TEST_KEYCHAIN_REDIRECT=1`. The macOS Debug, Core Journey and Release test jobs set it at job level, and the release workflow sets it only on its test step. Distribution builds never set it, so shipped apps and CLIs ignore `JSTI_TEST_KEYCHAIN_PATH`, `JSTI_TEST_KEYCHAIN_PASSWORD` and `RUNNER_ENVIRONMENT`. `scripts/verify-no-test-keychain-redirect.sh` fails packaging if any shipped Mach-O file contains those names. The private-Keychain wrapper refuses to run without the flag.

All macOS app and credential-fixture SecItem calls must go through `KeychainAccess`; do not introduce a raw Security call that could bypass the scoped native flow. Archived workflows predating this implementation must not be admitted to native tests. Keep exact-source admission and update the local approval only after reviewing the scoped implementation. For an old account-wide swap left by a previous runner, stop its tests and use `python3 scripts/with-test-keychain.py --repair` before resuming.
