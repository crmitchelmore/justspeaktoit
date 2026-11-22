# sherpa-onnx on-device TTS spike

Spike for [#1820](https://github.com/crmitchelmore/justspeaktoit/issues/1820),
part of [#1819](https://github.com/crmitchelmore/justspeaktoit/issues/1819).
Linux x64 was measured on 18 November 2026. The 22 November 2026 macOS arm64
run measured Kokoro and verified loading the dylibs in process. The official
Pocket TTS checkpoint is gated, so its macOS measurements remain open.

## Scope and owner decisions

- Local TTS is approved (18 Nov 2026).
- Voice creation is desktop only: macOS, Windows and Linux. iOS and Android
  are N/A by owner decision.
- The owner selected Kokoro-82M for built-in voices and Pocket TTS for cloning
  on 18 November. Pocket TTS requires an in-house ONNX export of the official
  Kyutai weights. The Linux Pocket TTS data used the public sherpa export
  before this decision. ZipVoice was dropped. Its Linux results are retained
  here as historical measurements.
- The spike tests whether the sherpa-onnx C API can run those models natively
  and in process within desktop CPU, latency and memory budgets.
- No app code was changed. No WAV or model file is committed.

### What Read Aloud does today

`DesktopSpeechSynthesis` (`Sources/SpeakCore/TTS/Desktop/`) is HTTP only. It
dispatches to a cloud provider and returns a complete WAV as `Data` per
segment. `DesktopHostReadAloud` in `SpeakDesktopHost` cuts text into
segments, stages each WAV and plays it. Linux and Windows share both. Neither
has an on-device voice (`Docs/linux-development.md`), and `Package.swift` has
no sherpa-onnx reference.

The macOS app already runs sherpa-onnx for live transcription, but through a
Python sidecar (`LocalPythonSidecar.swift`, `SherpaOnnxSidecarOutput.swift`).
That is not the in-process route measured here.

A local engine fits the existing shape: one call per segment returning a full
clip. Segment-by-segment generation is also how the long-text runs below were
timed.

## Method

### Linux x64

- Host: Intel Core i7-4870HQ (Haswell, 2013, 2.5 GHz), 4 cores / 8 threads,
  AVX2 and FMA, no AVX-512, 15 GiB RAM, Linux 7.2. This is a slow CPU. Newer
  CPUs should do better, but that is unmeasured.
- Runtime: official `sherpa-onnx-v2.0.1-linux-x64-shared-lib` prebuilt
  libraries (ONNX Runtime 1.28.2), C API only. `c-api.h` is from the `v2.0.1`
  tag.
- Harness: a small C program calling `SherpaOnnxCreateOfflineTts` and
  `SherpaOnnxOfflineTtsGenerateWithConfig`. A second C program does the
  quality checks. No Python on the measurement path. Both live in
  `~/spike-1820` (not committed).
- Threads: 4. Eight threads was slower (Pocket RTF 0.88 against 0.43).
- One run per cell, no repeats, so expect noise of a few percent.
- Peak RSS is `getrusage` `ru_maxrss` for the whole process.
- "Cold load" is a fresh process creating the engine. The page cache was warm
  because the files had just been extracted.
- Texts: a 21-word sentence and a 180-word paragraph (10 sentences; the brief
  said ~200).
- TTFA is time to first audio. For Pocket it is the first streaming callback.
  For Kokoro and ZipVoice the C API returns audio only when a sentence
  finishes, so it is the time to the first finished sentence.
- Models: `kokoro-int8-multi-lang-v1_0`,
  `sherpa-onnx-zipvoice-distill-int8-zh-en-emilia` plus `vocos_24khz.onnx`,
  `sherpa-onnx-pocket-tts-int8-2026-01-26`. All from k2-fsa GitHub release
  assets.
- Reference clip: LibriSpeech dev-clean speaker 2277 (Dreiser, *Sister
  Carrie*), utterances `2277-149896-0000` and `-0001` joined (13.7 s). The
  6.6 s variant is `-0000` alone. LibriSpeech is CC BY 4.0 and its audio is
  LibriVox public domain. Fetched through the Hugging Face datasets server.

### macOS arm64

- Bravo’s Mac mini, Mac16,10, Apple M4 (4 performance and 6 efficiency cores),
  16 GiB physical RAM, macOS 27.2.1 (26B131). Native arm64 process using the
  CPU provider and the
  [sherpa-onnx v2.0.1 arm64 shared library release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1)
  (ONNX Runtime 1.28.2).
- A scratch C harness called `SherpaOnnxCreateOfflineTts` and
  `SherpaOnnxOfflineTtsGenerateWithConfig` at 4 threads, with a 2-thread
  comparison. Each cell used a fresh process and a warm page cache. Engine
  creation was timed separately. Load RSS is current Mach task resident size.
  Process peak RSS is `getrusage(RUSAGE_SELF).ru_maxrss` in bytes on macOS.
  Sizes use decimal MB.
- Used the same Kokoro
  [int8 multi-language v1.0 archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2)
  with preset ID 0, speed 1.0 and silence scale 0.2. Timed one 21-word
  sentence and one 180-word paragraph (10 sentences). The Linux text was
  unavailable, so the Mac used the replacement below. Its per-sentence run
  made ten API calls. Its unsplit run made one call with ten phoneme ranges.
  RTF divides generation time by the returned audio duration.
- The [LibriSpeech dev-clean archive](https://www.openslr.org/12/) supplied
  the same 16 kHz speaker 2277 utterances as the Linux run. Joined
  `2277-149896-0000` (6.590 s) and `-0001` (7.145 s) without added silence
  for a 13.735 s reference. Used `-0002` (4.835 s) as the same-speaker anchor.
- The official [Kyutai Pocket TTS checkpoint](https://huggingface.co/kyutai/pocket-tts)
  returned HTTP 401 for `tts_b6369a24.safetensors`. Access to the gated
  checkpoint and a local int8 ONNX export are required to fill the macOS
  Pocket TTS column.

<details>
<summary>macOS benchmark text (the first sentence is the short input)</summary>

> The passengers checked their tickets while families waited near the ovens
> before the early train finally arrived at the quiet station. A woman at the
> front unfolded the map and traced the route along the river with her finger.
> Two children counted the bridges they would cross and guessed which one would
> offer the best view today. Beyond the houses, clouds drifted over the fields
> and sunlight caught the tops of the trees. An older man lifted his suitcase
> onto the rack and offered the window seat to his granddaughter. The conductor
> walked through the carriage and reminded everyone that the next stop was still
> twenty minutes away. When the train slowed, they saw a small boat tied to a post
> and a dog sleeping nearby. The girl drew the boat in her notebook and left
> enough room to add the dog later. At the platform a friend waved from beneath
> the clock and everyone gathered their bags. They stepped down together and
> followed the path toward town, where the market opened and the morning bells
> rang across the square.

</details>

### Phonemiser finding (affects the numbers below)

sherpa-onnx 2.0.0 removed espeak-ng and piper-phonemize (changelog #4055;
`data_dir` and `lang` are ignored). The v2.0.1 C API library exports no
espeak symbols. Consequences:

- **Kokoro** falls back to its shipped lexicon. Words it lacks are silently
  skipped ("passengers", "families", "ovens" and "arrived" were dropped from
  the test text). Full coverage needs pre-phonemised input
  (`phoneme_codepoints`).
- **ZipVoice** with lexicon only failed: "Failed to convert ... to token IDs",
  then 275 s of garbage audio and 3.4 GB peak RSS. English needs
  pre-phonemised tokens (`GenerationConfig.tokens`; `phoneme_codepoints` is
  ignored).
- **Pocket TTS** has a SentencePiece vocabulary and needs no phonemiser.

For the Kokoro and ZipVoice rows the harness phonemised with the `espeak-ng`
command line (`--ipa`) before the timers started, so that time is excluded.
On macOS the libraries also had no espeak-ng exports. The US English
lexicon skipped ten words in the Mac paragraph, including the four above. The harness ran espeak-ng
1.52.0 with `-q -v en-us --ipa` beforehand, restored final punctuation and
passed Unicode codepoints through the C API. The timings exclude that
process. The app needs a permissively licensed phonemiser for Kokoro.

## Measurements

| Measure | Linux Kokoro | Linux ZipVoice, 13.7 s ref | Linux ZipVoice, 6.6 s ref | Linux Pocket TTS, 13.7 s ref | macOS arm64 Kokoro | macOS arm64 Pocket TTS |
| --- | --- | --- | --- | --- | --- | --- |
| Download (tar.bz2) | 132 MB | 109 MB + 54 MB vocoder | same | 98 MB | 132.4 MB | Pending |
| Runtime files on disk | 157 MB | 186 MB | same | 198 MB | 157.3 MB runtime assets (189.9 MB full archive contents) | Pending |
| Cold load | 1.8 s | 1.6 s | 1.6 s | 0.7 s | 0.46–0.53 s | Pending |
| RSS after load | 346 MB | ~320 MB | ~320 MB | 328 MB | 416–417 MB | Pending |
| Peak RSS | 557 MB | 1,245 MB | 750 MB | 604 MB | 585 MB | Pending |
| TTFA, 21 words | 7.7 s | 8.3 s | 4.7 s | 2.3 s (streamed) | 3.57 s | Pending |
| TTFA, first sentence of 180 words | 5.5 s | 12.0 s | 5.6 s | 1.4 s (streamed) | 3.24 s | Pending |
| RTF, 21 words | 1.11 | 1.12 | 0.65 | 0.41 | 0.493 | Pending |
| RTF, 180 words (per sentence) | 1.23 | 2.54 | 1.27 | 0.43 | 0.491 | Pending |
| Streams inside a sentence | No | No | No | Yes (47 callbacks) | No (one callback per sentence) | Pending |
| Output rate | 24 kHz | 24 kHz | 24 kHz | 24 kHz | 24 kHz | Pending |

RTF is generation time over audio time; below 1.0 is faster than real time.
On the Linux host only Pocket TTS beat real time. Linux notes:

- ZipVoice cost grows with reference length because the reference is
  processed on every call. Halving it roughly halved RTF and cut peak RSS 40%.
- Pocket TTS's first call includes encoding the reference voice. Later calls
  with a cached voice were not measured.
- Unsplit generation of the long text gave similar RTF: Kokoro 1.18, ZipVoice
  2.57, Pocket 0.43.
- Kokoro with lexicon only (words dropped) ran at RTF 1.28.

At 4 threads on macOS, Kokoro produced 7.24 s of short audio and 52.22 s
for the split paragraph. The unsplit call took 29.02 s for 52.21 s of audio
(RTF 0.556), with 3.41 s to the first sentence and ten sentence callbacks.
The 2-thread run gave RTF 0.493, 0.570 and 0.563 for the short, split and
unsplit inputs, respectively. The runtime-size row counts the model, voices, tokens, lexicons
and text-normalization FSTs. The model archive also includes legacy
phonemiser and dictionary data.

### Platform columns

| Platform | Status | Who and where |
| --- | --- | --- |
| Linux x64 | Done (this report) | Spike host above |
| macOS arm64 | Kokoro and SwiftPM integration done. Pocket TTS pending. | Bravo’s Mac mini. Official checkpoint access required. |
| macOS x64 | pending | An Intel macOS runner. None arranged. |
| Windows x64 | pending | A Windows x64 host or runner. None was available to this spike. |

Use the corresponding `osx-x64` or `win-x64-shared-MD-Release` `-lib`
assets on the remaining hosts and measure the two selected models.

## Clone quality

### Linux x64

I could not listen to audio, and no panel was run. There is no by-ear
judgement of naturalness or artefacts. Two objective proxies were used
instead; they do not replace listening.

- Intelligibility: word error rate against the input text, from sherpa's
  Whisper tiny.en, cutting audio at silences. Tiny.en errs on its own, so
  read these as relative.
- Speaker similarity: cosine between `wespeaker_en_voxceleb_resnet34`
  embeddings of output and reference. Anchors: the same speaker's other real
  utterance scored 0.92; Pocket's bundled `bria.wav` (a different speaker)
  scored 0.60; Kokoro presets (a different speaker) scored 0.44 to 0.49.

| Model | Reference | WER, 21 words | WER, 180 words | Cosine to reference (short / long) |
| --- | --- | --- | --- | --- |
| Kokoro preset | none | 0.00 | 0.04 | 0.44 to 0.49 |
| ZipVoice | 13.7 s | 0.00 | 0.04 | 0.85 / 0.87 |
| ZipVoice | 6.6 s | 0.00 | 0.06 | 0.85 |
| Pocket TTS | 13.7 s | 0.00 | 0.09 | 0.74 / 0.81 |

Reading: both cloning models are intelligible. ZipVoice's embeddings sit
nearer the reference, so it probably sounds more like the speaker; Pocket TTS
sits between a different real speaker and the same-speaker anchor. A 6.6 s
reference worked about as well as 13.7 s for ZipVoice.

Limits: the reference is a read audiobook. History-style dictation is still untested. The
5 s and 30 s references were not tried. The generated WAVs are in
`~/spike-1820/bench/out/` (not committed) for the owner to listen to.

### macOS arm64

The sherpa C API extracted 256-dimensional
[`wespeaker_en_voxceleb_resnet34` embeddings](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models).
The same-speaker anchor scored 0.917. Kokoro’s built-in voice scored 0.403
(short), 0.458 (split paragraph) and 0.469 (unsplit paragraph) against the
reference. These are different-speaker baselines. No macOS WER or listening
results were collected.

## Language coverage

| Model | Languages |
| --- | --- |
| Kokoro multi-lang v1.0 | The package ships English (US and GB) and Mandarin lexicons and 54 voices. The upstream model also covers Spanish, French, Hindi, Italian, Japanese and Brazilian Portuguese (from the upstream card, untested here). In 2.0.x those need an external phonemiser. |
| ZipVoice | Chinese and English (Emilia). |
| Pocket TTS | English tested. Kyutai's README now lists English, French, German, Portuguese, Italian, Spanish and Dutch as separate weights; which the sherpa export supports was not checked. Treat as English only. |

## Licences

Terms as published.

| Component | Licence | Notes |
| --- | --- | --- |
| sherpa-onnx code and libraries | Apache-2.0 | 2.0.0 removed espeak-ng and piper-phonemize. |
| ONNX Runtime 1.28.2 (bundled) | MIT upstream | Attribution notice needed. |
| espeak-ng (the spike's phonemiser) | GPL-3.0 upstream | Not in the prebuilt libs. Likely unsuitable to link into the app. |
| Kokoro-82M weights | Apache-2.0 (model card) | Not gated. |
| ZipVoice code | Apache-2.0 | The `k2-fsa/ZipVoice` Hugging Face repo declares no licence and the sherpa package has no licence file. Confirm weight terms with k2-fsa. Its training set Emilia is CC-BY-4.0 (gated) on its card. |
| Pocket TTS code | MIT | `kyutai-labs/pocket-tts`. |
| Pocket TTS weights | CC-BY-4.0, gated | `kyutai/pocket-tts` needs a Hugging Face login and accepted terms. CC-BY-4.0 requires attribution: credit, licence link, note of changes. |
| Pocket TTS sherpa package | CC-BY-4.0 `LICENSE`; README says "It is for non-commercial" | Built from the third-party export `KevinAHM/pocket-tts-onnx` (card CC-BY-4.0, not gated); downloaded here with no login. The README line contradicts the CC-BY-4.0 text. Historical Linux benchmark artifact. The owner chose an in-house export for shipping. |
| LibriSpeech reference clip | CC BY 4.0 (audio public domain) | Spike only. |

For distribution, include the sherpa-onnx Apache-2.0 notices, the ONNX Runtime
MIT and bundled third-party notices, and the Kokoro-82M Apache-2.0 notices.
Credit Kyutai for Pocket TTS, link [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
identify our ONNX conversion and quantization, and honour the checkpoint’s
accepted use terms before hosting a download. Pocket TTS preset voices have
[separate licences](https://huggingface.co/kyutai/tts-voices).

## Build integration notes (Linux)

- Size: `libsherpa-onnx-c-api.so` 4.9 MB, `libsherpa-onnx-cxx-api.so` 0.27 MB,
  `libonnxruntime.so` 27 MB, about 31 MB. Dependencies are glibc (symbols up
  to GLIBC 2.17), libstdc++ (GLIBCXX 3.4.19), libm, libdl, libpthread and
  libgcc_s. The library has `RPATH=$ORIGIN`.
- ONNX Runtime 1.28.2 ships as a shared library beside the C API; no system
  onnxruntime or Python wheel is needed.
- Headers: the `-lib` tarballs hold only `lib/`. `c-api.h` is in the full
  `-shared` tarball and the source tree.
- SwiftPM works. A scratch package with a `.systemLibrary` target
  (`module.modulemap`: `module CSherpaOnnx [system] { header
  "sherpa-onnx/c-api/c-api.h" link "sherpa-onnx-c-api" export * }`) plus
  `linkerSettings: [.unsafeFlags(["-L", libDir, "-Xlinker", "-rpath",
  "-Xlinker", "$ORIGIN/../lib"])]` built with Swift 6.4.2 and ran from a
  `bin/` + `lib/` layout with no `LD_LIBRARY_PATH`, printing "sherpa-onnx
  2.0.1".
  - `unsafeFlags` is allowed only in root packages, so a dependency target
    needs the app build to supply the flags.
  - SwiftPM binary targets on Linux take artifact bundles, not plain shared
    libraries (from knowledge, not tested here). A system-library target
    with a pinned, fetched tarball is the realistic route.
  - Packaging (`Docs/linux-packaging.md`, Flatpak) must place the `.so`
    files in one lib directory and keep the RPATH relative.
- Models would be downloaded at runtime. The audio path stays in process,
  with no IPC or Python.
- Streaming: Pocket TTS streams through the generation callback. Kokoro and
  ZipVoice yield per sentence, which matches segment-by-segment Read Aloud.

## Build integration notes (macOS arm64)

- The 8.73 MB release archive contains 33.09 MB of native arm64 libraries.
  The C path needs 32.91 MB across `libsherpa-onnx-c-api.dylib` (4.13 MB) and
  `libonnxruntime.dylib` (28.78 MB). Both declare macOS 11.0 as their Mach-O
  minimum. Runtime execution was tested on macOS 27.2.1.
- A C probe linked with `@executable_path/../lib` ran after moving the
  `bin/` and `lib/` tree, with no DYLD library-path override. Both dylibs
  resolved from the moved tree. The C API uses `@rpath` for ONNX Runtime and
  carries its own `@loader_path` rpath to resolve the sibling library.
- With Apple Swift 6.2.3 and Xcode 26.2, a SwiftPM executable built using a
  `.systemLibrary` target with the C header and module map. A second executable
  built against two local `.binaryTarget` entries created with
  `xcodebuild -create-xcframework`. The two arm64 XCFrameworks total 33.08 MB,
  including the C header, module map and metadata. Both executables printed
  `sherpa-onnx 2.0.1` from the relocated layout. dyld confirmed they loaded
  both libraries from the sibling directory.
- Release dylibs are ad hoc signed. App bundle signing, hardened-runtime
  load and notarisation still need a release build check.

## Build integration notes (Windows and Intel macOS)

- Windows: release v2.0.1 has `win-x64-shared-{MD,MT}-{Release,MinSizeRel,Debug,RelWithDebInfo}[-lib]`
  and static variants. The MD Release `-lib` tarball (7.3 MB) holds
  `sherpa-onnx-c-api.dll` (3.9 MB), `onnxruntime.dll` (17 MB) and import
  `.lib` files. It is the same C API and header. Not built or run. Windows
  arm64 was not checked.
- Intel macOS: v2.0.1 provides `osx-x64` and `osx-universal2` shared
  `-lib` tarballs. Neither was run.

## Recommendations

| Platform | Recommendation | Reason |
| --- | --- | --- |
| Linux x64 | **Ship later** | Pocket TTS streamed at RTF 0.43 with the historical export. Confirm performance and clone quality with the official weights. Kokoro needs a shippable phonemiser and ran slower than real time on this host. |
| macOS arm64 | **Ship later** | Kokoro ran at RTF 0.491 on the split paragraph, with 3.24 s to its first sentence. Qualify the official Pocket TTS export, choose a permissive English phonemiser, and verify signing and notarisation. |
| macOS x64 | **Ship later** (provisional) | Native libraries are available. Host measurements are pending. |
| Windows x64 | **Ship later** (provisional) | DLL assets and import libraries exist. Host measurements are pending. |
| iOS, Android | **N/A** | Owner decision: voice creation is desktop only. |

Next steps:

1. Obtain approved access to Kyutai’s checkpoint, produce the in-house int8
   ONNX export, and measure Pocket TTS on macOS arm64 using the same reference.
2. Measure both selected models on Intel macOS and Windows x64. Repeat Pocket
   TTS on Linux with the in-house export so the platforms use identical weights.
3. Listen to clones of consented History-style references at several lengths,
   choose the Kokoro phonemiser, and verify the signed macOS bundle.
