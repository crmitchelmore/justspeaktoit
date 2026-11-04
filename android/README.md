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

### Package feeds

Package-feed policy forbids resolving directly from public registries, so Gradle has no
public repositories. Every dependency and plugin comes from one approved feed, and without
one the build stops with `blocked: no approved Maven feed configured`:

```bash
./gradlew -Pjsti.mavenMirror=https://<feed>/maven/v1 assembleDebug
# or: export JSTI_MAVEN_MIRROR=https://<feed>/maven/v1
```

The feed must proxy Maven Central and Google Maven; it serves both the libraries and the
Gradle plugin markers. CI reads the feed URL from the repository variable `JSTI_MAVEN_MIRROR`
and fails before Gradle runs if it is not set. No approved feed exists yet: the CFS proxy
returns 404 for Maven paths, so Android builds are currently blocked.

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
