# Reviewed native runner pool

The non-UI macOS CI jobs (Debug and Release tests, lint, the core-journey contract and API compatibility) can use the native pool. The pool is opt-in for one reviewed revision via the repository Actions variable `JSTI_NATIVE_APPROVED_SHA`. An unset or nonmatching value retains GitHub-hosted routing.

The pool defaults to `[jsti-macos-build, macOS]`. Set the repository variable `JSTI_NATIVE_RUNNER_LABELS` to a JSON label array (for example `["mac-mini-3-local","macOS"]`) to pin approved jobs to runners whose admission hooks accept the revision.

For a pull request, the source repository must be this repository and the variable must match its exact head SHA. Fork pull requests never match this route. For a push, only `refs/heads/main` with its exact commit SHA can match. Labels and this variable are scheduling controls, not a security boundary: each Mac must independently enforce its local admission policy before any job step runs.

Before activating a revision:

1. Review the source and workflow. Confirm native architecture support and the checkout revision; do not execute arbitrary fork code.
2. Configure the admission hook on every runner selected by `JSTI_NATIVE_RUNNER_LABELS` for the exact intended revision, event and jobs. Merely setting the repository variable does not enable a runner's hook.
3. Verify every selected runner is online and carries every configured label. Retain accurate X64/ARM64 labels; never assign ARM64 to an Intel runner.
4. Set `JSTI_NATIVE_APPROVED_SHA` to the reviewed source SHA, then start a fresh CI run and verify its named runner and hook acceptance. A rerun of an existing job may retain its original routing.
5. Clear the variable to return future jobs to hosted routing. Changing a source revision requires a fresh admission review and matching configuration.

Build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation does not use the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered native Macs are not configured for unattended UI automation, while hosted Intel UI execution has timed out or exhausted simulator disk. Compilation-only iOS SwiftPM, test-product, keyboard and watch jobs use hosted Intel. The test-product job exports both simulator architectures with source/Xcode/SDK provenance; hosted ARM verifies that provenance before executing the unchanged unit and UI selections with `test-without-building`. Ubuntu lanes always stay hosted.

The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause both laptop runners; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

Initial Intel evidence: Xcode 26.3 / Apple Swift 6.2.4 built Alpha `a43520a51e4b0a9dbcfd40fa5b0222645b3101f6` locally in 229 seconds. The separate pinned GitHub verification is https://github.com/crmitchelmore/justspeaktoit/actions/runs/34463783833; inspect its final result before enabling the pool. PR #1038 has merged; this follow-up must pass its complete CI gate before merging.
