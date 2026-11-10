# Native runner pool

Hosted macOS concurrency is the CI bottleneck: Mac jobs routinely queued 30–75 minutes for a runner. Two owner machines are dedicated CI hosts: an Intel MacBook Pro (i9-8950HK, 32 GB) and the Omarchy Linux laptop (8 cores, 15 GB). Each runs two runners. Their CPUs are no faster than hosted runners, so a cold build there gains nothing. They win by having no queue and by keeping each job's build directory warm between runs, so SwiftPM and CMake builds are incremental.

CI therefore uses hybrid routing. The Debug critical path and cache-friendly build jobs use the dedicated pools. iOS, keyboard, Release and Fixture UI stay on hosted macOS so they run in parallel:

| Job | Pool | Hosted fallback |
| --- | --- | --- |
| `ci.yml:build-macos` (Debug, the PR critical path) | MacBook | `macos-26-intel` |
| `ci.yml:lint` | MacBook | `macos-latest` (on hosted Intel the tooling tests exceeded their 30-minute budget) |
| `ci.yml:api-compatibility` (pull requests only) | MacBook | `macos-26-intel` |
| `local-transcription-benchmark.yml:benchmark-package` | MacBook | `macos-latest` |
| `windows.yml:portable-macos` | MacBook | `macos-15` |
| `linux.yml:linux-desktop` | Omarchy | `ubuntu-24.04` |
| `linux-local-runtime.yml:runtime` (whisper.cpp, called by `linux.yml:local-runtime`) | Omarchy | `ubuntu-24.04` |
| `windows.yml:portable-linux` | Omarchy | `ubuntu-22.04` |

Every other job uses a plain hosted label: Release, Build iOS Library (simulator build-for-testing plus tests in one job), the keyboard and Fixture UI on `macos-latest`. Debug also runs the Core Dictation Journey gate on its own warm build products. On pull requests, Release, keyboard and Fixture UI run only when their paths change, and every Swift gate except Lint is skipped for changes that cannot affect the Apple Swift build (docs, site, Linux/Windows/Android-only sources); `main` pushes run everything. Tiny Linux jobs (Paid Access Worker, Dependabot policy, desktop icons) stay on hosted Ubuntu because they have nothing to cache. `scripts/tests/self-hosted-routing.test.mjs` pins both pool sets exactly. Add a job to a pool only after updating that machine's admission hook.

A pool job routes natively only when the actor and triggering actor are `crmitchelmore` or `bravostation`, and either the event is a push to `main` or it is a same-repository `pull_request` authored by one of them. Bot-authored pull requests (Devin, Copilot, Dependabot), owner pushes to them, forks and every other event keep GitHub-hosted routing. Set the repository variable `JSTI_LOCAL_RUNNERS` to `off` to return every job to hosted runners.

The pool defaults to `["jsti-reviewed-local","macOS"]`, which selects only reviewed runners. Never use `jsti-macos-build` as a pool label: the owner's active Mac also carries it. Set the repository variable `JSTI_NATIVE_RUNNER_LABELS` to a JSON label array (currently `["jsti-reviewed-local","macOS","X64"]`) to pin pool jobs to runners whose admission hooks accept them. The routed jobs are architecture-neutral.

The Omarchy pool defaults to `["self-hosted","Linux","X64","omarchy-local"]`; the optional repository variable `JSTI_LINUX_RUNNER_LABELS` overrides it. To return every pool job to its own hosted fallback, set `JSTI_LOCAL_RUNNERS=off`. Omarchy jobs run in root job containers on the runner's `_work` bind mount. Each records the host work-tree owner before checkout and hands `_work` back to it at the end, except `_work/.jsti-cache`, which stays root-owned so the capture-writer tests' ancestor-ownership checks pass. Maintaining that directory on the host needs `sudo`.

Labels and variables are scheduling controls, not a security boundary: each runner must independently enforce the same actor, author, repository, event and job checks in its job-started hook before any job step runs. Self-hosted jobs execute owner-authored code unsandboxed as the runner user, so never widen the actor list to bots or outside contributors. Self-hosted jobs receive no secrets.

Self-hosted runners never fall back to hosted ones. If a pool machine is offline (asleep, paused or shut down), its jobs wait in the queue. Set `JSTI_LOCAL_RUNNERS=off` before taking it away for long, then rerun the affected workflow. A rerun of an existing job may retain its original routing.

Before adding a runner to the pool, configure its admission hook, verify it is online with every configured label, and retain accurate X64/ARM64 labels; never assign ARM64 to an Intel runner.

## Warm build caches

On self-hosted runners only (`runner.environment == 'self-hosted'`), `.github/actions/warm-build-cache` runs right after checkout and symlinks the job's build outputs (SwiftPM `.build`, `Tooling/.build`, the whisper.cpp CMake work tree, the benchmark scratch path) to `_work/.jsti-cache/<runner name>/<job key>/<path>`. The runner name keeps the two concurrent runners on one machine from sharing a directory; the job key keeps jobs apart. `actions/checkout`'s clean deletes only the untracked symlink, and the action adds each link to `.git/info/exclude`. If a job's cache exceeds 25 GB it is wiped before use. The same jobs skip `actions/cache` restore/save on self-hosted runners, so they spend no time uploading or downloading archives; hosted behaviour is unchanged. `build-macos` keeps `--disable-dependency-cache`, so its package checkouts live in its own warm `.build` and never touch the shared home SwiftPM cache. On self-hosted Macs, crash reports may name the resolved `.jsti-cache` path rather than `$GITHUB_WORKSPACE/.build`, so `collect-macos-xctest-crashes.py` can miss them; this affects diagnostics only. To force a cold build, delete the job's directory under `.jsti-cache` (with `sudo` on Omarchy).

Hosted build cache keys and restore prefixes, including the lint tooling cache, include `runner.arch`, a stable host identity (runner name for self-hosted machines, `hosted` for GitHub-hosted machines), and `github.workspace`. This keeps Intel/ARM object files separate and prevents absolute-path build state from crossing checkout locations.

UI automation never uses the native pool. `Core Journey Fixture UI` and iOS simulator execution stay on hosted ARM because the registered Macs lack unattended UI automation setup. Portable iOS test products also stay hosted: the producer exports both simulator architectures with source/Xcode/SDK provenance, and the consumer verifies that exact provenance before the unchanged unit/UI selections run.

Both hosts are dedicated to CI. Each admission hook admits two concurrent builds and sets eight SwiftPM/CMake/make workers. Omarchy's runner services have no CPU or I/O throttling, only a 14 GB memory ceiling per runner so a runaway job cannot hang the machine, and sleep/suspend is disabled. The MacBook's CI menu can pause its runners; pausing may cancel active jobs. These controls do not sandbox untrusted code.

## Keychain isolation on native and hosted runners

Both flows run the complete test gates. On hosted Macs, `with-test-keychain.py` retains the disposable account-wide Keychain and journalled recovery. On native Macs (and explicit local opt-in), it creates a private file Keychain through Security.framework without changing the account default or search list. Its path and an ephemeral random unlock password are passed only to the command's environment. `SpeakCore.KeychainAccess` scopes every app/fixture SecItem operation to that file; normal app launches retain the OS behaviour. Missing/invalid native scopes fail closed, never falling back to desktop or iCloud items. Synchronizable/data-protection requests report unsupported entitlements in the scoped flow.

Native cancellation cannot strand a temporary default because no preferences were swapped. SIGTERM stops the owned child group; SIGKILL can leave only job-owned temporary files, subject to normal Storage Guard retention. The private Keychain is unlocked noninteractively for each operation; test processes disable Security UI instead of prompting. The integration gate checks real create/read/update/delete, attempted alternate search lists, broad deletes, invalid scopes and SIGTERM/SIGKILL while preserving a separate sentinel Keychain and the desktop default/search list. Never print the ephemeral password.

The environment redirect compiles only when SpeakCore is built with `JSTI_TEST_KEYCHAIN_REDIRECT=1`. The macOS Debug, Core Journey and Release test jobs set it at job level, and the release workflow sets it only on its test step. Distribution builds never set it, so shipped apps and CLIs ignore `JSTI_TEST_KEYCHAIN_PATH`, `JSTI_TEST_KEYCHAIN_PASSWORD` and `RUNNER_ENVIRONMENT`. `scripts/verify-no-test-keychain-redirect.sh` fails packaging if any shipped Mach-O file contains those names. The private-Keychain wrapper refuses to run without the flag.

All macOS app and credential-fixture SecItem calls must go through `KeychainAccess`; do not introduce a raw Security call that could bypass the scoped native flow. Archived workflows predating this implementation must not be admitted to native tests. Keep native admission limited to owner-authored sources. For an old account-wide swap left by a previous runner, stop its tests and use `python3 scripts/with-test-keychain.py --repair` before resuming.
