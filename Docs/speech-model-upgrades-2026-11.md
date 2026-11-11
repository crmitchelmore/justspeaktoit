# Speech model upgrades: November 2026

Follow-up to the [October audit](transcription-model-audit-2026-10.md). Facts
below were rechecked against first-party pages on 2 November 2026.

## Announced shutdowns (`ModelRetirements`)

`Sources/SpeakCore/ModelRetirements.swift` is the one schedule shared by every
platform. Until a model's shutdown day (UTC) it stays selectable and its picker
description begins with "Retiring <date>: …". From that day the catalogue hides
it. What happens to a saved selection depends on whether a verified equivalent
exists; a matching date alone is not compatibility:

- **Automatic:** only when the successor accepts the same inputs and returns the
  same output shape. The batch/live normalisers move the saved ID on the day.
- **Explicit choice:** otherwise the saved ID is kept, as the record of what the
  user asked for, and every request fails before reaching the provider with
  `ModelRetiredError`: "<model> was retired by its provider on <day>. Choose
  another model in Settings: …". Nothing silently switches model or drops a
  feature. The guard runs in the shared OpenAI and Mistral batch clients, the
  shared Voxtral live client, the iOS batch client and the shared OpenAI speech
  request builder (Mac and desktop).

Both checks are evaluated when they are used, not at launch. Pickers re-filter
the catalogue on each read, and Mac and iOS apply automatic successors when a
recording resolves its model. An app left running across a shutdown day
therefore stops offering the model and moves equivalent selections without a
restart.

Custom and OpenRouter identifiers are never touched. Permanent migrations stay
in `batchTranscriptionSuccessors`/`liveTranscriptionSuccessors`; the sets are
disjoint and each automatic successor is a current entry of the same mode
(tested in `ModelRetirementTests`).

| Saved model | Shuts down | On that day | Why |
| --- | --- | --- | --- |
| `openai/gpt-4o-transcribe`, `openai/gpt-4o-mini-transcribe` | 2027-02-26 | Moves to GPT Transcribe | Same text output; $0.0045/min (Mini was $0.003) |
| `openai/gpt-4o(-mini)-transcribe-streaming` | 2027-02-26 | Moves to GPT Live Transcribe | Same live deltas; $0.017/min |
| `openai/whisper-1` | 2027-02-26 | Kept; error until user chooses (GPT Transcribe recommended) | GPT Transcribe has no `verbose_json` segment timestamps |
| `openai/gpt-4o-transcribe-diarize` | 2027-02-26 | Kept; error until user chooses | OpenAI has no speaker-labelling successor; error points to Scribe v2, Soniox or Gemini 3.5 Transcribe |
| `mistral/voxtral-mini-latest` (Voxtral 2) | 2027-04-30 | Kept; error until user chooses (Mini Transcribe 3 recommended) | Successor is a public preview |
| Voxtral Realtime 2602 | 2027-04-30 | Kept; error until user chooses (Realtime 3 recommended) | Preview; $0.008/min, up from $0.006 |
| `openai/gpt-audio` (OpenRouter) | 2027-01-20 | Kept; error until user chooses (GPT Transcribe recommended) | OpenAI names `gpt-audio-1.5`, but OpenRouter does not list it (models API, 3 Nov 2026) |
| OpenAI `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | 2027-01-06 | Kept; user chooses (GPT Realtime 2.1 mini recommended) | Different API and voices; see below |

GPT Transcribe and GPT Live Transcribe now have per-minute estimates from their
model pages. GPT Audio is guarded in the shared OpenRouter audio-chat client
and stays routed after shutdown so a saved selection reports the retirement.
When OpenRouter lists `openai/gpt-audio-1.5`, qualify it and add it as a new
entry; the saved GPT Audio choice is not remapped. The app does not use
`/v1/audio/translations`, and
`gpt-realtime-whisper` is not retiring. Voxtral 2 and 3 share a batch client
(`language`, `context_bias`), so the preview is a one-click choice, not a
code migration.

## OpenAI Realtime speech voices (Mac, Windows, Linux)

OpenAI's recommended successor, `gpt-realtime-2.1-mini`, is not accepted by
`/v1/audio/speech`. The new shared `OpenAIRealtimeSpeechSynthesizer`
(`Sources/SpeakCore/OpenAIRealtimeSpeech.swift`) speaks through a Realtime
WebSocket instead and returns 24 kHz PCM16, which each host wraps as WAV, so
file playback is unchanged.

- **Opt-in voices**, not a fourth quality tier: saved tiers map to the retiring
  models, so the ten Realtime voices (`alloy`, `ash`, `ballad`, `coral`, `echo`,
  `sage`, `shimmer`, `verse`, `marin`, `cedar`) appear as separate
  `openai/realtime/<voice>` entries labelled "GPT Realtime 2.1 mini". They reuse
  the OpenAI key. `fable`, `nova`, `onyx` have no Realtime equivalent, so saved
  speech-API voices are never remapped.
- **Reading, not replying:** each ≤1,000-character chunk is an out-of-band
  response (`conversation: "none"`) with strict read-aloud instructions. The
  audio transcript must contain every input word in order, so a dropped word
  such as "not" rejects the chunk (`notAReading`) instead of playing it.
  Numerals are exempt, since "2026" may be read as words in any language. Each
  numeral allows a few extra spoken words, with a small allowance for symbols
  read aloud. A longer addition is treated as an answer. Expansions such as "Dr"
  read as "doctor" are also rejected: strictness is preferred to wrong speech.
  A chunk with no audio, and an incomplete, failed or cancelled response, are
  errors, never truncated audio.
- **Limits:** speed 0.25–1.5 (outside that is an error, not clamped; the voice
  capabilities and the Mac slider use this range); 120 s deadline; audio is
  played after the whole text is synthesised, not streamed. Output is always
  WAV, so the Mac File Format picker is disabled for these voices.
- **Cost:** token-based ($20 per million audio output tokens, $0.6 text input),
  computed from each `response.done` usage, so there is no per-character rate.
  If any response omits usage, the cost is unknown (`nil`), never $0. The Mac
  records this cost; desktop usage records only audio duration for these voices.
- **Evidence:** protocol, chunking, guard, error and timeout paths are tested
  against a scripted socket (`OpenAIRealtimeSpeechTests`). **No live call was
  made** (no authorised credential), so verbatim fidelity, the reading check's
  false-rejection rate, latency, real cost per character and voice quality are not yet accepted.

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

## Weekly check: 9 November 2026

Rechecked against first-party pages. AssemblyAI, ElevenLabs, OpenAI, Deepgram,
Groq, Mistral, Azure and OpenRouter (`openai/gpt-audio`, `gpt-audio-mini`) need
no change.

- **Soniox v6.** [Soniox](https://docs.soniox.com/stt/models) released
  `stt-rt-v6` and `stt-async-v6` on 3 November and removes v5 on 15 December
  2026, after which it routes v5 requests to v6 itself. Soniox states v6 is
  fully API-compatible (only the model name changes), and
  [pricing](https://soniox.com/pricing) is unchanged. The catalogue now offers
  v6, and saved v3, v4 and v5 selections move to v6 in their own mode. v5
  pricing stays for history. Output formatting changes: spoken dictation
  commands ("period", "new line", "scratch that") come back as words, and
  prices and alphanumeric codes are written closer to how they were spoken
  ("15 dollars and 20 cents", no inserted hyphens in codes). The app does not
  apply spoken commands to transcripts, so these words reach the output (or
  post-processing, when enabled) as text.
- **Gemini TTS 3.8 Flash-Lite.** Google shuts down
  `gemini-3.1-flash-tts-preview` on 17 November 2026 and names
  [`gemini-3.8-flash-lite-tts`](https://aistudio.google.com/docs/models/gemini-3.8-flash-lite-tts.md)
  as its replacement. It has the same 30 voices and Interactions request, and
  covers all 18 explicit app languages. The app sends only single-speaker plain
  text, which 3.8 reads verbatim. Saved 3.1 selections resolve to Flash-Lite
  (`GeminiTTSModel.selectableModel(forID:)`); the 3.1 ID still resolves for
  history and keeps its price. Requests now declare `audio/l16` output. The
  estimate uses the 2027 list price ($12/M audio tokens, $1/M text tokens),
  not the introductory price that runs to 31 December 2026.

Carried blockers are unchanged: Distil-Whisper v3.5 still has no published
WhisperKit/Core ML export; Realtime TTS, local Nemotron 3.5 and Voxtral 3 are
not live- or device-accepted.

## Weekly check: 11 November 2026

Rechecked against first-party pages; no paid calls were made (no keys were
configured). The user report "MAI 2 is out" matches MAI-Transcribe-2 leaving
preview in Azure Speech.

**Changed**

- **Microsoft.** The [MAI-Transcribe page](https://learn.microsoft.com/azure/ai-services/speech-service/mai-transcribe)
  (updated 6 Nov) no longer carries a preview notice, so the batch MAI-Transcribe-2
  and 1.5 entries drop "(Preview)". The fast-transcription request is unchanged.
  MAI-Transcribe-2-Streaming, Voice Live transcription and MAI-Voice-2.1 are still
  public preview. The Voice Live `mai-transcribe` alias now points at
  MAI-Transcribe-2, so that route needs no change. Both introductory rates
  ($0.10/h batch, $0.54/h streaming) still end on 31 December 2026 with no later
  rate published. No MAI text model is on OpenRouter.
- **OpenAI.** [Deprecations](https://developers.openai.com/api/docs/deprecations):
  `gpt-5-mini`, the default cleanup model on every platform, shuts down on
  11 December 2026, and `gpt-5.4-nano` on 1 April 2027. `ModelRetirements` gained
  a `postProcessing` mode. Saved selections move automatically, because any chat
  model accepts the same OpenRouter request. GPT-5 Mini moves to GPT-5.6 Luna
  ($0.20/$1.20 per M tokens) and GPT-5.4 Nano to GPT-6 Luna ($0.10/$0.50).
  OpenAI's named replacement for GPT-5 Mini, GPT-5.6 Terra, costs about eight
  times as much, so the retirement note recommends it as an explicit choice.
  - The shared request encoder sends the successor once the day passes, so a
    running app keeps working.
  - The new default is GPT-5.6 Luna on Mac, iOS, Windows/Linux, Android
    (`CloudCatalog.CLEANUP_MODEL`) and the paid-access worker.
  - GPT-5.6 rates now match the standard tier: Luna $0.20/$1.20, Terra $2/$12,
    Sol $4/$20 (previously $1/$6, $2.5/$15 and $5/$30).
- **Direct (native) cleanup routes** from #1453 follow the same rules.
  `native/openai/gpt-5-mini` moves to `native/openai/gpt-6-luna` on 11 December;
  the direct list has no GPT-5.6 Luna. Groq shut down `llama-3.1-8b-instant` for
  free and developer tiers on 16 August 2026 ([deprecations](https://console.groq.com/docs/deprecations)),
  so `native/groq/llama-3.1-8b-instant` is hidden and moves to the new
  `native/groq/openai/gpt-oss-20b` entry ($0.075/$0.30 per M tokens).
- **Paid-access worker.** Its batch route, `google/gemini-2.0-flash-001`, is no
  longer listed on OpenRouter. It now uses `google/gemini-3.1-flash-lite`, the
  app's batch default. Policy version `2026-11-11`.
- **Anthropic.** Claude Haiku 5.5 ($0.10/$0.50) and Sonnet 5.5 ($2/$10), both with
  a 1M-token context, are added as optional cleanup entries via OpenRouter.
  Haiku 4.5 and Sonnet 4.6 remain Active, so they are unchanged.
- **Google.** Gemini 3.5 Transcribe and Transcribe Live are in the stable tables of
  the [deprecations page](https://ai.google.dev/gemini-api/docs/deprecations), so
  "(Preview)" is dropped. They stay opt-in and are never a default.
- **xAI.** `grok-voice-2.0` is deprecated. [Grok Voice 3.0](https://docs.x.ai/developers/models/grok-voice-3.0)
  keeps the same endpoint, session parameters, events and price. The live entry
  is now `xai/grok-voice-3.0-streaming` (wire model `grok-voice-3.0`), and saved
  Grok Voice Think Fast 2.0 selections migrate to it.
- **ElevenLabs.** [Scribe v3 and Scribe v3 Live](https://elevenlabs.io/docs/overview/models)
  succeed Scribe v2: only `model_id` changes, and v2 remains available. Both are
  added as new entries; saved v2 selections are not moved.
  - The Mac live controller now sends the selected model rather than a hard-coded
    v2 identifier.
  - [Pricing](https://elevenlabs.io/pricing/api) fell: batch is $0.20/h (was
    $0.22) and realtime $0.22/h (was $0.39).
  - Realtime keyterms are capped at 50 terms of at most 20 characters each, per
    the keyterm-prompting guide.
- **Deepgram.** The [pricing page](https://deepgram.com/pricing) no longer shows
  the streaming promotions. Nova-3 and Flux English streaming are $0.0077/min.
  Aura-2 TTS is $0.030 per 1k characters and Aura-1 $0.015 (both were estimated at
  $0.0135).

**No change needed:** AssemblyAI, Soniox, Cartesia, Modulate, Groq, Mistral,
Meta and the local models.

- **AssemblyAI** launched TTS-1, which the app does not integrate.
- **Soniox** `tts-rt-v1` is already gone from the catalogue.
- **Cartesia** still lists Sonic 3.6 and Ink 2 as current.
- **Mistral** pricing matches, and Voxtral 3 is still Public Preview.
- **Meta** has no first-party update; its docs were not reachable.
- **Local models:** WhisperKit, whisper.cpp, Parakeet and Nemotron have no new
  first-party exports.

**Not changed, follow-ups**

- **Gladia** now prices in euros only (€0.27/h async, €0.68/h live, new
  `solaria-3`). The USD estimates are left as they are, because converting them
  would mean guessing an exchange rate.
- **Gemini 3.1 Flash-Lite** shuts down on 7 May 2027 (replacement
  `gemini-3.5-flash-lite`). It is the batch default and the fast text default,
  and it appears in both the batch and cleanup catalogues. `ModelRetirements` keys
  shutdowns by ID alone, so one ID cannot carry two modes yet. Schedule it in a
  later check.
- **Gemini 2.5 Flash** routes to 3.5 Flash-Lite from 1 December on Google's side,
  so nothing breaks.
- **ElevenLabs** Eleven v4 Turbo TTS is not yet added.
- **Mistral** Voxtral TTS 3 is $13/M characters (the estimate uses $16/M). A
  saved Mistral voice does not record its model, so the estimate cannot vary by
  model.
- **sherpa-onnx** 2.0.1 is available; the app pins 1.13.5.
- NVIDIA's unified Nemotron ASR has no first-party sherpa export.

Carried blockers are unchanged: Distil-Whisper v3.5 still has no WhisperKit or
Core ML export.
