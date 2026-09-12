# Reviewed native runner pool

The `build-macos` and `api-compatibility` CI jobs can use `[jsti-macos-build, macOS]`. The pool is opt-in for one reviewed revision via the repository Actions variable `JSTI_NATIVE_APPROVED_SHA`. An unset or nonmatching value retains GitHub-hosted routing.

For a pull request, the source repository must be this repository and the variable must match its exact head SHA. Fork pull requests never match this route. For a push, only `refs/heads/main` with its exact commit SHA can match. Labels and this variable are scheduling controls, not a security boundary: each Mac must independently enforce its local admission policy before any job step runs.

Before activating a revision:

1. Review the source and workflow. Confirm native architecture support and the checkout revision; do not execute arbitrary fork code.
2. Configure both Mac admission hooks for the exact intended revision/event/jobs, including the PR base and merge revision where required. The laptop defaults to rejecting all PR events; merely setting this variable does not enable its hook.
3. Verify both registered runners are online and carry `jsti-macos-build` and `macOS`. Retain their accurate X64/ARM64 labels. Do not assign ARM64 to the Intel laptop.
4. Set `JSTI_NATIVE_APPROVED_SHA` to the reviewed source SHA, then start a fresh CI run and verify its named runner and hook acceptance. A rerun of an existing job may retain its original routing.
5. Clear the variable to return future jobs to hosted routing. Changing a source revision requires a fresh admission review and matching configuration.

Build cache keys and restore prefixes include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations. Other CI lanes retain their existing routing. The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause both laptop runners; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

Initial Intel evidence: Xcode 26.3 / Apple Swift 6.2.4 built Alpha `a43520a51e4b0a9dbcfd40fa5b0222645b3101f6` locally in 229 seconds. The separate pinned GitHub verification is https://github.com/crmitchelmore/justspeaktoit/actions/runs/34463783833; inspect its final result before enabling the pool. PR #1038 has merged; this follow-up must pass its complete CI gate before merging.
