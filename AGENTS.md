# Repository Guidelines

## Versioning & Release Process

This project maintains **separate version tracks** for macOS and iOS:

### Version Discovery

Stable versions are explicit inputs to **Prepare Stable** (`mac_version`,
`ios_version`), so look up the latest published release before choosing one;
the `VERSION` file lags behind and is not a release source.

```bash
# Latest Stable macOS release (the next Mac version must be higher;
# scripts/release-train.mjs rejects one that does not advance):
gh release list --repo crmitchelmore/justspeaktoit | grep "mac-v" | head -1

# Example: if latest is mac-v3.2.0 → next could be mac-v3.2.1 or mac-v3.3.0
# iOS has no version tag: check the latest version in App Store Connect.
```

### Tag Conventions

| Tag Format | Example | Created by |
|------------|---------|------------|
| `alpha-build-N` | `alpha-build-106` | `.github/workflows/alpha-release.yml` (Alpha manifest after a green main CI) |
| `stable-candidate-N` | `stable-candidate-3` | `.github/workflows/prepare-stable.yml` (frozen Stable candidate manifest) |
| `mac-v*` | `mac-v3.2.0` | `.github/workflows/publish-stable.yml` (published Stable direct macOS release) |
| `v*` | `v0.9.0` | None (legacy) |

`release-mac.yml` and `release-ios.yml` are reusable workers called with a
manifest tag; a tag push does not trigger them.

### Alpha and Stable Release Process

See [Docs/alpha-stable-release-trains.md](Docs/alpha-stable-release-trains.md).
Commit types and tag pushes never trigger a release. Every successful main CI creates an
isolated Alpha build through `alpha-release.yml` (enabled in
`Config/ReleasePipeline.json`). Alpha tags are `alpha-build-N` and are
never GitHub Latest. Website downloads, Homebrew and existing updates stay Stable.

The owner selects a tested Alpha source through `prepare-stable.yml`, reviews
cumulative per-surface notes and candidate builds, then explicitly approves the
frozen manifest hash through `publish-stable.yml`. Stable publication must never
be inferred from a main merge, tag push, upload or successful TestFlight build.
The three release workers are reusable workflows accepting a manifest tag only.

Before an App Store submission, read [`Docs/ios-app-store-submission.md`](Docs/ios-app-store-submission.md): it records which review requirements the repo already satisfies, and which ones (export compliance answers, nutrition label, review notes) still have to be answered by hand in App Store Connect.

For Google Play, [`Docs/android-play-store-submission.md`](Docs/android-play-store-submission.md) holds the
release job behaviour, data safety and content rating answers, and the owner setup steps.

### VERSION File

The `VERSION` file is a **hint**: `Project.swift` reads it as the marketing version for local Tuist builds, and the release workers overwrite it with the manifest's version (`scripts/release-train.mjs`). It does not choose or control any release version; verify macOS against `mac-v*` releases and iOS against App Store Connect.

### Post-Release Support

When a user reports that a freshly shipped macOS release won't install or launch, perform the remediation directly when the environment permits filesystem/app actions; otherwise provide these exact steps for the user to run locally:
1. Download the latest `mac-v*` DMG for the user's Mac: `JustSpeakToIt-arm64.dmg` on Apple Silicon, `JustSpeakToIt-universal.dmg` on Intel.
2. Back up the existing app to a persistent location, e.g. `mv /Applications/JustSpeakToIt.app ~/Desktop/JustSpeakToIt.app.bak-$(date +%s)`.
3. Replace `/Applications/JustSpeakToIt.app` with the app from the DMG.
4. Verify launch locally (e.g. `open -n /Applications/JustSpeakToIt.app`) before asking the user to retry.
5. If local install verification is requested, confirm `/Applications/JustSpeakToIt.app` exists, read `CFBundleShortVersionString`, and verify the process is running.

## Owner Manual Checks

When an issue is blocked only on an owner device check or decision, add it to
`Docs/manual-checks.yml` (served at `justspeaktoit.com/qa`) instead of asking in
the issue; results come back through the `manual-qa-results` workflow. See
[Docs/manual-qa.md](Docs/manual-qa.md).

## Project Structure & Module Organization

The canonical current target inventory, build graphs and runtime map live in
[Docs/Architecture.md](Docs/Architecture.md). Keep generated Xcode projects out
of hand-maintained structure documentation.

### Modularization Patterns

1. **Shared code in SpeakCore**: Types, protocols, and utilities that work on both platforms
2. **Platform guards**: Use `#if os(iOS)` / `#if os(macOS)` for platform-specific code
3. **Public APIs for libraries**: Types in `SpeakiOSLib` must be `public` for Xcode project to access
4. **Tuist links packages**: `Project.swift` references the local Swift package for Xcode generation

### Windows and shared desktop behaviour

- Put provider contracts, parsing, catalogues and transcript policies in `SpeakCore`;
  put portable desktop recording/history orchestration in `SpeakDesktop`.
- New shared source files enter the Windows/Linux build by default. Keep native
  framework dependencies in platform adapters; do not expand `appleCoreSources`
  to avoid implementing a shared feature on Windows.
- Keep capture, resampling, inference and insertion native and in process. Reuse
  shared Swift behaviour without adding IPC or disk polling to the audio path.
- Use the canonical catalogue and stable identifiers. A platform may expose only
  routes its host actually implements; catalogue membership alone is not support.
- Changes to shared behaviour must pass the normal Apple suite and portable
  Windows/macOS/Linux checks. Native adapters also need target-platform evidence.
- Follow [Docs/windows-development.md](Docs/windows-development.md) for builds,
  the current parity matrix and performance/device acceptance gates. Preserve
  `Package.resolved` when the dependency-free portable graph removes it.

## Accessibility and Computer Use

Every control needs an accessible name, role, state and a stable automation ID,
and recording state changes must be announced. Follow
[Docs/accessibility.md](Docs/accessibility.md) for per-platform rules and the CI
guards that enforce them.

## Build, Test, and Development Commands

### macOS (SwiftPM)
- Use Xcode's toolchain only: `swift --version` must report `Apple Swift`. swift.org toolchains (swiftly) do not build this repo (#877).
- `make` or `make run` – Build and launch the macOS app
- `make build` – Debug compilation only
- `make rebuild` – Clean and rebuild from scratch
- `make test` – Execute XCTest suite
- `python3 scripts/with-test-keychain.py <command>` – CI wrapper that runs tests against a disposable Keychain. Locally it is a plain passthrough unless `JSTI_TEST_KEYCHAIN=1`; all other explicit values disable swapping. Overlapping swap runs serialise on a per-user lock. Use `--repair` to recover a valid journal from an interrupted run; an unreadable journal fails closed without changing Keychain settings. The private (native/opt-in) flow also requires `JSTI_TEST_KEYCHAIN_REDIRECT=1`, which compiles the test-only Keychain redirect; never set it for distribution builds.
- `swift build --target SpeakiOSLib` – Verify iOS library compiles

### iOS (Xcode)
- `tuist generate` – Generate the Xcode workspace
- `open "Just Speak to It.xcworkspace"` – Open in Xcode
- Select device/simulator and build (Cmd+B)
- Or use xcodebuild MCP for automation (see below)

### Linting and autofix
```bash
make fix                                           # autofix files changed vs origin/main (pre-pr runs this first)
make format                                        # autofix the whole repository
make quality                                       # zero-violation SwiftFormat, Ruff, ShellCheck, actionlint
make lint                                          # strict SwiftLint: zero violations, no baseline
./scripts/swiftlint.sh lint --strict Sources/SpeakApp  # lint a subset
./scripts/swiftformat.sh Sources/SpeakApp          # format a subset (isolated Tooling graph)
```
- SwiftLint and SwiftFormat resolve through the isolated `Tooling/` graph (pinned in `Tooling/Package.resolved`) so app/test dependency changes cannot downgrade the linter; upgrade it intentionally with `make update-tooling`.
- `scripts/quality` owns the non-SwiftLint linters: SwiftFormat and SwiftLint `--fix` (Swift), Ruff (`ruff.toml`; every `*.py` and Python-shebang script), ShellCheck at every severity (every `*.sh` and shell-shebang script), actionlint (workflows, with `.github/actionlint.yaml`) and ESLint `--fix` for `workers/paid-access` when its `node_modules` exist. `fix` autofixes; `check` fails on anything left. CI's Lint job runs `make quality` (`check --all`), so the bar is zero everywhere.
- Install the local tools once: `brew install shellcheck actionlint`. Ruff installs itself into `.build/quality-tools` from `Tooling/quality-requirements.txt` with pip's configured index (on Microsoft devices that is the CFS proxy). With `CI=true`, pinned ShellCheck and actionlint releases are downloaded and SHA-256 verified.
- Suppress only where a rule is wrong for that line, with a reason: `# noqa: RULE`, `# shellcheck disable=SCxxxx # reason`.
- SwiftLint has no baseline: every violation fails. Fix it; where a rule is genuinely wrong for one line (for example a public API name), use a scoped `// swiftlint:disable:this <rule>` or `:next` with a reason. File-wide `swiftlint:disable` is legacy debt that `scripts/ci/lint-suppression-ratchet.py` stops from growing.

## MCP Tools

### xcodebuild MCP
Installed globally via npm for Xcode build automation:
```bash
npm install -g xcodebuildmcp
```

The MCP server provides tools for:
- Project/workspace discovery
- Building for iOS/macOS targets
- Simulator management
- App deployment and testing

### Usage Pattern
When xcodebuild MCP is available, prefer it for:
- Automated iOS builds without opening Xcode
- CI/CD pipeline integration
- Simulator lifecycle management

## Design Patterns

### Liquid Glass (iOS 26+)
See `.copilot/skills/liquid-glass.md` for Apple's Liquid Glass design guidance.

Key principles:
- **Glass for controls layer** (toolbars, nav bars, floating controls) - not content
- **System components first** - they apply Liquid Glass automatically
- **Remove custom backgrounds** on navigation chrome
- **SF Symbols** for icon-only controls with accessibility labels
- **Spring animations** for natural motion
- **Tint sparingly** - only for semantic emphasis (critical actions)

### Cross-Platform Code
```swift
// In SpeakCore (shared)
public struct TranscriptionResult: Sendable { ... }

// In SpeakiOS (iOS-only)
#if os(iOS)
public final class iOSLiveTranscriber: ObservableObject { ... }
#endif
```

### Settings Search Registry

- Every setting, settings card/section and settings page must be indexed in
  `SettingsSearchCatalog` (`Sources/SpeakCore/SettingsSearch/`). The entry
  `title` must equal the on-screen heading, `settingKeys` must list the
  persisted property names, and `keywords` should hold the words people search
  for. On iOS, use `SearchableSettingsSection` for top-level Settings sections.
- `SettingsSearchCoverageTests` fails when a card, section or `@Published`
  setting is missing. Exempt a setting only with a reason in that test. Desktop
  (`DesktopSettingsSearchTests`) and Android (`SettingsSearchCoverageTest`) have
  equivalent guards. After changing Android entries, regenerate
  `android/app/src/main/assets/settings_search.json` (see
  [Docs/settings-search.md](Docs/settings-search.md)).

### Shared Evolving Catalogues

- Any capability list that can grow over time (models, providers, voices,
  languages, presets, migrations, defaults, or display metadata) must have one
  canonical definition in `SpeakCore` when both platforms consume it.
- Platform targets may expose filtered projections for genuine capability
  differences, but must not copy catalogue entries or defaults.
- Add parity/invariant tests in `SpeakCore` so a new shared entry automatically
  appears on every supported platform and retired identifiers migrate safely.
- If platform behaviour differs deliberately, document the capability rule next
  to the shared catalogue rather than encoding a second platform-owned list.

## Apple documentation (Sosumi)

Apple Developer documentation needs JavaScript, so agents can't read
`developer.apple.com` directly. Use [Sosumi](https://sosumi.ai) instead, and
check Apple APIs against it rather than relying on memory. That covers Swift,
SwiftUI, UIKit, AppKit and Foundation, along with API availability, the Human
Interface Guidelines and WWDC sessions.

- **MCP:** `https://sosumi.ai/mcp` (Streamable HTTP). Tools:
  `searchAppleDocumentation`, `fetchAppleDocumentation`,
  `fetchAppleVideoTranscript` and `fetchExternalDocumentation`.
- **HTTP:** swap the host, so `https://developer.apple.com/documentation/swiftui/view`
  becomes `https://sosumi.ai/documentation/swiftui/view`. Use
  `https://sosumi.ai/external/<url>` for other Swift-DocC sites.
- **CLI:** `npx @nshipster/sosumi search "SwiftData"`, or
  `npx @nshipster/sosumi fetch /documentation/swift/array`.
- **Skill:** `https://sosumi.ai/SKILL.md`, installed in `~/.agents/skills/sosumi`
  and `~/.claude/skills/sosumi`.

## Coding Style & Naming Conventions
- New Swift files use 4-space indentation and LF line endings. `.swiftformat` sets these options but runs only the `braces`, `redundantRawValues` and `redundantReturn` rules, so existing 2-space files (for example `Sources/SpeakApp/Settings/AppSettings.swift`) are not reindented; match the indentation of the file you edit
- Prefer expressive type names (`ContentView`, `SpeakApp`)
- Keep new API surface `internal` unless exposure is required for cross-module use
- Use `public` for types that need to be accessed from Xcode project or other modules
- Enforce linting via `.swiftlint.yml`; rules include `implicit_return`, line-length 120/160
- Apple UI controls need accessible names and stable identifiers; follow [Docs/accessibility.md](Docs/accessibility.md). `make lint` runs `scripts/accessibility/check-apple-accessibility.py`

## Testing Guidelines
- Tests live in per-module XCTest targets under `Tests/` (for example `Tests/SpeakAppTests`, `Tests/SpeakCoreTests`, `Tests/SpeakDesktopTests`, `Tests/SpeakiOSTests`)
- Name specs `test<Behaviour>_<Expectation>()` to mirror scenarios
- Run `scripts/pre-pr` locally before PRs (see Pre-PR Checks); `make test` runs the whole suite
- iOS testing requires device/simulator via Xcode

## Pre-PR Checks (mandatory for agents)

Before opening a PR or pushing to one, run `scripts/pre-pr` (or `make pre-pr`)
and fix every failure first. It compares your branch, including uncommitted
files, with `origin/main` and runs what the CI Gate's pull-request jobs would
run for those files, with the same commands, so a pass predicts a green gate.
Use `--plan` to see the selection, `--fetch` to refresh `origin/main` and
`--full` to run every macOS unit-test target.

- **Autofix first:** pre-pr starts with `scripts/quality fix` over the changed
  files and lists every file it edited; commit those edits (the record's tree
  includes them). `--no-fix` skips it. The pre-push hook passes
  `--fail-on-fix`, so a push whose commit still needed fixes is blocked.
- **Code quality:** `scripts/quality check` over the changed Swift, Python,
  shell and workflow files (SwiftFormat, Ruff, ShellCheck, actionlint). It is
  required, not advisory, and fails closed when a tool is missing.

- **Lint:** `make ci-lint`, the target ci.yml's Lint job runs. That is
  whole-repo strict SwiftLint with zero violations and no baseline,
  accessibility, a ratchet that fails when file-wide `swiftlint:disable`
  suppressions grow against `origin/main`
  (`scripts/ci/lint-suppression-ratchet.py`),
  `Tooling/Package.resolved` drift and `make test-tooling`. It runs unless
  every changed file is docs, website, Android or Workers.
- **Portable Swift (Linux):** `scripts/ci-portable-linux.sh` in the CI image
  (`swift:6.2.3-jammy`), via `scripts/linux-precheck`. That uses a local
  Docker or Podman if one runs, otherwise a throwaway `precheck/**` branch run
  on GitHub's Ubuntu runners (`.github/workflows/precheck.yml`, never macOS).
  It starts first and runs alongside the local checks. Force a mode with
  `--remote-linux` or `--container-linux`. `--no-linux` makes the result
  `incomplete`, which the evidence check rejects.
- **macOS job:** the SwiftPM build, then the unit-test targets that
  `scripts/ci/affected-swift-tests.py` selects, minus the targets Linux runs,
  exactly as CI selects them. `--quick` narrows this to type-level matches,
  which is faster but no longer CI's selection. A build that changes
  `Package.resolved` fails, as in CI.
- **Public API compatibility:** `scripts/ci-api-compatibility.sh <merge-base>`, the
  CI job's command, whenever the exported library products' sources
  (SpeakCore, SpeakSync, SpeakiOS, SpeakHotKeys, SpeakAutomationKit,
  SpeakWatchCore), `Package.*` or the gate's own files change. The open PR's
  title (`gh pr view`, or `PR_TITLE`) declares a break with `!`; without a PR,
  a `type!:` commit subject does. macOS only; elsewhere the result is
  `incomplete`.
- **Android:** `scripts/ci-android.sh`, the Android job's command (android.yml runs it too).
  pre-pr runs it locally only with a working JDK and an approved Maven feed
  (`JSTI_MAVEN_MIRROR`), and otherwise on a remote `precheck/**` branch run,
  as for Linux. It never skips or passes as advisory. `JSTI_ANDROID_LOCAL=1`
  or `=0` forces the choice.
- It fails closed. A required check whose tool is missing fails, and so does a
  Swift change that runs no unit tests or a changed module that no test
  target covers. Path routing lives once in `scripts/ci/routing.json`:
  pre-pr reads it, and ci.yml's and android.yml's path filters are generated
  from it (`python3 scripts/ci/routing.py --write`); the tooling tests fail
  when they drift.
- It never runs UI tests, xcodebuild, the core-journey harness or app launches,
  and Swift tests use a private file Keychain in `.build/pre-pr/`, so it is safe
  on the owner's Mac. CI still runs UI and release gates.
- Paste `scripts/pre-pr --markdown` output (also in `.build/pre-pr/summary.md`)
  into the PR body's **Pre-PR checks** section. Keep the hidden
  `pre-pr-summary` marker. It records `head` and `tree`, the tree of the
  checked working copy, so a run before committing still matches the pushed
  commit if you commit exactly what was checked. CI's `Pre-PR evidence
  (blocking)` job fails CI Gate, before any macOS job starts, unless the newest
  record passed for the exact PR head commit or its identical tree. Re-run it
  after every push. Only Dependabot is exempt.
- `scripts/ci-metrics` reports the escape rate: the share of PR and batch CI
  failures whose head had a passing record. The target is under 1%.
- The machine-readable result is `.build/pre-pr/summary.json`; per-check logs
  are in `.build/pre-pr/logs/`.
- Runs are serialised machine-wide per user (`~/.cache/jsti-pre-pr.lock`) so parallel agents don't overload the Mac into timing flakes; a waiting run says who holds the lock. `JSTI_PRE_PR_LOCK=off` disables it.
- Opt in to running it on every push with `scripts/install-pre-pr-hook`
  (`make install-hooks`). Bypass once with `JSTI_SKIP_PRE_PR=1`.

## Commit & Pull Request Guidelines
- **Never use `git add -A` or `git add .`** — always stage specific files (`git add <path>`) to avoid committing other agents' work
- **Use Conventional Commits** — the type sorts each change into a release-notes section (`scripts/release-notes-lib.mjs`): `feat:` → New and improved, `fix:` → Fixes, `perf:` → Performance; `refactor:`, `build:`, `ci:`, `test:` and `chore:` → Under the hood; `docs:` → Documentation. Commit types do not trigger releases or choose version numbers (see Working with Release Trains)
- Keep commits scoped to a single concern
- Use platform tags in scope: `feat(mac):`, `fix(ios):` — these feed Sparkle release notes
- Pull requests should describe motivation, note user-visible changes, and reference related issues
- Fill the PR template's **Pre-PR checks** section with the `scripts/pre-pr --markdown` output (see Pre-PR Checks); add screenshots when UI shifts
- Direct pushes to `main` are blocked by branch protection; create a branch and PR even for small fixes, then merge through the normal repo gate.

### Working with Release Trains

Conventional commits and platform scopes still generate user-facing notes.
Main merges go to Alpha after successful CI; they do not publish Stable.
Keep candidate source, versions and note hashes frozen while Alpha continues.
Use the manifest and actual GitHub/App Store Connect publication receipts as
version/baseline authority. `VERSION` is a build hint only.

### Batch merging
- To land several ready PRs on one CI run, use `scripts/merge-batch` (create → status → land, or split to bisect a failure); see [Docs/merge-batch.md](Docs/merge-batch.md). Batches land only through their own PR and required checks.
- Score CI changes with `scripts/ci-metrics --days 7`: its scorecard reports PR open-to-merge, required-gate p50/p90, main failure rate and zombie runs, and it also lists the per-job critical path. Run lists and job data are cached locally, and `--since`/`--until` compare windows.

### PR merge unblock checklist
- The `main` ruleset does not require branches to be up to date. A PR that is only `BEHIND` can merge as-is: do not rebase or merge `main` into it, because every push restarts all of its CI and takes a scarce hosted macOS slot. Update a branch from `main` only on a real conflict (`mergeStateStatus` `DIRTY`) or when a fix it needs has landed on `main`.
- Main CI runs every gate after the merge and opens a `ci-main-failure` issue if one fails, so it catches the rare semantic conflict a stale branch misses.
- Merge first, verify on main. On a same-repository pull request every other CI job is skipped and the `CI Gate` job itself checks the passing `scripts/pre-pr` record for its exact head (one hosted-runner wait); auxiliary workflows (Linux, Windows, Android, Flatpak, CodeQL, site media) no longer run on pull requests; Lint, Workers, Linux, macOS, iOS, journeys and API run on main after the merge (and on Dependabot or fork PRs, which carry no trusted record). Add `ci:full` to run every gate on a PR.
- A red main is handled by `.github/workflows/auto-revert.yml`: flake-prone failures are re-run once; then the suspects and failure log go on the `CI failing on main` issue (labels `ci-main-failure`, `agent-fix`) for an agent to fix forward with a normal PR. If main is still red 2 hours after turning red, or 3 more commits merge first, the suspects are reverted by a bot PR whose `CI Gate` admits only an exact revert; each culprit PR gets the `auto-reverted` label and a draft `reland/<pr>` PR. Kill switch: repository variable `JSTI_AUTO_REVERT=off`.
- If `gh pr merge` says “required status checks are expected” while checks look green, a required job is still queued or the run was cancelled; wait for it or re-run it rather than pushing.
- After each push, re-check unresolved review threads (especially CodeRabbit), as new threads can be created on updated diffs and still block merge.
- If admin merge fails with `All comments must be resolved.`, resolve the remaining review threads before retrying.

## SwiftUI Concurrency Patterns

### Singleton ObservableObjects
- Use `@ObservedObject` (not `@StateObject`) when referencing singletons like `TipStore.shared`
- Singletons manage their own lifecycle; `@StateObject` causes ownership conflicts and crashes

### Child View Button Actions
- Don't pass `@ObservedObject` to child views that have button actions
- Pass primitive values (e.g., `isPurchasing: Bool`) and access singleton directly in action:
  ```swift
  Button {
      Task { @MainActor in
          await MySingleton.shared.doWork()
      }
  }
  ```

### Async Delays in SwiftUI
- Prefer `.task { try? await Task.sleep(for: .seconds(2)) }` over `DispatchQueue.asyncAfter`
- The `.task` modifier properly handles view lifecycle and cancellation

### MainActor Deadlock Anti-Pattern
- **Never** use `DispatchSemaphore.wait()` on the MainActor while spawning `Task { @MainActor in }` — this is an instant deadlock
- The semaphore blocks the MainActor, preventing the task from ever executing to signal it
- Use `Thread.sleep` for brief synchronous delays, or restructure as fully `async`

### NotificationCenter Block-Based Observers
- `addObserver(forName:object:queue:block:)` returns an opaque `NSObjectProtocol` token — **always store it**
- Remove with `NotificationCenter.default.removeObserver(token)`, NOT `removeObserver(self, name:, object:)`
- The `removeObserver(self, name:, object:)` variant is for target-action observers only
- Failing to store and remove the token causes a memory leak on each registration cycle

### Audio Engine Resource Cleanup
- When adding guard-let error paths in transcription code, always clean up audio resources started before the guard point
- Call `audioEngine.stop()` and `audioEngine.inputNode.removeTap(onBus: 0)` before throwing
- Compare with existing cleanup paths in the same function to ensure consistency
- Install taps with `installTapSafely` (SpeakCore), never `installTap`: AVFAudio rejects a tap by raising an Objective-C exception that aborts the app. Keep the call inside the block whose failure path removes the tap and stops the engine. SwiftLint `unsafe_audio_tap` enforces this.

## AssemblyAI Universal-3.6 Pro Streaming

Live streaming uses Universal-3.6 Pro (`universal-3-6-pro`); saved Universal-3.5 Pro streaming selections migrate to it (`AssemblyAIModels.legacyUniversal3StreamingIDs`). Universal-3.5 Pro remains the batch model.

### Turn message semantics
- Do not send `format_turns`; Universal-3.6 Pro always formats its single end-of-turn message.
- Commit a turn only when both `end_of_turn=true` and `turn_is_formatted=true`.
- Partial `transcript` values are complete replacements for the current turn, not deltas.
- Track `turn_order` to replace (not append) segments for the same turn.
- Interim text uses replacement semantics — AssemblyAI sends the full turn text each time, not deltas.

### Pre-processing prompt
- The streaming API accepts a contextual `prompt` plus `keyterms_prompt`; neither is a transcript formatting control.
- `keyterms_prompt` entries are sourced from `assemblyAIKeyterms` (comma-separated, max 50 chars each, max 100 items).
- The app currently sends keyterms only. `postProcessingSystemPrompt` remains post-transcription in `PostProcessingManager`.
- When a pre-processing prompt is active, LLM post-processing is automatically skipped.

### Rollout preference
- Prefer core live-transcription integration first; add advanced v3 controls only when a clear app need is confirmed.
- Keep style control in post-processing (`postProcessingSystemPrompt`); native `prompt` is for audio context.

### Connection reliability
- Use EU host first (`streaming.eu.assemblyai.com`) and retry once on global host (`streaming.assemblyai.com`) only when the attempt fails before `Begin` (`!attempt.didBegin`), no fallback has been tried, and the run is not finishing. A `Begin` that takes more than 8 seconds counts as a failure.
- Keep shared live-stream state on the client's `LiveClientStateQueue`; receive/send completions and lifecycle methods must not touch it directly.
- Every callback checks `isCurrent(active, attempt)` before acting, so a late completion from a stopped run or a superseded attempt cannot affect a newly started session.
- Do not establish fallback/reconnect sockets after stopping has begun.
- On failure cleanup, capture the active session before async cancellation so failed runs still persist to History.

### Live audio framing + shutdown guarantees
- Live PCM chunk duration must be 50-1000ms (100ms preferred); sub-50ms frames can trigger close code 3007 (`Input Duration Violation`). `AssemblyAIPCMFramer` sends 100ms frames and pads a final short tail to 50ms.
- Stop sequencing must be: drain every admitted audio frame, send `ForceEndpoint`, wait up to `postStopFinalizeBudget` for the trailing formatted turn, hold for the caller's stop grace, then send `Terminate`. The whole finish is bounded by `finishDeadline` (8 seconds) plus the grace.
- If users report “batch-like” live behaviour (no live text), run a direct WebSocket probe first and capture close code/reason before changing app logic.

### Key files
- `Sources/SpeakCore/Live/Providers/AssemblyAI/` — shared streaming client (`AssemblyAILiveClient` plus its connection, run, sending, framer, transcript and keyterm files)
- `Sources/SpeakCore/Transcription/Providers/AssemblyAIModels.swift` — model IDs, hosts and the streaming URL/keyterms query
- `Sources/SpeakApp/Live/SharedClientLiveController.swift` — macOS adapter that drives the shared client
- `Sources/SpeakApp/Transcription/AssemblyAITranscriptionProvider.swift` — batch (file) transcription

## OpenAI Realtime Transcription

### Endpoint and payload
- Validate OpenAI Realtime transcription changes against the live WebSocket API before shipping; this API changed during rollout and stale docs/assumptions caused regressions.
- All OpenAI transcription models use `wss://api.openai.com/v1/realtime?intent=transcription` with a GA `session.update` payload; do **not** use `?model=<name>` for transcription.
- Do **not** send the legacy `OpenAI-Beta: realtime=v1` header for transcription sessions; it pins the old schema and rejects `session.type`.
- Endpoint shape, event names, payload fields and stop/finalisation sequencing live once in the shared SpeakCore client (see Key files below); macOS and iOS only adapt it, so change the shared client rather than a platform copy.

### Prompt semantics
- `gpt-live-transcribe`, `gpt-transcribe`, `gpt-4o-transcribe`, and `gpt-4o-mini-transcribe`
  support the Realtime transcription `prompt`; `gpt-realtime-whisper` and `whisper-1` reject it.
- `gpt-live-transcribe` and `gpt-transcribe` use plural `languages` hints; existing
  GPT-4o and Whisper integrations use the singular `language` field.
- Use `gpt-live-transcribe` for low-latency live deltas and `gpt-transcribe` for
  completed recordings. Although `gpt-transcribe` can run in Realtime after a
  committed turn, do not present it as a live-delta model.
- Treat the OpenAI transcription `prompt` as vocabulary/keyterm biasing, not a custom formatting or tone prompt. Keep tone/style changes in post-processing.

### Key files
- `Sources/SpeakCore/Live/Providers/OpenAIRealtime/OpenAIRealtimeLiveClient.swift` (+ `…LiveConnection`, `…LiveSending`, `…LiveRun`, `…Protocol`, `…TranscriptAssembler`) — the shared portable client: endpoint, GA `session.update`, readiness gating on `session.updated`, bounded PCM admission, ordered single-in-flight sends, commit/finalisation and per-run identity. Transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP on Windows).
- `Sources/SpeakApp/Transcription/OpenAIRealtimeTranscriptionProvider.swift` and `Sources/SpeakiOS/Services/OpenAIRealtimeWebSocketClient.swift` — thin platform adapters; keep behaviour changes in the shared client, not here.
- Portable lifecycle tests live in `Tests/SpeakDesktopTests/OpenAIRealtime*Tests.swift` and drive the real client through a fake `StreamingWebSocketConnection`.

## xAI Dedicated Speech-to-Text Streaming

### Protocol
- `wss://api.x.ai/v1/stt` is configured entirely by query items (`model=grok-voice-transcribe-2.0`, `encoding=pcm`, `sample_rate`, `interim_results=true`, optional `language`, repeated `keyterm`); there is no start message. Audio goes up as raw binary PCM and must wait for `transcript.created`; `{"type":"audio.done"}` requests `transcript.done`. This is a different protocol from the Grok Voice session in `XAILiveClient`, which shares the `xai/` prefix and credential.
- Server frames are `transcript.partial` with `is_final`/`speech_final` (there is no `transcript.chunk`). A final's identity is `channel_index` + `start`: a locked chunk restated as an utterance final has the same start and is dropped, while identical text at a new start is a genuine repeat. A non-empty `transcript.done` replaces the folded finals; an empty one keeps them.
- Only `transcript.done` completes a session: the server closes the socket after it, so a closure before it (even after `audio.done` left) or a finish budget that elapses without it is published as an error (`sessionNotReady`, `missingCompletion` or `transportStalled`) before the finish returns the locked spans received so far. Hosts keep that text as recovery material, not as a completed transcript.

### Key files
- `Sources/SpeakCore/Live/Providers/XAISpeechToText/XAISpeechToTextLiveClient.swift` (+ `…LiveRun`, `…LiveConnection`, `…LiveSending`, `…LiveProtocol`, `XAISpeechToTextEvent.swift`) — the shared portable client: injected transport, readiness gating on `transcript.created`, bounded single-in-flight sends, one bounded finish and per-run identity. `LiveTranscriptionClientFactory` (Apple) and `DesktopLiveTranscription` (Windows) construct it; the desktop factory admits only `XAISpeechToText.liveCatalogID`, never the Grok Voice route.
- Portable lifecycle tests: `Tests/SpeakDesktopTests/XAISpeechToText*Tests.swift`; established protocol expectations: `Tests/SpeakCoreTests/XAISpeechToTextLiveClientTests.swift`.

## Accessibility Text Insertion

### API semantics
- `kAXSelectedTextAttribute` — inserts at cursor position (or replaces selection). Preferred default.
- `kAXValueAttribute` — replaces the entire field content. Use as fallback.
- Not all apps support `kAXSelectedTextAttribute`; fall back gracefully.
- `SmartTextOutput` skips accessibility entirely for known problematic apps (Electron, Chromium, etc.).
- Do not probe the focused AX element synchronously at recording start; check permission only, then defer AX readiness checks until the first insertion attempt.

### Settings
- `AccessibilityInsertionMode`: `.insertAtCursor` (default) or `.replaceAll`
- Only relevant when `TextOutputMethod` is `.smart` or `.accessibilityOnly`

## Downloaded Local Models (macOS)

- Treat downloaded local models as a distinct feature from Apple Speech: use `local/...` identifiers for downloaded models and keep Apple Speech under `apple/local/...`.
- Keep settings structured as top-level **Local** vs **Remote**, then **Batch** vs **Streaming** within the selected side; mirror the same interaction pattern across transcription and post-processing.
- Local model UI should show clear catalogue/source sections, Hugging Face discovery/import when supported, model size, selected/downloaded/prepared state, runtime install state, and local-only copy. Hide runtime install controls after the runtime is installed.
- For local post-processing, the prompt editor must be visible for downloaded local LLMs as well as remote OpenRouter models; pass `postProcessingSystemPrompt` into the local model as an explicit system instruction. Built-in rules cleanup may ignore the prompt, but the UI must say so.
- Local LLM post-processing must honour the user-defined prompt in the model context/system instruction, including formatting-only prompts such as one full stop after each word.
- Empty or silent recordings must remain empty through post-processing; never emit placeholder text such as "This is a raw transcript." for no-input transcription.
- In History and headers, always resolve model identifiers to friendly names, including imported/downloaded local models. Avoid generic labels such as “Downloaded Local Model” when a repo/model name can be derived.

## Commit Message Tagging
- Prefix commit messages with a platform tag or scope: `[mac]`/`[ios]` or `(mac)`/`(ios)` (e.g., `fix: [mac] add recording sound picker` or `fix(mac): add recording sound picker`).
- These tags/scopes feed the Sparkle release notes generator so macOS updates only list mac-specific changes.

## Security & Configuration Tips
- Do not commit personalised signing assets
- Keep bundle identifiers within `Config/AppInfo.plist` and adjust via scripts
- API keys stored in Keychain via `SecureStorage` (SpeakCore) / `SecureAppStorage` (SpeakApp)
- Keychain service: `com.github.speakapp.credentials`, account: `speak-app-secrets`

## App Store Connect / iOS Signing (sensitive)
- App Store Connect API Key ID: stored in secure notes (do not commit)
- App Store Connect Issuer ID: stored in secure notes (do not commit)
- App Store Connect API key: store base64 in `.env` as `APP_STORE_CONNECT_API_KEY` (do not commit)
- iOS distribution cert: store base64 in `.env` as `IOS_DISTRIBUTION_P12` (password in `.env` as `IOS_DISTRIBUTION_PASSWORD`)
- GitHub secrets used by CI: `APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_ISSUER_ID`, `APPLE_TEAM_ID`, `IOS_DISTRIBUTION_P12`, `IOS_DISTRIBUTION_PASSWORD`, `IOS_APPSTORE_PROFILE`, `IOS_WIDGET_APPSTORE_PROFILE`; `IOS_KEYBOARD_APPSTORE_PROFILE` is optional when the workflow can reuse or create a valid portal profile
- Required entitlements: App Group `group.com.justspeaktoit.ios` and iCloud container `iCloud.com.justspeaktoit.ios`
- The feature-flagged watch app and complication use their own App Group `group.com.justspeaktoit.watch` and bundle ids; see [`Docs/watch-provisioning.md`](Docs/watch-provisioning.md)
- The keyboard extension accepts `IOS_KEYBOARD_APPSTORE_PROFILE` when set and otherwise uses the validated portal-profile fallback; see [`Docs/ios-testflight-release.md`](Docs/ios-testflight-release.md) before changing portal capabilities or regenerating profiles.
- Never commit private keys or provisioning profile contents.

## PostHog Maintenance

For PostHog feature flags and consented post-release product-event checks, use the hosted
MCP connection and [maintenance guide](Docs/posthog-maintenance.md). Verify the
Production project before querying; retain evidence and deduplicate follow-up issues.
Use Sentry below for production crashes and exceptions; PostHog does not capture them.

## Sentry Error Monitoring
- **Region:** EU (de.sentry.io) — use `https://de.sentry.io/api/0/` for all API calls
- **Org slug:** `tally-lz`
- **Project slug:** `justspeaktoit`
- **Auth token:** stored in `.env` as `SENTRY_AUTH_TOKEN` (do not commit)
- **DSN:** configured in `Sources/SpeakApp/Analytics/SentryManager.swift`
- **GitHub CI secret:** `SENTRY_AUTH_TOKEN` lives only in the `sentry` environment, whose deployment branch policy admits only `main`. Only the `sentry-upload` job in `release-mac.yml` reads it; the build job, which holds the signing secrets, hands dSYMs over as an artefact. Rotate with `gh secret set SENTRY_AUTH_TOKEN --env sentry`; never add it as a repository secret.

### Querying Sentry from CLI
```bash
# Load token from .env
export SENTRY_AUTH_TOKEN="$(sed -n 's/^SENTRY_AUTH_TOKEN=//p' .env | tail -n1)"
export SENTRY_ORG="tally-lz"
export SENTRY_PROJECT="justspeaktoit"

# List unresolved issues
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://de.sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&sort=date&limit=25"

# Get latest event for an issue
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://de.sentry.io/api/0/organizations/$SENTRY_ORG/issues/{ISSUE_ID}/events/latest/"

# Ignore/resolve an issue
curl -s -X PUT -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" -H "Content-Type: application/json" \
  -d '{"status":"ignored"}' \
  "https://de.sentry.io/api/0/organizations/$SENTRY_ORG/issues/{ISSUE_ID}/"
```

## GitHub Actions Security
- New secrets belong in an environment with a `main`-only deployment branch policy (as `sentry` and `windows-signing` do), read only by the job that needs them. The Apple signing, notarisation, App Store and Sparkle secrets used by the release workflows are still repository secrets pending migration; do not add more.
- `issue_comment` / `pull_request_review_comment` / `workflow_run` jobs that hold secrets must gate on `author_association` or `head_repository.full_name == github.repository` before running.
- Pin third-party actions to a full commit SHA with a version comment, and pin every action in a job that holds an environment secret; self-hosted runners are only for `main` pushes and approved same-repo SHAs.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking -- do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge -- do NOT use MEMORY.md files
- Keep Beads automation on Copilot CLI surfaces (`AGENTS.md` and repo-local `.github/hooks/*.json`); do NOT add Claude-specific Beads files such as `CLAUDE.md` or `.claude/settings.json`
- Beads hooks can generate a root `issues.jsonl` artefact during commits. Before committing or pushing, check for and exclude that file; if a hook already staged or committed it, rewrite the commit cleanly rather than shipping the artefact.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
