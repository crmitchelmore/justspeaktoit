# Just Speak to It for Android

Native Android app (Kotlin, Jetpack Compose). Scope, supported devices and the feature
comparison with the Mac app are in the [Android parity matrix](../Docs/android-parity-matrix.md).

This is a developer build: it is not published to Google Play.

## Requirements

- JDK 17
- Android SDK with platform 36 (Android Studio installs it, or set `ANDROID_HOME`)
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

CI runs the same tasks in [`.github/workflows/android.yml`](../.github/workflows/android.yml)
and uploads the debug APK as the `justspeaktoit-android-debug` artefact.

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
2. Copy the feed's Maven URL from "Connect to feed" > Gradle. For local builds, add a personal
   access token with Packaging (Read) to `~/.gradle/gradle.properties` if the feed is private.
3. To use it in CI too, make the feed public, or add credentials to the workflow, and set the
   repository variable `JSTI_MAVEN_MIRROR`.

## Layout

```
app/src/main/java/com/justspeaktoit/android/
├── MainActivity.kt          # permission flow and lifecycle (stops dictation when the app leaves the screen)
├── dictation/
│   ├── DictationState.kt    # pure state machine, events and error mapping
│   ├── RecognizerAvailability.kt  # pure availability and language resolution
│   ├── AndroidSpeechEngine.kt     # SpeechRecognizer adapter (main thread)
│   └── DictationViewModel.kt
├── security/                # Keystore-backed AES-GCM secret store for BYOK keys
├── output/                  # copy and share
└── ui/                      # Compose screen and brand theme
```

Policy lives in plain Kotlin so it is unit-tested on the JVM; Android classes stay in the
adapter, ViewModel and UI.

## Privacy

- **On-device** mode keeps audio on the phone. **Speech service** mode uses the device's
  default recognition service, which may send audio to its provider. The app never switches
  modes on its own.
- Audio is not stored. Transcripts stay in memory until cleared.
- Secrets are encrypted with a non-exportable Android Keystore key. App data is excluded
  from cloud backup and device transfer.
