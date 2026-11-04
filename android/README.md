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

### Package feeds

By default Gradle resolves from Google Maven, Maven Central and the Gradle Plugin Portal.
On machines that must use a single proxy feed, point every repository at it:

```bash
./gradlew -Pjsti.mavenMirror=https://<feed>/maven/v1 assembleDebug
# or: export JSTI_MAVEN_MIRROR=https://<feed>/maven/v1
```

The feed must proxy Google Maven, Maven Central and the Gradle Plugin Portal.

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
  default recognition service, which may send audio to its provider. The app never switches
  modes on its own.
- **Cloud** mode uploads audio to the provider chosen in Settings with your key. The
  recording is a temporary file that is deleted after the request, whether it succeeds or fails.
- Optional cleanup sends the final transcript text (not audio) to OpenRouter.
- History is stored only in app-private storage (excluded from backup) and follows the
  retention chosen in History; Off saves nothing and deletes existing entries.
- Secrets are encrypted with a non-exportable Android Keystore key. App data is excluded
  from cloud backup and device transfer.
