# Native runner pool

Hosted macOS concurrency is the CI bottleneck: Mac jobs routinely queued 30–75 minutes for a runner. The native pool is a single serial Intel MacBook whose admission hook runs one build at a time. Routing every Mac job to it made CI slower: in run 42674488497 the Debug build, keyboard, Core Dictation Journey and Lint were still queued for it when CI was cancelled at 60 minutes. Hosted Ubuntu jobs had no queue and also finished faster than on Omarchy.

CI therefore uses hybrid routing. Only three light, cache-friendly jobs that do not depend on each other use the pool, so it runs in parallel with hosted macOS and takes slots away from that queue:

| Job | Native (MacBook) | Hosted fallback |
| --- | --- | --- |
| `ci.yml:lint` | ~7 min | `macos-latest` (on hosted Intel the tooling tests exceeded their 30-minute budget) |
| `ci.yml:api-compatibility` (pull requests only) | ~11 min | `macos-26-intel` (~16.5 min) |
| `local-transcription-benchmark.yml:benchmark-package` | ~8 min | `macos-latest` |

A PR therefore puts at most about 18 minutes of serial work on the MacBook, and a `main` push about 15 minutes, both shorter than the hosted Debug gate that runs alongside. Every other job uses a plain hosted label: Debug and Core Dictation Journey on `macos-26-intel` (the journey restores Debug's arch-scoped cache), and Release, the iOS jobs, Fixture UI and Portable Swift on macOS on `macos-latest`/`macos-15`. All Linux jobs, including Paid Access Worker, Dependabot policy, desktop icons, Linux desktop, the whisper.cpp runtime and Portable Swift on Linux, run on hosted Ubuntu. There is no self-hosted Linux routing. `scripts/tests/self-hosted-routing.test.mjs` pins this exact set. Add a job to the pool only after timing it there and updating the MacBook admission hook.

A pool job routes natively only when the actor and triggering actor are `crmitchelmore` or `bravostation`, and either the event is a push to `main` or it is a same-repository `pull_request` authored by one of them. Bot-authored pull requests (Devin, Copilot, Dependabot), owner pushes to them, forks and every other event keep GitHub-hosted routing. Set the repository variable `JSTI_LOCAL_RUNNERS` to `off` to return every job to hosted runners.

The pool defaults to `["jsti-reviewed-local","macOS"]`, which selects only reviewed runners. Never use `jsti-macos-build` as a pool label: the owner's active Mac also carries it. Set the repository variable `JSTI_NATIVE_RUNNER_LABELS` to a JSON label array (currently `["jsti-reviewed-local","macOS","X64"]`) to pin pool jobs to runners whose admission hooks accept them. The routed jobs are architecture-neutral.

Labels and variables are scheduling controls, not a security boundary: each runner must independently enforce the same actor, author, repository, event and job checks in its job-started hook before any job step runs. Self-hosted jobs execute owner-authored code unsandboxed as the runner user, so never widen the actor list to bots or outside contributors. Self-hosted jobs receive no secrets.

Self-hosted runners never fall back to hosted ones. If the MacBook is offline (asleep, paused or shut down), its jobs wait in the queue. Set `JSTI_LOCAL_RUNNERS=off` before taking it away for long, then rerun the affected workflow. A rerun of an existing job may retain its original routing.

Before adding a runner to the pool, configure its admission hook, verify it is online with every configured label, and retain accurate X64/ARM64 labels; never assign ARM64 to an Intel runner.

Build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation never uses the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered Macs lack unattended UI automation setup. Portable iOS test products also stay hosted: the producer exports both simulator architectures with source/Xcode/SDK provenance, and the consumer verifies that exact provenance before the unchanged unit/UI selections run.

The laptop uses one shared build slot across repositories, nine Swift build workers and reduced process priority. Its CI menu can pause the runner; pausing may cancel active jobs. These controls do not provide a hard CPU/RAM quota or sandbox untrusted code.

## Keychain isolation on native and hosted runners

Both flows run the complete test gates. On hosted Macs, `with-test-keychain.py` retains the disposable account-wide Keychain and journalled recovery. On native Macs (and explicit local opt-in), it creates a private file Keychain through Security.framework without changing the account default or search list. Its path and an ephemeral random unlock password are passed only to the command's environment. `SpeakCore.KeychainAccess` scopes every app/fixture SecItem operation to that file; normal app launches retain the OS behaviour. Missing/invalid native scopes fail closed, never falling back to desktop or iCloud items. Synchronizable/data-protection requests report unsupported entitlements in the scoped flow.

Native cancellation cannot strand a temporary default because no preferences were swapped. SIGTERM stops the owned child group; SIGKILL can leave only job-owned temporary files, subject to normal Storage Guard retention. The private Keychain is unlocked noninteractively for each operation; test processes disable Security UI instead of prompting. The integration gate checks real create/read/update/delete, attempted alternate search lists, broad deletes, invalid scopes and SIGTERM/SIGKILL while preserving a separate sentinel Keychain and the desktop default/search list. Never print the ephemeral password.

The environment redirect compiles only when SpeakCore is built with `JSTI_TEST_KEYCHAIN_REDIRECT=1`. The macOS Debug, Core Journey and Release test jobs set it at job level, and the release workflow sets it only on its test step. Distribution builds never set it, so shipped apps and CLIs ignore `JSTI_TEST_KEYCHAIN_PATH`, `JSTI_TEST_KEYCHAIN_PASSWORD` and `RUNNER_ENVIRONMENT`. `scripts/verify-no-test-keychain-redirect.sh` fails packaging if any shipped Mach-O file contains those names. The private-Keychain wrapper refuses to run without the flag.

All macOS app and credential-fixture SecItem calls must go through `KeychainAccess`; do not introduce a raw Security call that could bypass the scoped native flow. Archived workflows predating this implementation must not be admitted to native tests. Keep native admission limited to owner-authored sources. For an old account-wide swap left by a previous runner, stop its tests and use `python3 scripts/with-test-keychain.py --repair` before resuming.
