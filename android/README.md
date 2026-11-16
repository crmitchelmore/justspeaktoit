# Just Speak to It for Android

Native Android app (Kotlin, Jetpack Compose). Scope, supported devices and the feature
comparison with the Mac app are in the [Android parity matrix](../Docs/android-parity-matrix.md).

Green `main` builds are signed and published to Google Play's internal testing track once the
owner has configured the release secrets; see the
[Play submission guide](../Docs/android-play-store-submission.md).

## Requirements

- JDK 17
- Android SDK with platform 37 (Android Studio installs it, or set `ANDROID_HOME`)
- A phone or emulator running Android 10 (API 29) or newer. On-device recognition needs
  Android 12+ and a speech service that provides it.

## Build and test

```bash
cd android
./gradlew testDebugUnitTest   # JVM unit tests
./gradlew lintDebug           # Android lint: zero warnings, no baseline
./gradlew assembleDebug       # app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug        # install on a connected device
```

Android lint treats every warning as an error and the Kotlin compiler fails on any warning
(`android/app/build.gradle.kts`). Only the checks that report a newer upstream release are
disabled, because they would fail an unchanged tree; Dependabot owns dependency currency.

CI runs the unit test, lint, debug build and R8 release bundle tasks (not `installDebug`, so
installation is not checked) in [`.github/workflows/android.yml`](../.github/workflows/android.yml)
and uploads the debug APK as the `justspeaktoit-android-debug` artefact. On `main` its `release`
job then builds the upload-signed AAB (`justspeaktoit-android-release`) and, when configured,
publishes it to the internal testing track.

Pull requests that change only `android/**`, `.github/workflows/android.yml` or
`Docs/android-*.md` skip the macOS and iOS jobs in `ci.yml`. The required checks still
report, and any other changed file, or a push to `main`, runs every Apple gate.

### Android dependency sources

`settings.gradle.kts` picks one source for every library and Gradle plugin:

| Where Gradle runs | Source |
| --- | --- |
| `JSTI_MAVEN_MIRROR` (or `-Pjsti.mavenMirror`) set | Only that feed |
| GitHub-hosted runner (`GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`) | Google Maven and Maven Central |
| Anywhere else (developer machines, self-hosted runners) | None: the build stops and names `JSTI_MAVEN_MIRROR` |

Machines governed by a package-feed policy (for example Microsoft CFS) must never fetch from
public registries, so local builds need a feed. Gradle itself comes from the wrapper, pinned by
`distributionSha256Sum`, and CI validates the wrapper jar. The Android workflow stays on
GitHub-hosted runners and reads an optional feed from the repository variable `JSTI_MAVEN_MIRROR`.

```bash
export JSTI_MAVEN_MIRROR=https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/maven/v1
./gradlew assembleDebug
```

Optional personal feed (owner steps; the CFS proxy does not serve Maven today):

1. In a personal Azure DevOps organisation, create an Artifacts feed and add the upstream
   sources Maven Central and Google Maven (`https://dl.google.com/android/maven2/`).
2. Copy the feed's Maven URL from "Connect to feed" > Gradle. If the feed is private, put a
   personal access token with Packaging (Read) in `~/.gradle/gradle.properties` as
   `jsti.mavenMirrorToken=<token>` (optionally `jsti.mavenMirrorUser=<name>`), or export
   `JSTI_MAVEN_MIRROR_TOKEN`/`JSTI_MAVEN_MIRROR_USER`.
3. To use it in CI, set the repository variable `JSTI_MAVEN_MIRROR`. A public (anonymous-read)
   feed needs nothing else. A private feed's token must live in a `main`-only environment, which
   pull-request builds cannot read, so pull requests would keep using the hosted-runner default.

Without a feed, get a branch's APK from GitHub-hosted runners instead.
`scripts/linux-precheck --job android --tree . --base origin/main` (which `scripts/pre-pr` runs) pushes
a throwaway `precheck/**` branch. `precheck.yml` runs `scripts/ci-android.sh` there and uploads the
debug APK as `justspeaktoit-android-debug`. Install it on an emulator with
`gh run download <run-id> -n justspeaktoit-android-debug && adb install -r -g app-debug.apk`.

## Layout

```
app/src/main/java/com/justspeaktoit/android/
├── MainActivity.kt          # permission flow and lifecycle (stops dictation when the app leaves the screen)
├── dictation/
│   ├── DictationState.kt    # pure state machine, events and error mapping
│   ├── RecognizerAvailability.kt  # pure availability and language resolution
│   ├── AndroidSpeechEngine.kt     # SpeechEngine: SpeechRecognizer adapter (main thread)
│   ├── CloudCapture.kt      # owns the Cloud recording and deadline-bounded, abortable blocking IO
│   ├── RecorderRetirement.kt      # process-wide bound on recorder stops that outlive their owner
│   ├── DictationLanguages.kt      # the shared language catalogue and Automatic → phone language
│   ├── DictationEngineSelector.kt # mode, cloud model, language, availability and the plan a session follows
│   ├── DictationSessionController.kt  # session lifecycle, microphone hold and cleanup
│   ├── SessionRequests.kt   # provider requests: key reads, deadlines and failure mapping
│   ├── SharedAudioSource.kt # reads audio shared by other apps (content:// only)
│   └── DictationViewModel.kt      # projects its owners into UI state; production wiring in Factory
├── cloud/                   # BYOK catalogue, WAV capture, OpenAI-compatible client, cleanup policy
├── corrections/             # personal corrections and the cloud vocabulary prompt
├── history/                 # transcript history, retention, atomic storage and usage insights
├── settings/                # non-secret preferences
├── telemetry/               # opt-in PostHog analytics and Sentry crash reports, consent gating
├── tips/                    # Google Play Billing tip jar
├── security/                # Keystore-backed AES-GCM secret store for BYOK keys
├── output/                  # copy and share (Read aloud lives in ui/ReadAloudButton.kt)
└── ui/                      # Compose screen and brand theme
```

Policy lives in plain Kotlin so it is unit-tested on the JVM; Android classes stay in the
adapters and UI. The ViewModel takes its engine, recorder factory, cloud client, history,
preferences and secret store as interfaces, so `DictationViewModelTest` drives the real
ViewModel with fakes; `DictationEngineSelectorTest` and `DictationSessionControllerTest` drive its
owners directly.

Shared catalogues are generated from `Sources/SpeakCore`, never parsed from Swift:
`assets/settings_search.json` (settings search), `assets/settings_schema.json` (the raw configuration
editor's fields), `assets/cloud_catalog.json` (cloud providers,
credential IDs, the models Android offers with their wire fields, the cleanup model and prompt, the
dictation languages and the vocabulary prompt limits), `assets/tip_catalog.json` (tip product IDs,
names and emoji) and `assets/troubleshooting.json` (the phone Troubleshooting findings and fixes for each
state, from `MobileTroubleshooting`). Regenerate them with `scripts/update-android-assets`; the Swift export tests fail when an asset is
stale. The build's `generateCloudCatalog` task writes `GeneratedCloudCatalog.kt` from the cloud asset,
so `CloudCatalog` and `CleanupPolicy` hold no hand-typed copy; only each provider's base URL and
display name (Android transport) are authored, and `CloudCatalogParityTest` checks the generated
values against the asset and that every provider has a transport.

## Privacy

- **On-device** mode keeps audio on the phone. **Speech service** mode uses the device's
  default recognition service, which may send audio to its provider, and which may keep it
  under that provider's terms. A running session never changes mode, and Cloud is never chosen
  automatically. Without an explicit choice, a new session uses on-device recognition when it is
  ready and otherwise the speech service, and the screen always shows which mode will be used.
  Choose a mode explicitly to pin it.
- The app itself does not store audio, except for Cloud mode's temporary upload file and
  cancelled Cloud recordings kept in History (below).
- **Cloud** mode uploads audio to the provider chosen in Settings with your key. The
  recording is a temporary file that is deleted after the request, whether it succeeds or fails.
- **Keep audio when a recording is cancelled** (Settings, on by default; shared key
  `keepAudioOnCancel` with the other apps): cancelling a Cloud recording moves its audio to
  app-private storage and adds a Cancelled History entry with a **Transcribe** action, which uses
  the current cloud model and key. A successful transcription replaces the entry and deletes the
  audio; deleting the entry, clearing History or retention pruning deletes it too. Recordings under
  a quarter of a second are discarded. Off restores the old behaviour (the audio is deleted and
  nothing is recorded). On-device and speech-service modes never give the app audio, so the
  setting does not apply to them. Leaving the app or a capture failure still discards the audio.
- Optional cleanup sends the final transcript text (not audio) to the chosen model's provider:
  a native provider (Anthropic, OpenAI, Google Gemini, Groq or Mistral) or OpenRouter.
- History is stored only in app-private storage (excluded from backup) and follows the
  retention chosen in History; Off saves nothing and deletes existing entries.
- Secrets are encrypted with a non-exportable Android Keystore key. App data is excluded
  from cloud backup and device transfer.
- **Share anonymous analytics** and **Send crash reports and diagnostics** (Settings › Privacy,
  shared keys `analyticsConsent` and `diagnosticsConsent`) are off until the user turns them on;
  the app asks once on first launch with both switches off. Analytics sends the Mac's three
  first-rollout events to PostHog EU with coarse context and a random ID that opting out deletes,
  and only from release builds given `POSTHOG_PROJECT_KEY`. Crash reports go to Sentry EU from
  release builds only, without user, IP, screenshots or an installation ID. Neither ever includes
  transcripts, audio, prompts or keys.
- **Support development** offers optional Google Play tips (consumables that unlock nothing); a
  sideloaded or debug build shows that tips are available in the Google Play version.
