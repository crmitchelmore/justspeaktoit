# Transcription model audit: October 2026

Audited on **2026-10-13**, using public first-party documentation and OpenRouter's
public inventory, without account keys or billable service probes. A provider's
latest family is not automatically a replacement for every tier, language set
or request protocol. `SpeakCore.ModelCatalog` remains the canonical catalogue.
Existing defaults and custom identifiers are preserved.

## Changes

| Surface | Previous | Current | Saved selection |
| --- | --- | --- | --- |
| AssemblyAI streaming | `universal-3-5-pro` | `universal-3-6-pro` | Exact old live aliases migrate to `assemblyai/universal-3-6-pro-streaming` |
| AssemblyAI batch | `universal-3-5-pro`, fallback `universal-2` | Unchanged; no documented batch 3.6 | Current batch IDs remain unchanged |
| Soniox batch/live | Catalogue already v5; some saved v3/v4 IDs lacked migrations | v5 | Exact retired v3/v4 IDs migrate within their original mode |
| OpenRouter OpenAI audio-chat | Unavailable pinned GPT-4o audio preview | `openai/gpt-audio` | Only the shipped `openai/gpt-4o-audio-preview-2024-12-17` ID migrates |
| Modulate Velma-2 | `modulate-developer-apis.com` origin | `platform.modulate.ai` | IDs, stored key, endpoint paths and payload remain unchanged |
| Mistral batch | `voxtral-mini-latest` | Same current alias, labelled Voxtral Mini Transcribe 2 | No migration; corrected published rate |
| Cartesia streaming | Ink-2 described as English-only | English, French, Hindi, Japanese and Spanish | No migration or route change |

AssemblyAI's mode-specific [streaming selection guide](https://www.assemblyai.com/docs/streaming/select-the-speech-model)
and [WebSocket API specification](https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket.md)
recommend 3.6. Its [prerecorded selection guide](https://www.assemblyai.com/docs/pre-recorded-audio/select-the-speech-model)
still specifies 3.5 plus Universal-2. Older general overview pages can lag these
mode-specific references. 3.5 streaming remains supported upstream; the app's
existing flagship slot now follows 3.6 rather than adding a duplicate slot.

The existing [turn contract](https://www.assemblyai.com/docs/streaming/turn-detection)
is unchanged: partials replace the complete current turn, finals require both
`end_of_turn` and `turn_is_formatted`, and `turn_order` prevents duplicate commits.
No `format_turns` parameter is sent. PCM framing, ordered send drain,
`ForceEndpoint`, formatted-final wait, `Terminate`, EU-first fallback and
keyterms remain intact. 3.6's additional `SpeechStarted` event is harmlessly
ignored by the existing event parser. The app does not newly expose provider
prompting or language controls.

[AssemblyAI pricing](https://www.assemblyai.com/pricing) is $0.45 per **streaming
session** hour, $0.21 per 3.5 batch audio hour, and $0.15 per Universal-2 batch
audio hour. The streaming comparison converts that hourly rate to minutes;
estimates based on recording duration do not include extra idle socket time.
[Mistral's model page](https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02.md)
lists $0.003/minute for Voxtral Mini Transcribe 2, not $0.001.

## Curated OpenRouter recorded-audio choices

The [public model inventory](https://openrouter.ai/api/v1/models) advertised audio
input for every added identifier:

| Added ID | Purpose |
| --- | --- |
| `thinkingmachines/inkling` | Hosted Inkling audio understanding |
| `thinkingmachines/inkling-small` | Smaller hosted Inkling tier |
| `thinkingmachines/inkling:free` | Free hosted tier, subject to availability and rate limits |
| `thinkingmachines/inkling-small:free` | Free Small tier, subject to availability and rate limits |
| `google/gemini-3.1-pro-preview` | Currently advertised Gemini Pro audio preview |
| `mistralai/voxtral-small-24b-2507` | Voxtral Small audio-instruct model, distinct from Mini transcription |
| `google/gemini-3.8-flash` | Current advertised Gemini Flash audio-chat generation |
| `google/gemini-3.5-flash-lite` | Current advertised Gemini Flash Lite audio-chat generation |

These are **batch-only hosted choices**, using the existing
`POST https://openrouter.ai/api/v1/chat/completions` inline base64 `input_audio`
contract and `openrouter.apiKey`. The shared catalogue's credential ownership,
not `google/`, `openai/` or `mistralai/` prefixes, determines routing. They are not
the dedicated `openrouter/transcription/...` speech-to-text route and do not use
direct Google/OpenAI/Mistral credentials. iOS now derives visibility from that
same shared ownership; portable desktop routing already does so.

The [OpenRouter audio guide](https://openrouter.ai/docs/guides/overview/multimodal/audio)
warns that accepted formats depend on the actual model/provider.
[Inkling's official card](https://thinkingmachines.ai/model-card/inkling/)
specifies 16 kHz WAV and recommends audio within 20 minutes. All four Inkling
routes therefore prepare mono PCM16 WAV in process on Apple and validate the
native canonical WAV on portable hosts, with an explicit 20-minute preparation
limit. Portable import adapters are told that these routes need native
conversion. The recording is never modified; invalid containers, decoded size
limits and cancellation fail before upload. This reuses the shared preparation
pipeline used by Meta/Azure rather than assuming OpenRouter converts M4A.

Inkling is hosted-only here. Its full checkpoint requires at least 600 GB of
quantized VRAM or 2 TB BF16 VRAM, beyond the app's qualified local runtimes.
The model-card context size is not a guarantee of a particular hosted endpoint.
The app sends its standard transcript-only prompt, temperature 0 and non-streaming
chat request. It does **not** claim to reproduce a chart's reasoning budget,
context settings, latency or benchmark result.

The old [pinned GPT-4o audio preview endpoint lookup](https://openrouter.ai/api/v1/models/openai/gpt-4o-audio-preview-2024-12-17/endpoints)
returned 404 and the ID was absent from inventory.
[GPT Audio's endpoint lookup](https://openrouter.ai/api/v1/models/openai/gpt-audio/endpoints)
advertised an active OpenAI endpoint. OpenAI recommends `gpt-audio-1.5`, but
OpenRouter did **not** advertise that ID at audit time; no unverified route was
invented. GPT Audio itself has a scheduled upstream retirement (below).
Existing hosted Gemini 3.1 Flash Lite and 2.5 Flash are still advertised and
remain distinct choices. The batch default stays Gemini 3.1 Flash Lite.

Paid audio-chat models have token-based, provider-specific pricing, not a
verified fixed rate per audio minute. Their new comparison entries remain
unpriced rather than inventing one. Free variants carry zero model-usage price;
that does not imply unlimited availability or that every account can use them.

## Complete existing-provider audit

| Provider | Finding and action | Authoritative sources |
| --- | --- | --- |
| Azure | Main already offers MAI-Transcribe-2 and 1.5 batch and generic MAI Voice Live. MAI-1 is deprecated; no downgrade or fabricated Gaia route. Genuine incremental MAI-2 streaming is owned by pending PR [#1202](https://github.com/crmitchelmore/justspeaktoit/pull/1202), not duplicated here. | [MAI transcription](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe) |
| AssemblyAI | Upgrade streaming flagship to Universal-3.6 Pro. Keep 3.5 prerecorded plus Universal-2 fallback; protocol details above. | [Streaming selection](https://www.assemblyai.com/docs/streaming/select-the-speech-model), [batch selection](https://www.assemblyai.com/docs/pre-recorded-audio/select-the-speech-model) |
| OpenAI | Direct `gpt-transcribe` batch and `gpt-live-transcribe` streaming already current. Preserve still-supported Whisper, GPT-4o, Mini and diarization tiers. `whisper-1`, `gpt-4o-transcribe`, Mini and diarization retire 2027-02-26; legacy audio/voice including `gpt-audio` retire 2027-01-20. GPT Audio's recommended successor is not yet advertised on OpenRouter. | [Transcription](https://developers.openai.com/api/docs/guides/transcription), [deprecations](https://developers.openai.com/api/docs/deprecations) |
| xAI | Dedicated `grok-voice-transcribe-2.0` batch/live and separate `grok-voice-think-fast-2.0` voice route already current. Their protocols are distinct and unchanged. | [STT](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text), [speech-to-speech](https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech) |
| Deepgram | Nova-3 general and Flux English/multilingual streaming current. Older still-supported Nova tiers serve different coverage/features; no blanket replacement. | [Models and languages](https://developers.deepgram.com/docs/models-languages-overview.md) |
| Cartesia | Ink-2 stable streaming current; corrected its five-language description. Ink Whisper is still a supported, affordable multilingual batch/streaming tier, not replaced with a streaming-only model. | [Latest STT](https://docs.cartesia.ai/build-with-cartesia/stt/latest.md), [older supported models](https://docs.cartesia.ai/build-with-cartesia/stt/older-models.md) |
| Gladia | Solaria-1 remains default with broad language coverage and code-switching. Solaria-3 is a distinct batch-only five-language model without code-switching, not a universal successor; no automatic replacement. | [Model comparison](https://docs.gladia.io/chapters/introduction/models.md) |
| ElevenLabs | Scribe v2 batch, v2 realtime and v2 medical already current. Existing v1 retirement migrations remain intact. | [Models](https://elevenlabs.io/docs/overview/models.md) |
| Soniox | Async/RT v5 already current. v3 retired February 2026, v4 June 2026; added exact saved-selection migrations. Custom IDs stay unchanged. | [Model lifecycle](https://soniox.com/docs/stt/models) |
| Speechmatics | Enhanced/Standard remain supported batch/live. Melia-1/Oak-1 have different, reduced batch feature sets; Agent STT Linden-1 is a separate protocol. No forced replacement. iOS batch exclusion is an upload-route limitation, not absent credential storage. | [Models and feature sets](https://docs.speechmatics.com/speech-to-text/models.md) |
| Mistral | `voxtral-mini-latest` already aliases GA Voxtral Mini Transcribe 2 (`voxtral-mini-2602`); updated name/rate. `voxtral-mini-transcribe-realtime-2602` current. Hosted Voxtral Small is a separate audio-instruct tier. | [Mini Transcribe 2](https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02.md), [realtime](https://docs.mistral.ai/studio/audio/speech_to_text/realtime_transcription.md), [models](https://docs.mistral.ai/models.md) |
| Rev.ai | Current default/Reverb batch and streaming services are server-versioned. No verified superseding explicit model ID; keep current routes. | [Asynchronous API](https://docs.rev.ai/api/asynchronous), [streaming API](https://docs.rev.ai/api/streaming) |
| Modulate | Velma-2 models current. Corrected batch/live/warm-up/key-dashboard origin to `platform.modulate.ai`. HTTP `X-API-Key`, WebSocket `api_key`, WAV/audio framing and completion contract preserved. | [Authentication](https://docs.modulate.ai/guides/authentication.md), [STT guide](https://docs.modulate.ai/get-started/stt.md), [batch spec](https://docs.modulate.ai/api/velma_2_stt_batch.yaml), [streaming spec](https://docs.modulate.ai/api/velma_2_stt_streaming.yaml) |
| Google Gemini | Direct Gemini 3.5 Transcribe batch and Live Transcribe preview already current. Their dedicated ASR APIs are not replaced with Gemini chat generations. New hosted Flash/Pro choices are separate. | [Transcribe](https://ai.google.dev/gemini-api/docs/transcribe), [Live Transcribe](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe) |
| Meta | Official model remains `muse-voice-transcribe-1.0`; current 16 kHz batch WAV and 24 kHz live contracts match. Only audio preparation is shared with Inkling; no model generation invented. | [STT](https://dev.meta.ai/docs/speech-to-text), [voice API](https://dev.meta.ai/docs/api-reference/voice) |
| Groq | Whisper Large v3 Turbo remains supported production batch at $0.04/hour. Large v3 is a distinct accuracy/translation tier, not a blanket superseding model. | [Speech-to-text](https://console.groq.com/docs/speech-to-text) |
| Apple Speech | Native OS-provided Speech/SpeechAnalyzer, not a versioned hosted/downloaded model. Do not invent a provider version or change the OS gate/default. | Repository's existing OS capability guards and native Speech frameworks |
| Downloaded local | Existing Whisper Large-v3 Turbo, Parakeet v3 and Phonon-2 cards confirm their supported tiers. New multilingual Nemotron 3.5 exists, but the pinned English Nemotron/sherpa artifacts cannot be replaced without runtime/export/license/device qualification. Downloads and runtimes are not automatically upgraded. | [Whisper card](https://huggingface.co/openai/whisper-large-v3-turbo/raw/main/README.md), [Parakeet card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/raw/main/README.md), [Phonon-2 card](https://huggingface.co/FermionResearch/Phonon-2/raw/main/README.md), [current Nemotron card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/raw/main/README.md), [new Nemotron 3.5](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/raw/main/README.md) |

## Access and qualification limitations

Whisper Tiny/Base/Small and the dated lightweight Zipformer exports are
deliberate size/latency tiers, not aliases to the largest newest checkpoint.
Existing distilled Whisper v3/v3 Turbo choices remain separate from multilingual
Whisper Turbo. The [Distil-Whisper v3.5 card](https://huggingface.co/distil-whisper/distil-large-v3.5)
does identify a newer drop-in English checkpoint, but
[Argmax's published WhisperKit Core ML tree](https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main?limit=100)
advertised only the existing v3/v3 Turbo exports at audit time, not v3.5.
New raw weights do not create a runnable Core ML catalogue entry; qualifying an
export is follow-up work rather than redirecting installed v3 models to a
missing directory. The portable GGML projection also deliberately excludes
unqualified distilled entries. No assertion is made that every third-party
export is the newest upstream checkpoint.

**MAI-Gaia-3.0:** no public API identifier, request specification or accessible
endpoint was verified from the chart name and current Azure model documentation.
This is an access/documentation blocker, not proof that the model does not exist.
Integration requires provider-issued API documentation and access; mapping the
chart name onto an existing MAI endpoint would falsely claim support.

**Local Nemotron 3.5:** published weights alone do not establish compatibility
with the app's pinned native runtime/export, licensing acceptance or supported
hardware. Keep the qualified English tier until those gates are satisfied.

Public inventory and a valid model card do not establish account entitlement,
region availability or live inference quality. Network tests here use fake
responses; no purchased transcription, found credentials or benchmark claims
are part of this audit. New Pulse/Reson8/StepAudio/Alibaba integrations are
separate workstreams, outside this existing-provider audit.
