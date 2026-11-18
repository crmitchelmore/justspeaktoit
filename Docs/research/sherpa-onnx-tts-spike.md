# sherpa-onnx on-device TTS spike: Linux x64 results

Spike for #1820, part of #1819. Run on 18 November 2026. This report covers
Linux x64 only. The macOS and Windows columns are pending.

`Docs/` had no `research/` folder; this file creates it.

## Scope and owner decisions

- Local TTS is approved (18 Nov 2026).
- Voice creation is desktop only: macOS, Windows and Linux. iOS and Android
  are N/A by owner decision.
- Pocket TTS against ZipVoice-only is still an open licence question. This
  report measures both and states the terms as written.
- Question: can the sherpa-onnx C API run Kokoro presets and ZipVoice or
  Pocket TTS clones natively and in process, without Python, within sensible
  resource limits?
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
espeak-ng is GPL-3.0 upstream. A shipped app needs its own English phonemiser
decision. This favours Pocket TTS.

## Measurements

| Measure | Kokoro int8 multi-lang v1.0 | ZipVoice distill int8, 13.7 s ref | ZipVoice, 6.6 s ref | Pocket TTS int8, 13.7 s ref |
| --- | --- | --- | --- | --- |
| Download (tar.bz2) | 132 MB | 109 MB + 54 MB vocoder | same | 98 MB |
| Runtime files on disk | 157 MB | 186 MB | same | 198 MB |
| Cold load | 1.8 s | 1.6 s | 1.6 s | 0.7 s |
| RSS after load | 346 MB | ~320 MB | ~320 MB | 328 MB |
| Peak RSS | 557 MB | 1,245 MB | 750 MB | 604 MB |
| TTFA, 21 words | 7.7 s | 8.3 s | 4.7 s | 2.3 s (streamed) |
| TTFA, first sentence of 180 words | 5.5 s | 12.0 s | 5.6 s | 1.4 s (streamed) |
| RTF, 21 words | 1.11 | 1.12 | 0.65 | 0.41 |
| RTF, 180 words (per sentence) | 1.23 | 2.54 | 1.27 | 0.43 |
| Streams inside a sentence | No | No | No | Yes (47 callbacks) |
| Output rate | 24 kHz | 24 kHz | 24 kHz | 24 kHz |

RTF is generation time over audio time; below 1.0 is faster than real time.
On this CPU only Pocket TTS beats real time. Notes:

- ZipVoice cost grows with reference length because the reference is
  processed on every call. Halving it roughly halved RTF and cut peak RSS 40%.
- Pocket TTS's first call includes encoding the reference voice. Later calls
  with a cached voice were not measured.
- Unsplit generation of the long text gave similar RTF: Kokoro 1.18, ZipVoice
  2.57, Pocket 0.43.
- Kokoro with lexicon only (words dropped) ran at RTF 1.28.

### Platform columns

| Platform | Status | Who and where |
| --- | --- | --- |
| Linux x64 | Done (this report) | Spike host above |
| macOS arm64 | pending | Hosted Apple Silicon runner; the issue says not the owner's Mac. No owner assigned. |
| macOS x64 | pending | An Intel macOS runner. None arranged. |
| Windows x64 | pending | A Windows x64 host or runner. None was available to this spike. |

Run the same harness with the `osx-*` or `win-x64-shared-MD-Release` `-lib`
assets and fill each cell above.

## Clone quality

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

Limits: the reference is a read audiobook, not History-style dictation. The
5 s and 30 s references were not tried. The generated WAVs are in
`~/spike-1820/bench/out/` (not committed) for the owner to listen to.

## Language coverage

| Model | Languages |
| --- | --- |
| Kokoro multi-lang v1.0 | The package ships English (US and GB) and Mandarin lexicons and 54 voices. The upstream model also covers Spanish, French, Hindi, Italian, Japanese and Brazilian Portuguese (from the upstream card, untested here). In 2.0.x those need an external phonemiser. |
| ZipVoice | Chinese and English (Emilia). |
| Pocket TTS | English tested. Kyutai's README now lists English, French, German, Portuguese, Italian, Spanish and Dutch as separate weights; which the sherpa export supports was not checked. Treat as English only. |

## Licences

Terms as published. Not legal advice; nothing here is cleared.

| Component | Licence | Notes |
| --- | --- | --- |
| sherpa-onnx code and libraries | Apache-2.0 | 2.0.0 removed espeak-ng and piper-phonemize. |
| ONNX Runtime 1.28.2 (bundled) | MIT upstream | Attribution notice needed. |
| espeak-ng (the spike's phonemiser) | GPL-3.0 upstream | Not in the prebuilt libs. Likely unsuitable to link into the app. |
| Kokoro-82M weights | Apache-2.0 (model card) | Not gated. |
| ZipVoice code | Apache-2.0 | The `k2-fsa/ZipVoice` Hugging Face repo declares no licence and the sherpa package has no licence file. Confirm weight terms with k2-fsa. Its training set Emilia is CC-BY-4.0 (gated) on its card. |
| Pocket TTS code | MIT | `kyutai-labs/pocket-tts`. |
| Pocket TTS weights | CC-BY-4.0, gated | `kyutai/pocket-tts` needs a Hugging Face login and accepted terms. CC-BY-4.0 requires attribution: credit, licence link, note of changes. |
| Pocket TTS sherpa package | CC-BY-4.0 `LICENSE`; README says "It is for non-commercial" | Built from the third-party export `KevinAHM/pocket-tts-onnx` (card CC-BY-4.0, not gated); downloaded here with no login. The README line contradicts the CC-BY-4.0 text. Clarify before shipping. |
| LibriSpeech reference clip | CC BY 4.0 (audio public domain) | Spike only. |

Pocket TTS preset voices carry their own licences
(`huggingface.co/kyutai/tts-voices`); not reviewed. Cloning needs none.

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

### Windows and macOS (research only)

- Windows: release v2.0.1 has `win-x64-shared-{MD,MT}-{Release,MinSizeRel,Debug,RelWithDebInfo}[-lib]`
  and static variants. The MD Release `-lib` tarball (7.3 MB) holds
  `sherpa-onnx-c-api.dll` (3.9 MB), `onnxruntime.dll` (17 MB) and import
  `.lib` files. It is the same C API and header. Not built or run. Windows
  arm64 was not checked.
- macOS: `osx-arm64`, `osx-x64` and `osx-universal2` shared `-lib` tarballs
  exist (arm64: c-api dylib 4.1 MB, onnxruntime dylib 29 MB). Bundled dylibs
  need signing and notarisation.

## Recommendations

| Platform | Recommendation | Reason |
| --- | --- | --- |
| Linux x64 | **Ship later** | The runtime works natively and in process. Pocket TTS is the lead candidate: the only model faster than real time here (RTF 0.43 on a 2013 CPU), it streams and needs no phonemiser. Blocked on the licence clarification (non-commercial line, gating, attribution) and an owner listening check. ZipVoice clones closer on the embedding measure but runs slower than real time here (RTF 1.1 to 2.5), needs an English phonemiser and covers only Chinese and English. Kokoro presets also run slower than real time here and need the phonemiser too. |
| macOS (arm64, x64) | **Ship later** (provisional) | Same C API and assets. Unmeasured. Needs runner measurements and dylib signing and notarisation. |
| Windows x64 | **Ship later** (provisional) | DLL assets and import libraries exist. Unmeasured; no Windows host was available. |
| iOS, Android | **N/A** | Owner decision: voice creation is desktop only. |

Next steps:

1. Owner: settle Pocket TTS against ZipVoice-only using the licence facts.
2. Ask the package exporter or Kyutai whether the sherpa Pocket TTS package
   may be used commercially.
3. Listen to the WAVs; repeat with 5, 15 and 30 s History-style references.
4. Measure macOS arm64, macOS x64 and Windows x64, and a current x64 CPU.
5. If Kokoro or ZipVoice stay in scope, choose an English phonemiser that can
   ship.
