# Speech model upgrades: November 2026

Follow-up to the [October audit](transcription-model-audit-2026-10.md). Facts
below were rechecked against first-party pages on 2 November 2026.

## Announced shutdowns (`ModelRetirements`)

`Sources/SpeakCore/ModelRetirements.swift` is the one schedule shared by every
platform. Until a model's shutdown day (UTC) it stays selectable and its picker
description begins with "Retiring <date>: …". From that day the catalogue hides
it and the batch/live normalisers move saved selections to the successor, so a
build that is never updated still stops calling a dead model. Custom and
OpenRouter identifiers are never touched. Permanent migrations stay in
`batchTranscriptionSuccessors`/`liveTranscriptionSuccessors`; the two sets are
disjoint and each successor is a current entry of the same mode (tested in
`ModelRetirementTests`).

| Saved model | Shuts down | Moves to | Notes |
| --- | --- | --- | --- |
| `openai/whisper-1`, `openai/gpt-4o-transcribe` | 2027-02-26 | GPT Transcribe | $0.0045/min |
| `openai/gpt-4o-mini-transcribe` | 2027-02-26 | GPT Transcribe | Up from $0.003/min |
| `openai/gpt-4o-transcribe-diarize` | 2027-02-26 | GPT Transcribe | **Loses speaker labels**; notice suggests Scribe v2, Soniox or Gemini 3.5 Transcribe |
| `openai/gpt-4o(-mini)-transcribe-streaming` | 2027-02-26 | GPT Live Transcribe | $0.017/min |
| `mistral/voxtral-mini-latest` (Voxtral 2) | 2027-04-30 | Voxtral Mini Transcribe 3 | $0.0035/min, public preview |
| Voxtral Realtime 2602 | 2027-04-30 | Voxtral Realtime 3 | $0.008/min (up from $0.006), public preview |
| OpenAI `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | 2027-01-06 | none | See blocker below |

Selections move on the provider's retirement date rather than now because the
deprecated models still work, OpenAI's tiers are cheaper today, and both
Voxtral 3 successors are previews. Voxtral 2 and 3 use the same batch client
(`language`, `context_bias`); the app never requested Voxtral 2 diarisation,
so nothing is lost. Live language detection stays automatic.

GPT Transcribe and GPT Live Transcribe now have per-minute estimates from their
model pages. The app does not use `/v1/audio/translations`, and
`gpt-realtime-whisper` is not retiring.

**OpenAI TTS blocker:** OpenAI recommends `gpt-realtime-2.1-mini`, which is a
Realtime-session model and is not accepted by `/v1/audio/speech`. Substituting
the string would break playback, and a Realtime speech path is a new transport
outside the file playback architecture. The Mac voice settings and the desktop
voice list label the three models with the shutdown date; on that day users
must choose another voice provider. A same-API successor, or a deliberate
Realtime speech design, is follow-up work.

Sources: [OpenAI deprecations](https://developers.openai.com/api/docs/deprecations),
[GPT Transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe),
[GPT Live Transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe),
[Voxtral Mini Transcribe 2](https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02),
[Voxtral Realtime 2602](https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-26-02),
[Voxtral Mini Transcribe 3](https://docs.mistral.ai/models/voxtral-mini-transcribe-3-0),
[Voxtral Realtime 3](https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-3-0).

## Local multilingual Nemotron 3.5 (macOS)

Two new downloaded streaming models, alongside the unchanged English Nemotron
pair (NVIDIA still recommends the English model for English-only use):

| Choice | sherpa-onnx export | Archive SHA-256 |
| --- | --- | --- |
| 560 ms | `sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11` | `c6bf5e0d…05ae3a` (reproduced from a download) |
| 1120 ms | `sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11` | `adbdd5e9…9beed3` (GitHub release digest) |

- Runtime: sherpa-onnx gained the multilingual model in 1.13.3 and republished
  the exports with 1.13.5. The app now pins 1.13.5 for new installs, records the
  installed version and refuses to start Nemotron 3.5 on an older runtime with
  an "Update Runtime" action. Existing models keep working on older runtimes.
- Language: an explicitly chosen app language is passed as the model's
  `language` option (exact locale, else a supported bare code; Norwegian maps to
  `nb`). Automatic sends nothing. Hints are only sent for the 32
  transcription-ready and broad-coverage locales; the 8 adaptation-ready ones
  use auto-detect. A wrong forced language produced an **empty** transcript in
  testing, which is why Automatic never guesses.
- Licence: [OpenMDW-1.1](https://openmdw.ai/license/1-1/), permissive; notice
  duties apply to redistributors. The app downloads the archive on demand from
  the upstream release and does not redistribute it.
- Measured once on an Apple M2 Pro (CPU, 2 threads, Python sherpa-onnx 1.13.5
  CLI, not the app): 560 ms export loads in ~1.2 s, RTF 0.107–0.127, peak RSS
  ~1.25–1.33 GB; download 453 MiB, ~667 MB extracted. With a `ja` hint a
  Japanese clip transcribed correctly where auto-detect prefixed Korean text.
  Not measured: the 1120 ms export, Intel Macs, in-app end-to-end use, accuracy.
- Not offered on Windows/Linux: those hosts have no sherpa streaming runtime.

Sources: [model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/raw/main/README.md),
[sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models).

## Distil-Whisper Large v3.5: not shipped (blocker)

The [v3.5 checkpoint](https://huggingface.co/distil-whisper/distil-large-v3.5)
(English, MIT, 756M parameters) has no export that runs on the app's supported
local runtimes:

- **WhisperKit (macOS/iOS):** [Argmax's Core ML repository](https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main)
  publishes only `distil-large-v3` and `distil-large-v3_turbo`. Shipping a
  self-converted Core ML export would add model hosting and per-device
  qualification the app does not have.
- **whisper.cpp (Windows/Linux):** the official
  [`distil-large-v3.5-ggml`](https://huggingface.co/distil-whisper/distil-large-v3.5-ggml)
  file exists (1,519,521,155 bytes, SHA-256 `ec249891…8dcf26`), but whisper.cpp
  does not run distilled checkpoints with their chunked long-form decoding, the
  reason `WhisperCppModels` already excludes the v3 distilled entries.
- **sherpa-onnx:** a v3.5 Whisper export exists, but the app's sherpa sidecar
  only runs streaming transducer models.

Existing Distil v3 / v3 Turbo choices are unchanged. Upstream benchmark claims
are not app measurements. Revisit when Argmax publishes a v3.5 Core ML export.
