# transcribe.cpp assessment

Issue [#548](https://github.com/crmitchelmore/justspeaktoit/issues/548) asks whether the downloaded-local
WhisperKit batch path should be replaced by
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). This change adds a reproducible comparison
tool; it does **not** change the shipping app runtime, default, model catalogue, saved model identifiers, or imported
WhisperKit models.

## Current integration finding

The assessment pins transcribe.cpp `v0.1.3` (tag commit
`a94e021ef658dc7c788837341a13f6acea3baf3c`) through its published Apple XCFramework. The SwiftPM checksum is
`b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd`; reproduce it with:

```sh
curl -L --fail \
  -o /tmp/TranscribeCpp.xcframework.zip \
  https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/TranscribeCpp.xcframework.zip
swift package compute-checksum /tmp/TranscribeCpp.xcframework.zip
```

The release has macOS arm64/x86_64, iOS device, and iOS Simulator slices. Its official Swift README still marks the
wrapper as `0.0.1` and in development, and says the standalone Swift package mirror is not published. Therefore this
assessment consumes only the release's raw `CTranscribe` module in the benchmark executable. `SpeakApp` does not
depend on `CTranscribe`, so the binary is not linked or bundled into either shipping macOS distribution.

The current production baseline remains WhisperKit via `argmax-oss-swift` `0.18.0` at
`e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef` from `Package.resolved`.

## Initial smoke evidence (not a replacement decision)

On 2026-07-26, the tool ran the upstream 11-second JFK sample on an Apple M4 (`Mac16,10`, macOS 26.5.2). Both
engines produced the human reference exactly (0 WER/CER over three measured iterations):

| Engine and model | Median warm time | Real-time factor | Peak process RSS |
| --- | ---: | ---: | ---: |
| WhisperKit 0.18.0, Whisper Tiny | 97 ms | 0.0088 | 169 MB |
| transcribe.cpp 0.1.3, Whisper Tiny Q8_0 | 117 ms | 0.0106 | 143 MB |

The candidate was about 20% slower and used about 15% less peak RSS in this smoke run, so it did not meet the 20%
performance gate. Cold-load values were excluded because one process downloaded a model and Metal pipeline caches
were already warm for another. This single clean English sample lacks the required corpus, reliability, and
distribution evidence; its correct outcome is `insufficient-evidence`, not adoption or rejection.

The candidate model was pinned to Hugging Face revision `6687f30c99641ee265df421e582354adbc8848fc`, had byte size
`45981088`, and SHA-256 `325b9c7997cd1eff81ef709d55766565e71be696130cc3a3d444713798706834`.

## Corpus

Copy `Benchmarks/LocalTranscription/corpus.example.json`, then add consented, human-verified 16 kHz mono 16-bit PCM
WAV files. Do not commit private user recordings. Both engines receive the same decoded audio. The decision gate
requires coverage tagged `accent`, `long`, `multilingual`, `noise`, and `silence`; add short clean dictation as a
sanity case. Run on the same idle Mac, power source, macOS version, and build configuration.

Compare an equivalent Whisper checkpoint first. WhisperKit Large v3 Turbo and transcribe.cpp's
Whisper Large v3 Turbo Q8_0 isolate runtime differences better than comparing unrelated model families. Evaluate
Parakeet or streaming models only in separately labelled reports.

## Run

Build the benchmark tool without building or launching the app:

```sh
swift build --product local-transcription-benchmark
```

Create the WhisperKit baseline:

```sh
swift run local-transcription-benchmark run \
  --engine whisperkit \
  --model openai_whisper-large-v3-v20240930_turbo_632MB \
  --repo argmaxinc/whisperkit-coreml \
  --model-source e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef \
  --manifest /path/to/corpus.json \
  --warmups 1 \
  --iterations 3 \
  --output /path/to/whisperkit.json
```

Create the transcribe.cpp candidate report with a checksum-verified GGUF pinned to a Hugging Face revision:

```sh
swift run local-transcription-benchmark run \
  --engine transcribe.cpp \
  --model /path/to/whisper-large-v3-turbo-Q8_0.gguf \
  --model-source https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/PINNED_REVISION/whisper-large-v3-turbo-Q8_0.gguf \
  --backend metal \
  --manifest /path/to/corpus.json \
  --warmups 1 \
  --iterations 3 \
  --output /path/to/transcribe-cpp.json
```

Each report records host details, cold load, per-run transcript, WER, CER, wall time, real-time factor, user/system
CPU time, peak process RSS, failures, runtime version, and source metadata. Peak RSS is the process high-water mark;
run each engine in a fresh process. Use Instruments Energy Log for energy comparison because a command-line process
cannot collect reliable system energy data without privileged tooling.

## Decision gate

Copy `Benchmarks/LocalTranscription/evidence.example.json` and fill it from observed evidence. A model artifact entry
is complete only when it has a pinned URL, 64-character SHA-256, byte size, and license. Then run:

```sh
swift run local-transcription-benchmark compare \
  --baseline /path/to/whisperkit.json \
  --candidate /path/to/transcribe-cpp.json \
  --evidence /path/to/evidence.json \
  --output /path/to/decision.json
```

The automated result is `proceed`, `reject`, or `insufficient-evidence`. Proceed requires all of the following:

- no more than 5% relative WER regression;
- at least 20% lower median warm latency or peak RSS, or a documented capability/compatibility gain;
- identical baseline/candidate cases, required corpus coverage, and zero run failures;
- explicit successful cancellation, long-recording, and silence checks;
- successful direct and `TUIST_APP_STORE=1` macOS builds;
- complete provenance for every proposed GGUF.

Do not add a transcribe.cpp model to `ModelCatalog`, migrate saved selections, or remove WhisperKit based on a smoke
test. If the full gate passes, follow with a separate opt-in production-adapter PR and retain the WhisperKit adapter
through at least one observed release.

## Build and linkage evidence for this assessment PR

- `swift test --filter LocalTranscriptionBenchmarkTests`: 9 tests passed.
- The selected test build also compiled the typed `SpeakCore` routing and catalogue test target.
- `swift build --product SpeakApp -Xswiftc -DAPP_STORE`: passed, exercising the App Store compilation guards.
- Direct `tuist generate --no-open`: passed. Its Xcode target graph listed SpeakCore, SpeakSync, SpeakHotKeys,
  WhisperKit, Sentry, and Sparkle for `SpeakApp`, with no `CTranscribe` dependency.
- `TUIST_APP_STORE=1 tuist generate --no-open`: passed. The generated target used bundle identifier
  `com.justspeaktoit.mac.appstore`, product `JustSpeakToItAppStore`, the `APP_STORE` condition, and the sandbox audio
  input entitlement. Its frameworks contained WhisperKit and Sentry, but neither Sparkle nor CTranscribe.

A full direct Xcode build was stopped during package resolution when free disk reached the 5 GiB safety threshold;
the agent-created DerivedData was removed. The already completed SwiftPM direct build and App Store guarded build
provide compilation evidence, while the two generated Tuist graphs provide distribution/linkage evidence. No claim
is made that an archived, signed, or notarised build was produced.
