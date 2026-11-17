# Android on-device transcription and cleanup models

Decision record for #1593, which feeds the Android half of #1650. Assessed on
13 November 2026 against the primary sources linked below; re-check the device
lists and API stages before implementing, as both change often.

Android's private routes are the platform recogniser
(`SpeechRecognizer.createOnDeviceSpeechRecognizer`, Android 12+) and, since
#1658, downloaded Whisper models run by whisper.cpp in the app (see
[Downloaded Whisper on Android](#downloaded-whisper-on-android)). Since #1660,
cleanup can also run on downloaded GGUF models through llama.cpp (see
[Downloaded cleanup on Android](#downloaded-cleanup-on-android) and
[android-parity-matrix.md](android-parity-matrix.md)). The Mac,
Windows and Linux apps download Whisper, Parakeet and GGUF cleanup models under
shared `local/...` identifiers (`Sources/SpeakCore/LocalModels/`).

## Decision

| Need | Decision | Delivery |
| --- | --- | --- |
| Downloaded transcription | **Adopt whisper.cpp**, batch only, reusing the shared `WhisperCppModels` pins and `local/whisperkit/*` identifiers. Pick the default model from measured device numbers. | #1658 |
| On-device cleanup (supported phones) | **Adopt Gemini Nano** through the ML Kit Prompt API as an optional, in-app-only route on devices that report it. | #1659 |
| On-device cleanup (every other phone) | **Adopt llama.cpp** with the shared `ModelCatalog.localPostProcessing` GGUF models. | #1660 |
| ML Kit GenAI Speech Recognition | **Defer.** Alpha API, Advanced mode is limited to recent flagships, and Basic mode adds nothing over the platform recogniser on our supported Android versions. Revisit when it reaches beta. | none |
| sherpa-onnx (Parakeet, streaming) | **Defer.** Strong runtime, but Parakeet v3 needs about 2 GB of RAM and the streaming route can follow once whisper.cpp numbers exist. | none |
| LiteRT-LM / MediaPipe LLM | **Reject for now.** Its `.litertlm` artefacts do not match the shared GGUF catalogue. | none |
| ML Kit Proofreading / Rewriting | **Reject.** They cannot honour a custom prompt. | none |

## Candidates

### ML Kit GenAI and Gemini Nano (AICore)

ML Kit's GenAI APIs run Gemini Nano inside AICore, an Android system service
that downloads, updates and runs the model; apps share one copy of the base
model ([ML Kit GenAI][mlkit-genai], [Gemini Nano][android-nano]).

- **Licence and terms:** proprietary model, used under the
  [ML Kit GenAI Additional Terms][genai-terms]. They require an audience of 18 or
  over (our Play listing already targets 18+, see
  [android-play-store-submission.md](android-play-store-submission.md)), forbid
  extracting the weights, forbid clinical use, and exclude "Preview" or
  "Experimental" services from production.
- **Size:** downloaded by AICore, not by the app, so it does not count against
  our APK or storage. The app can trigger and observe the download
  (`checkStatus()`, `download()`) but cannot choose or pin the model version;
  output can differ between Nano versions ([ML Kit GenAI][mlkit-genai]).
- **Device support:** an explicit allow-list of recent flagships (Pixel 9 to
  11, Galaxy S25/S26, Z Fold7/8, OnePlus 13/15, Xiaomi 15/17 and others) on
  Nano 2, 3 or 4 depending on the device and its RAM. Not on unlocked
  bootloaders. Mid-range phones are largely absent ([ML Kit GenAI][mlkit-genai]).
- **Prompt API** (`genai-prompt`, beta): custom text prompts, input under 4,000
  tokens, temperature, `topK`, `seed` and `maxOutputTokens`
  ([Prompt API][prompt-api], [get started][prompt-start]). Since `1.0.0-beta5`
  a request can carry a `SystemInstruction` where `getAvailableFeatures()` includes
  `Feature.SYSTEM_PROMPT` (`isSystemPromptAvailable()` is deprecated).
- **Proofreading** (beta): English, Japanese, French, German, Italian, Spanish
  and Korean, input under 256 tokens, fixed behaviour with a `VOICE` input type
  ([Proofreading][proofreading]). It cannot apply the user's cleanup prompt.
- **Speech Recognition** (`genai-speech-recognition`, alpha, no SLA): Advanced
  mode uses Gemini on Pixel 10/11 and devices on listed Snapdragon, Dimensity
  and Exynos chipsets, with 21 locales; Basic mode wraps the traditional
  on-device recogniser on API 31+. It streams partials with word timings and can
  also transcribe files (MP3, WAV, FLAC, M4A, OGG), which the platform
  recogniser cannot ([Speech Recognition][mlkit-speech]).
- **Latency and battery:** Google publishes no per-device latency. AICore uses
  the device's accelerators, enforces a per-app request quota (`BUSY`) and a
  long-window battery quota (`PER_APP_BATTERY_USE_QUOTA_EXCEEDED`)
  ([ML Kit GenAI][mlkit-genai]).
- **Privacy and offline:** inference is local and AICore keeps no record of
  inputs or outputs; it follows Private Compute Core rules, with model
  downloads routed through Private Compute Services ([Gemini Nano][android-nano]).
  Works offline once the model and feature configuration are present, but a
  freshly set-up device may need minutes to hours online before features
  appear ([Speech Recognition][mlkit-speech]).
- **Surface limit:** inference is allowed only while the app is the top
  foreground app; background and foreground-service use returns
  `BACKGROUND_USE_BLOCKED` ([ML Kit GenAI][mlkit-genai]). Our keyboard runs
  inside another app, so Gemini Nano cleanup is in-app only. The keyboard does
  not run cleanup today; its voice edit uses the default cloud cleanup model
  when Gemini Nano is chosen.

### Gemini Nano cleanup as shipped (#1659)

- **Dependency:** `com.google.mlkit:genai-prompt:1.0.0-beta5` from Google Maven
  (`android/gradle/libs.versions.toml`), checked on 16 November 2026 (the
  documentation still showed beta4). The library's `minSdk` is 26, below the
  app's 29, so no `tools:overrideLibrary` or runtime SDK guard is needed. Its
  manifest adds the AICore service binding permission, a `<queries>` entry for
  `com.google.android.aicore`, and ML Kit's init provider and component
  discovery service.
- **Identifier:** `android/local/GeminiNano` (`AndroidLocalModels` in SpeakCore,
  exported as `geminiNano` in `assets/cloud_catalog.json`, with the 4,000-token
  input limit). It is kept out of `cleanupModels`, which are all cloud routes
  that need a key.
- **Offering:** the cleanup picker (Settings and profiles) asks `checkStatus()`
  when it opens, never at app start. Gemini Nano is listed under
  **On this phone** when it is available, downloadable or downloading; choosing
  it while downloadable starts the AICore download, with progress shown on the
  row. On other phones the section says why it isn't offered. Downloaded
  llama.cpp cleanup models (#1660) are listed below it in the same section once
  downloaded (Settings only, not profiles).
- **Request:** the shared `TranscriptCleanupPolicy` prompt, or the user's cleanup
  prompt, goes as the system instruction, and the transcript goes separately as
  the same JSON data the cloud routes send (`CleanupPolicy.userMessage`). On an
  AICore build without system instruction support the instruction comes first
  in one prompt, still with the transcript as data. Temperature is 0.2.
- **Guards:** an empty transcript never calls the model. The app must be the
  resumed activity before the request and again before generation.
  `countTokens` over the limit, a reply cut short at the output limit, an empty
  reply, `BACKGROUND_USE_BLOCKED`, `BUSY`, `PER_APP_BATTERY_USE_QUOTA_EXCEEDED`
  and every other error keep the original transcript and show the reason. There
  is no cloud fallback.
- **Code:** `ondevice/GeminiNanoCleanup.kt` holds the logic behind the
  `GeminiNanoModel` interface, tested with a fake (`GeminiNanoCleanupTest`);
  `ondevice/MlKitGeminiNano.kt` is the only file that touches ML Kit.
- **Telemetry:** ML Kit GenAI sends Google diagnostics and usage data (device
  and app information, performance, input and output sizes, error codes), not
  the transcript itself. The Play data safety answers cover it; see
  [android-play-store-submission.md](android-play-store-submission.md).
- **Device acceptance** is still open: the manual checks
  `android-gemini-nano-pixel-offline`, `android-gemini-nano-samsung-offline` and
  `android-gemini-nano-unsupported` in [manual-checks.yml](manual-checks.yml).

### whisper.cpp

- **Licence:** MIT (runtime); OpenAI Whisper weights are MIT
  ([whisper.cpp][whisper-cpp]). Latest release v1.9.5 (6 October 2026).
- **Size and memory** ([whisper.cpp memory table][whisper-cpp]): tiny 75 MiB
  disk / ~273 MB RAM, base 142 MiB / ~388 MB, small 466 MiB / ~852 MB, medium
  1.5 GiB / ~2.1 GB. Our shared pins are Tiny (77.7 MB), Base (148 MB), Small
  (488 MB) and Large v3 Turbo q5_0 (574 MB), with SHA-256 digests
  (`Sources/SpeakCore/WhisperCppModels.swift`). Integer quantisation shrinks
  them further.
- **Device support:** any arm64 Android phone via the NDK, using NEON on the
  CPU; the upstream Android example targets `minSdk 26` and recommends tiny or
  base on phones ([whisper.android][whisper-android]). The Vulkan backend
  exists but Android GPU drivers vary, so plan for CPU.
- **Latency and battery:** no primary-source phone benchmarks exist. Whisper is
  a 30-second-window batch model, so text arrives after stop, not as partials.
  #1658 must measure real-time factor, time-to-text and battery on a mid-range
  and a flagship phone before choosing a default, and must keep keyboard use
  within the IME's 10-second finish bound.
- **Privacy and offline:** fully in process; no network after the weights are
  downloaded and verified.
- **Fit:** reuses the identifiers, pins and integration knowledge of the
  Windows and Linux whisper.cpp route. It builds from source with CMake, so no
  binary artefact has to come from outside the approved Maven feed.

### sherpa-onnx

- **Licence:** Apache-2.0 ([sherpa-onnx][sherpa-onnx]); latest v2.0.1 (26
  October 2026). Model licences vary: Parakeet TDT 0.6B v3 is CC-BY-4.0
  (NVIDIA), Whisper is MIT.
- **Size:** the shared Parakeet v3 int8 entry downloads ~465 MB, unpacks to
  ~670 MB and needs just under 2 GB of RAM while decoding
  (`Sources/SpeakCore/LocalModels/ParakeetLocalModels.swift`). Small streaming
  Zipformer and Moonshine models exist for English.
- **Device support:** Android arm64, armeabi-v7a and x86_64, with prebuilt AARs
  on GitHub releases and an optional Qualcomm NPU (QNN) path
  ([sherpa-onnx Android][sherpa-android]).
- **Latency:** supports true streaming recognition with partials, which
  whisper.cpp does not. No primary phone benchmarks for Parakeet v3.
- **Privacy and offline:** fully local ([sherpa-onnx Android][sherpa-android]).
- **Why deferred:** the AARs are GitHub release assets, not on the Maven feed,
  so they would need building from source or vendoring; and the 2 GB RAM need
  excludes many mid-range phones. Revisit for a live local route after #1658.

### llama.cpp

- **Licence:** MIT ([llama.cpp][llama-cpp]). Shared cleanup models: SmolLM2
  360M (Apache-2.0, ~230 MB), Qwen3 0.6B (Apache-2.0, ~450 MB) and Qwen3 1.7B
  (Apache-2.0, ~1.1 GB), all Q4 GGUF (`ModelCatalog.localPostProcessing`).
- **Device support:** the official Android binding picks CPU kernels at runtime
  (up to Arm SME2) so it runs on both old and new phones
  ([llama.cpp Android][llama-android]).
- **Latency:** no primary phone numbers for our models; #1660 measures them.
- **Privacy and offline:** fully in process.
- **Fit:** the same GGUF identifiers, SYSTEM/USER prompt split and failure rules
  as [desktop-local-llm-cleanup.md](desktop-local-llm-cleanup.md); covers every
  phone without Gemini Nano.

### LiteRT-LM (successor to MediaPipe LLM Inference)

Apache-2.0 runtime with a Kotlin API on Google Maven and GPU/NPU acceleration;
the MediaPipe LLM Inference page now redirects to it ([LiteRT-LM][litert-lm],
[LiteRT-LM Android][litert-android]). It loads `.litertlm` models, mostly Gemma
(Gemma Terms of Use, gated on Hugging Face). Adopting it would add a second
artefact format and model list beside the shared GGUF catalogue, so it is not
recommended unless llama.cpp proves too slow on phones.

## Downloaded Whisper on Android

Built in #1658 (code); the owner's device measurements (real-time factor,
time-to-text, battery, the default model and the Turbo memory floor) are still
open on that issue and listed in `Docs/manual-checks.yml`.

### Native build

- `android/app/src/main/cpp/` builds one shared library,
  `libjsti_local_models.so`, holding a thin JNI bridge (`whisper_jni.cpp`,
  called from `local/WhisperCppTranscriber.kt`) with whisper.cpp and ggml linked
  statically. No prebuilt binaries are used.
- **Source pin:** whisper.cpp v1.9.5 (commit
  `d2a764c648779feb36d44363f212a29b00aad1af`). `cmake/whisper.cmake` fetches the
  release archive with `FetchContent` and `URL_HASH SHA256=ff1a9053…dc1720`; a
  mismatch fails the configure. The archive is downloaded once per build
  directory into `build/native-sources` and shared by every ABI. Offline
  builds pass a local copy of the same archive with
  `-Pjsti.whisperCppArchive=/path/whisper.cpp-v1.9.5.tar.gz`; its hash is checked
  the same way. To upgrade, change the version, commit comment and SHA-256
  together and re-run the device checks.
- **Shared ggml:** `cmake/ggml.cmake` adds the `ggml` target once (CPU backend
  only, no OpenMP, Vulkan or llamafile). llama.cpp (#1660) links that same
  target, so both runtimes ship one ggml (see
  [Downloaded cleanup on Android](#downloaded-cleanup-on-android)). It builds
  the ggml bundled with the pinned whisper.cpp unless `JSTI_GGML_SOURCE_DIR`
  names a ggml both runtimes are pinned against.
- **ABIs:** arm64-v8a (phones), x86_64 (emulator, Chromebooks) and
  armeabi-v7a (so 32-bit-only phones can still install the app now that it ships
  native code; it is too slow for anything above Tiny). The runtimes are always
  built with `-O3`, debug builds included, because unoptimised inference is
  unusable. The library is linked for 16 KB pages.
- **Toolchain:** `ndkVersion` 27.3.13750724 (r27d) and CMake 3.31.5, both
  preinstalled on GitHub's `ubuntu-24.04` runners, so `scripts/ci-android.sh`
  and the Android job need no extra install step. A machine without them needs
  the SDK Manager's `ndk;27.3.13750724` and `cmake;3.31.5` packages.
- **Unit tests** never load the library: Downloaded mode talks to the
  `LocalTranscriber` interface, and JVM tests use a fake.

### Models and downloads

- `assets/whisper_models.json` is generated from SpeakCore's
  `WhisperCppModels` pins by `WhisperCppAndroidExport`
  (`scripts/update-android-assets`); `WhisperCppAndroidExportTests` fails when
  the asset drifts. It carries each model's `local/whisperkit/*` ID, URL, bytes,
  SHA-256, licence, allowed download hosts and Android memory floor.
- Tiny, Base and Small are offered on every phone. Large v3 Turbo (q5_0) is
  offered only when `ActivityManager.MemoryInfo.totalMem` is at least 5 GiB
  (`WhisperCppAndroidExport.largeModelMinimumDeviceMemoryBytes`), an unmeasured
  starting point the device checks must confirm. A model already downloaded stays
  listed so it can be removed.
- Settings › Downloaded models shows each model's size and state (not
  downloaded, downloading with progress, paused, waiting for Wi-Fi, failed,
  downloaded) with Download, Resume, Cancel and Remove. Downloads wait for an
  unmetered network unless "Download on mobile data" is on.
- `ModelDownloader` resumes a partial file with an HTTP range request, restarts
  when the server ignores the range, follows at most five redirects, each of
  which must be HTTPS to an allowed host, and installs the file only after its
  size and SHA-256 match the pin. A mismatch deletes it. Downloads run while the
  app is open (no foreground service); a stopped one resumes from its partial
  file. Models live in the app's private files (`files/models/whisper`); the
  app opts out of backup and device transfer, and configuration transfer carries
  only the chosen model's ID, so another device downloads its own copy.

### Transcription

- Downloaded is its own mode beside Speech service, On device and Cloud, chosen
  only by the user. It records the same 16 kHz mono 16-bit WAV as Cloud mode,
  then whisper.cpp transcribes it after Stop (batch only, no partials). The
  language follows the dictation language (Automatic uses the phone's).
- A missing, partially downloaded or corrupt model, or a whisper.cpp failure,
  is a visible error; the recording is kept in History for a retry. Nothing
  falls back to Cloud or the platform recogniser, and a Downloaded History
  entry is retried only with a downloaded model.
- Hands-free and shared audio files stay on Cloud for now.
- **Keyboard:** the dictation keyboard never offers Downloaded models
  (`KeyboardPolicy.APP_ONLY_MODES`). There are no device measurements yet, the
  keyboard must finish within its 10-second bound while the user waits in
  another app, and an IME process has a tighter memory budget than the app.
  Revisit once the measurements exist.

## Downloaded cleanup on Android

Built in #1660 (code); the owner's device measurements (time to clean a
transcript per model, peak memory, battery and the Qwen3 1.7B memory floor) are
still open on that issue and listed in `Docs/manual-checks.yml`.

### Native build

- llama.cpp is compiled from source into the same `libjsti_local_models.so`
  (`llama_jni.cpp`, called from `local/LlamaCppCleaner.kt`). No prebuilt
  binaries are used.
- **Source pin:** llama.cpp tag `b11425` (commit
  `e117148a41d8e9bedb72e4c6c3f003ab0fe7f857`). `cmake/llama.cmake` fetches the
  tag archive with `URL_HASH SHA256=3bf5a64c…c83c92a` through the same
  `cmake/native-sources.cmake` helper as whisper.cpp; a mismatch fails the
  configure. Offline builds pass
  `-Pjsti.llamaCppArchive=/path/llama.cpp-b11425.tar.gz`.
- **Why b11425:** llama.cpp and whisper.cpp each vendor a copy of ggml.
  whisper.cpp v1.9.5 synced ggml at the point recorded as llama.cpp
  `e117148a` (`scripts/sync-llama.last`), so b11425's ggml is source-identical
  to the one the shared target builds (only the version line in
  `ggml/CMakeLists.txt` differs). llama.cpp therefore compiles against and
  links the one shared `ggml` target and never builds its own. The configure
  compares the SHA-256 of every public ggml header in both archives and fails
  if a later bump of either pin lets them drift; upgrade the two pins
  together.
- Only the `llama` library is built (no common, tools, server, examples or
  tests). A host build of both runtimes linked with no duplicate ggml symbols.

### Models and downloads

- `assets/cleanup_models.json` is generated from SpeakCore's `LlamaCppModels`
  pins by `LlamaCppAndroidExport` (`scripts/update-android-assets`);
  `LlamaCppAndroidExportTests` fails when the asset drifts or when the pins and
  `ModelCatalog.localPostProcessing` disagree. It carries each model's
  `local/post-processing/*` ID, display name, URL (a Hugging Face revision, not
  `main`), bytes, SHA-256, licence, allowed hosts and Android memory floor.
- SmolLM2 360M Q4 and Qwen3 0.6B Q4 are offered on every phone. Qwen3 1.7B Q4
  needs 5 GiB of `totalMem`, an unmeasured starting point the device checks
  must confirm.
- Settings › Clean up transcripts › Downloaded cleanup models lists each model
  with its size and state and Download, Resume, Cancel and Remove, through the
  same `ModelDownloader` (Wi-Fi by default, resumable, SHA-256 verified) as the
  Whisper models. Weights live in `files/models/llm`.
- Before every load, `PinnedWeightsVerifier` checks the file's size and SHA-256
  against the pin again (cached per path, size and modification time for the
  process), so a file changed after download is never loaded.

### Cleanup

- Choosing a downloaded model (in Downloaded cleanup models, or under
  **On this phone** in the Settings cleanup picker, beside Gemini Nano) replaces
  the picked cleanup model, cloud or Gemini Nano, and the Cleanup model row
  names it; choosing any other model in the picker clears it. The prompt editor
  stays visible. A profile's own cleanup model (cloud or Gemini Nano) still
  wins for its sessions. Configuration transfer uses
  the shared `postProcessingModel` key, so a desktop's `local/post-processing/*`
  choice imports when Android offers that model.
- The cleanup prompt (`CleanupPolicy.systemPrompt`, honouring
  `postProcessingSystemPrompt`) is the SYSTEM message and the JSON-wrapped
  transcript is the USER message, formatted with the model's own chat template
  (Qwen3 gets its documented non-thinking prefill). Decoding is greedy.
- Bounds: a 4,096-token context, at most 2,048 output tokens, at most four
  threads, two minutes per transcript (`DictationTimings.localCleanupMs`) from
  before the model loads, and cancellation or the deadline aborts loading as
  well as decoding. One model is loaded at a time and freed after each
  transcript.
- An empty transcript stays empty and never loads the model. A runtime that
  did not load, a missing or unverified model, a load or decode failure, a
  timeout, an empty reply or a reply that thinks aloud keeps the original
  transcript with a visible notice;
  nothing falls back to the cloud or rules cleanup. A selected model that is not
  downloaded turns cleanup off for the session and Settings says so.
- Small models sometimes echo the `{"transcript": ...}` wrapper; Android
  unwraps exactly that shape. The desktop runtimes do not.
- **Keyboard:** the dictation keyboard keeps cloud cleanup for voice edits, for
  the same latency and memory reasons as Downloaded transcription.
- **Unit tests** never load the library: cleanup talks to the `LocalCleaner`
  interface, and JVM tests use a fake.

## Identifier mapping

| Route | Identifier | Notes |
| --- | --- | --- |
| whisper.cpp | `local/whisperkit/tiny`, `base`, `small`, `large-v3-turbo` | Same IDs as desktop; `LocalModelBackend.whisperCppGGML` with the pinned GGML file. Hugging Face Whisper import can use `local/whispercpp/huggingface/...` later. |
| llama.cpp | `local/post-processing/smollm2-360m-instruct-q4`, `qwen3-0.6b-q4`, `qwen3-1.7b-q4` | `LocalModelBackend.llamaCppGGUF`; imports use `local/llamacpp/sha256/...`. |
| Gemini Nano | `android/local/GeminiNano` | OS-provided, not downloaded, so it mirrors `apple/local/FoundationModels` rather than the `local/...` namespace. Added to SpeakCore with an Android-only capability rule. |
| sherpa-onnx (later) | `local/streaming/huggingface/k2-fsa/sherpa-onnx/sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8` | Existing shared streaming entry. |

Android must consume these from SpeakCore exports, as it does
`assets/cloud_catalog.json`, never from a hand-copied list.

## Rules every route keeps

- No silent cloud or platform fallback; an unavailable or failed model is a
  visible error and keeps the original transcript or audio.
- Empty transcripts stay empty without calling a cleanup model.
- Downloads are verified against pinned size and SHA-256 before use and can be
  removed; Wi-Fi by default.
- Routes appear only on devices that can run them.

## Sources

[mlkit-genai]: https://developers.google.com/ml-kit/genai
[android-nano]: https://developer.android.com/ai/gemini-nano
[genai-terms]: https://developers.google.com/ml-kit/genai-terms
[prompt-api]: https://developers.google.com/ml-kit/genai/prompt/android
[prompt-start]: https://developers.google.com/ml-kit/genai/prompt/android/get-started
[proofreading]: https://developers.google.com/ml-kit/genai/proofreading/android
[mlkit-speech]: https://developers.google.com/ml-kit/genai/speech-recognition/android
[whisper-cpp]: https://github.com/ggml-org/whisper.cpp
[whisper-android]: https://github.com/ggml-org/whisper.cpp/tree/master/examples/whisper.android
[sherpa-onnx]: https://github.com/k2-fsa/sherpa-onnx
[sherpa-android]: https://k2-fsa.github.io/sherpa/onnx/android/index.html
[llama-cpp]: https://github.com/ggml-org/llama.cpp
[llama-android]: https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md
[litert-lm]: https://github.com/google-ai-edge/LiteRT-LM
[litert-android]: https://developers.google.com/edge/litert-lm/android

- [ML Kit GenAI overview, device support, quota and background use][mlkit-genai]
- [Gemini Nano and AICore on Android][android-nano]
- [ML Kit GenAI API Additional Terms of Service][genai-terms]
- [ML Kit Prompt API][prompt-api] and [get started][prompt-start]
- [ML Kit Proofreading API][proofreading]
- [ML Kit GenAI Speech Recognition API][mlkit-speech]
- [whisper.cpp][whisper-cpp] and its [Android example][whisper-android]
- [sherpa-onnx][sherpa-onnx] and its [Android guide][sherpa-android]
- [llama.cpp][llama-cpp] and its [Android guide][llama-android]
- [LiteRT-LM][litert-lm] and its [Android guide][litert-android]
