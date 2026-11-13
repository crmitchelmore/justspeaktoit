# Android on-device transcription and cleanup models

Decision record for #1593, which feeds the Android half of #1650. Assessed on
13 November 2026 against the primary sources linked below; re-check the device
lists and API stages before implementing, as both change often.

Today Android's private route is the platform recogniser
(`SpeechRecognizer.createOnDeviceSpeechRecognizer`, Android 12+) and cleanup is
cloud-only (see [android-parity-matrix.md](android-parity-matrix.md)). The Mac,
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
  tokens, temperature, `topK`, `seed` and `maxOutputTokens`; no separate system
  role is documented, so the instruction and transcript travel together in the
  request ([Prompt API][prompt-api], [get started][prompt-start]).
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
  not run cleanup today, so nothing is lost.

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

## Identifier mapping

| Route | Identifier | Notes |
| --- | --- | --- |
| whisper.cpp | `local/whisperkit/tiny`, `base`, `small`, `large-v3-turbo` | Same IDs as desktop; `LocalModelBackend.whisperCppGGML` with the pinned GGML file. Hugging Face Whisper import can use `local/whispercpp/huggingface/...` later. |
| llama.cpp | `local/post-processing/smollm2-360m-instruct-q4`, `qwen3-0.6b-q4`, `qwen3-1.7b-q4` | `LocalModelBackend.llamaCppGGUF`; imports use `local/llamacpp/sha256/...`. |
| Gemini Nano | proposed `android/local/GeminiNano` | OS-provided, not downloaded, so it mirrors `apple/local/FoundationModels` rather than the `local/...` namespace. Added to SpeakCore with an Android-only capability rule. |
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
