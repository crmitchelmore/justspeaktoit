# scripts/

Repository tooling, grouped by purpose. Tests for top-level and grouped helpers
live in `tests/` unless a folder carries its own `test_*.py`.

| Folder | Purpose |
| --- | --- |
| `accessibility/` | Apple and Linux accessibility lint (`make lint` runs the Apple check) |
| `assets/` | App, DMG and desktop icon generators |
| `ci/` | CI-only helpers: routing, affected tests, retries, crash/sample collection, API and boundary gates; `ci/pre_pr/` holds `pre-pr`'s planner, test selection, check runner, summary and lock |
| `core-journey/` | The core-journey contract gate, its stages and UI verifier |
| `dev/` | Local conveniences (`.env` loading, checksum verification) |
| `ios/` | iOS CI simulator, test products and test evidence |
| `linux/`, `linux-local-runtime/` | Linux desktop checks, Flatpak staging/qualification, the Whisper runtime |
| `loopback/` | The credential-free WebSocket peer for live-provider runtime tests, one module per provider |
| `qualification/` | Modulate opening-audio qualification and its source-state guard |
| `release-maintenance/` | Hand-run release-note, crash-rate and Sparkle key tools |
| `local-llm-runtime/`, `migration/`, `site-media/` | Local LLM runtime build, migration fixtures, site media |
| `windows-*/` | Windows bundle, package, cross-compile, CloudKit and runtime tooling |

## What stays at the top level

- **Typed entry points** documented in `AGENTS.md`: `pre-pr`, `merge-batch`,
  `ci-metrics`, `swiftlint.sh`, `swiftformat.sh`, `with-test-keychain.py`,
  `linux-precheck`, `install-pre-pr-hook`, `update-android-assets` and the CI
  job commands `ci-android.sh`, `ci-portable-linux.sh`, `ci-api-compatibility.sh`.
- **Release-pinned scripts.** `release-mac.yml` and `release-ios.yml` check out
  the frozen manifest source and run scripts from it, while the workflow itself
  comes from `main`. Every script a release workflow or release action
  (`package-mac-release`, `publish-speak-cli`, `setup-apple-toolchain`) runs, and
  the libraries those scripts load, keep their paths so a manifest frozen before
  a move still resolves. The Apple Ruby helpers stay beside `release-apple.rb`,
  which loads them.
- `check-pre-pr-evidence.py`: CI fetches it from the pull request's base commit.
- `azure-speech-proxy.py` and `generate-release-train-config.py`: app sources
  name these paths.
