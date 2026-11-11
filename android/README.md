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
./gradlew lintDebug           # Android lint
./gradlew assembleDebug       # app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug        # install on a connected device
```

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
│   ├── AndroidSpeechEngine.kt     # SpeechRecognizer adapter (main thread)
│   └── DictationViewModel.kt
├── cloud/                   # BYOK catalogue, WAV capture, OpenAI-compatible client, cleanup policy
├── history/                 # transcript history, retention and atomic storage
├── settings/                # non-secret preferences
├── security/                # Keystore-backed AES-GCM secret store for BYOK keys
├── output/                  # copy and share
└── ui/                      # Compose screen and brand theme
```

Policy lives in plain Kotlin so it is unit-tested on the JVM; Android classes stay in the
adapter, ViewModel and UI. `CloudParityTest` reads `Sources/SpeakCore` to keep model IDs,
credential IDs and the cleanup prompt identical to the Mac app.

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
- Optional cleanup sends the final transcript text (not audio) to OpenRouter.
- History is stored only in app-private storage (excluded from backup) and follows the
  retention chosen in History; Off saves nothing and deletes existing entries.
- Secrets are encrypted with a non-exportable Android Keystore key. App data is excluded
  from cloud backup and device transfer.
