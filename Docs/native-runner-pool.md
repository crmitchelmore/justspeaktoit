# Reviewed native runner pool

The non-UI macOS CI jobs (Debug and Release tests, lint, the core-journey contract and API compatibility) can use the native pool. The pool is opt-in for one reviewed revision via the repository Actions variable `JSTI_NATIVE_APPROVED_SHA`. An unset or nonmatching value retains GitHub-hosted routing.

The pool defaults to `["jsti-macos-build","macOS"]`. Set the repository variable `JSTI_NATIVE_RUNNER_LABELS` to a JSON label array (for example `["mac-mini-3-local","macOS"]`) to pin approved jobs to runners whose admission hooks accept the revision.

For a pull request, the source repository must be this repository and the variable must match its exact head SHA. Fork pull requests never match this route. For a push, only `refs/heads/main` with its exact commit SHA can match. Labels and this variable are scheduling controls, not a security boundary: each Mac must independently enforce its local admission policy before any job step runs.

Before activating a revision:

1. Review the source and workflow. Confirm native architecture support and the checkout revision; do not execute arbitrary fork code.
2. Configure the admission hook on every runner selected by `JSTI_NATIVE_RUNNER_LABELS` for the exact intended revision, event and jobs. Merely setting the repository variable does not enable a runner's hook.
3. Verify every selected runner is online and carries every configured label. Retain accurate X64/ARM64 labels; never assign ARM64 to an Intel runner.
4. Set `JSTI_NATIVE_APPROVED_SHA` to the reviewed source SHA, then start a fresh CI run and verify its named runner and hook acceptance. A rerun of an existing job may retain its original routing.
5. Clear the variable to return future jobs to hosted routing. Changing a source revision requires a fresh admission review and matching configuration.

Build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation does not use the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered native Macs are not configured for unattended UI automation, while hosted Intel UI execution has timed out or exhausted simulator disk. Neither hosted pool alone has enough capacity for every required gate, so Apple jobs are split across both. The iOS SwiftPM, test-product, keyboard and watch compilation jobs stay on hosted ARM (`macos-latest`) with the simulator and UI jobs. Debug tests, API compatibility and the core-journey contract fall back to hosted Intel (`macos-26-intel`). Lint and Release tests stay on hosted ARM: on Intel, Lint's tooling tests ran past its 30-minute budget and a cold Release build ran past its 45-minute budget. The core-journey contract has to share Debug's architecture to restore its cache. None of these jobs depends on the host architecture. The test-product job exports both simulator architectures with source/Xcode/SDK provenance; the simulator job verifies that provenance before executing the unchanged unit and UI selections with `test-without-building`. Ubuntu lanes always stay hosted.

The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause both laptop runners; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

Initial Intel evidence: Xcode 26.3 / Apple Swift 6.2.4 built Alpha `a43520a51e4b0a9dbcfd40fa5b0222645b3101f6` locally in 229 seconds. The separate pinned GitHub verification is https://github.com/crmitchelmore/justspeaktoit/actions/runs/34463783833; inspect its final result before enabling the pool. PR #1038 has merged; this follow-up must pass its complete CI gate before merging.

## Keychain isolation on native and hosted runners

Both flows run the complete test gates. On hosted Macs, `with-test-keychain.py` retains the disposable account-wide Keychain and journalled recovery. On native Macs (and explicit local opt-in), it creates a private file Keychain through Security.framework without changing the account default or search list. Its path and an ephemeral random unlock password are passed only to the command's environment. `SpeakCore.KeychainAccess` scopes every app/fixture SecItem operation to that file; normal app launches retain the OS behaviour. Missing/invalid native scopes fail closed, never falling back to desktop or iCloud items. Synchronizable/data-protection requests report unsupported entitlements in the scoped flow.

Native cancellation cannot strand a temporary default because no preferences were swapped. SIGTERM stops the owned child group; SIGKILL can leave only job-owned temporary files, subject to normal Storage Guard retention. The private Keychain is unlocked noninteractively for each operation; test processes disable Security UI instead of prompting. The integration gate checks real create/read/update/delete, attempted alternate search lists, broad deletes, invalid scopes and SIGTERM/SIGKILL while preserving a separate sentinel Keychain and the desktop default/search list. Never print the ephemeral password.

All macOS app and credential-fixture SecItem calls must go through `KeychainAccess`; do not introduce a raw Security call that could bypass the scoped native flow. Archived workflows predating this implementation must not be admitted to native tests. Keep exact-source admission and update the local approval only after reviewing the scoped implementation. For an old account-wide swap left by a previous runner, stop its tests and use `python3 scripts/with-test-keychain.py --repair` before resuming.
