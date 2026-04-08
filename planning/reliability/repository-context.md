# Repository Context — Reliability

## Release pipeline
- **macOS**: Conventional commit on `main` → `auto-release.yml` calculates bump → pushes `mac-v*` tag → `release-mac.yml` builds, notarises, publishes DMG + appcast.xml, updates Homebrew tap.
- **iOS**: Manual `workflow_dispatch` → `release-ios.yml` → TestFlight via App Store Connect API.
- **Rollback (macOS)**: Push the previous `mac-v*` tag; Sparkle will serve the prior version. Or update `appcast.xml` to point to previous build.
- **No staging/canary**: Sparkle updates go to all users immediately on release.

## Error monitoring
- Sentry EU region: `https://de.sentry.io/api/0/`
- Org: `tally-lz`, Project: `justspeaktoit`
- DSN in `Sources/SpeakApp/SentryManager.swift`

## Known CI risks
- `release-mac.yml` uses `xcode-version: latest-stable` — floating version, potential environment drift on Apple updates.
- `auto-release.yml` skips bot commits via commit message matching — fragile if commit message format changes.
- `fix(ios):` scoped commits trigger macOS auto-release (scope filtering not implemented in the workflow).

## Audio/transcription
- AudioEngine resource cleanup must always call `audioEngine.stop()` + `audioEngine.inputNode.removeTap(onBus: 0)` on all error paths.
- AssemblyAI streaming v3: `format_turns=true` produces two end-of-turn messages; only commit the formatted one.
- MainActor deadlock risk: never use `DispatchSemaphore.wait()` on MainActor with `Task { @MainActor in }`.

## Security storage
- API keys in Keychain: service `com.github.speakapp.credentials`, account `speak-app-secrets`.
- Missing key must degrade gracefully (show error, not crash).

## Landing page
- `landing-page/` directory: static site deployed to Cloudflare Pages
- Deploy workflow: `.github/workflows/deploy-landing-page.yml`
- Trigger: push to `main` with paths `landing-page/**`, or workflow_dispatch
- No PR preview deployment; changes go live on main merge
- Rollback: Cloudflare Pages dashboard (instant rollback to prior deployment)
- No build step; pure static HTML/CSS/JS
- Secrets used: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
