# Groq, Gemini, Mistral and Speechmatics voice output

Four speech-generation providers added in September 2026. Each reuses the
Keychain entry its transcription provider already writes, so there is one
combined credential card per provider in **Settings → API Keys** rather than a
second entry pointing at the same secret. No additional paid subscription,
credit purchase or automatic top-up is enabled by this integration.

All four are macOS-only, matching every other entry in
`Sources/SpeakApp/TextToSpeech/`. The iOS voice-output route
(`VoiceOutputProvider`) still carries Deepgram, Soniox and OpenRouter only;
`TTSProviderPlatformTests` asserts that restriction so it cannot drift silently.

None of the four exposes a speaking-rate or pitch parameter. Rather than drop
those settings silently, a non-default speed or pitch returns an explicit
message naming what the provider ignores.

## Groq Orpheus

| | |
| --- | --- |
| Credential | `groq.apiKey`, shared with Groq Whisper transcription |
| Endpoint | `POST https://api.groq.com/openai/v1/audio/speech`, `Authorization: Bearer` |
| Models | `canopylabs/orpheus-v1-english`, `canopylabs/orpheus-arabic-saudi` |
| English voices | `autumn`, `diana`, `hannah` (female); `austin`, `daniel`, `troy` (male) |
| Arabic (Saudi) voices | `lulwa`, `noura`, `aisha` (female); `abdullah`, `fahad`, `sultan` (male) |
| Output | WAV only |
| Price | $22 / 1M characters (English), $40 / 1M characters (Arabic) |

The retired `playai-tts` and `playai-tts-arabic` identifiers are deliberately
absent: Groq shut them down on 31 December 2025 and a request naming one now
fails. The upstream open-source Orpheus voice names (`tara`, `leo`, …) are not
what Groq hosts and are equally absent.

Groq caps one Orpheus request at **200 characters**. Longer text is split at
sentence ends by `TTSTextChunker` and the WAV parts are joined by
`TTSAudioJoiner`, so a long document costs many requests against a low
per-minute allowance.

**A stored key is not access.** Orpheus requires a Groq organisation admin to
accept the model terms in the console once. That only surfaces on the first
synthesis request, as HTTP 400 with `code: model_terms_required`; the client
reports it as an access requirement with the console link, never as a bad key.
Organisation or project model blocks (`model_permission_blocked_org`,
`model_permission_blocked_project`) and the spend-limit block
(`blocked_api_access`) are classified the same way. Groq documents no realtime
speech-to-text, and none is advertised.

## Gemini

| | |
| --- | --- |
| Credential | `google.apiKey`, shared with Gemini transcription |
| Endpoint | `POST https://generativelanguage.googleapis.com/v1beta/interactions`, `x-goog-api-key` |
| Model | `gemini-3.1-flash-tts-preview` |
| Voices | The 30 documented prebuilt voices, `Zephyr` … `Sulafat` |
| Output | 24 kHz mono 16-bit PCM, wrapped in a RIFF header by `PCMWaveWriter` |
| Price | $20 / 1M audio-output tokens, at 25 tokens per second of speech |

This is Google's own billing and quota, not the OpenRouter speech route tracked
in #821. Speak already reaches Gemini transcription over the Interactions API,
and the speech-generation guide documents the same surface, so both directions
share one host, one header and one credential.

`gemini-2.5-flash-preview-tts` and `gemini-2.5-pro-preview-tts` are supported by
the Interactions API too, and are simply not offered yet: `gemini-3.1-flash-tts`
supersedes both, it is the only one of the three that supports streaming, and a
one-model picker is one fewer choice with no benefit attached. Adding them is a
catalogue entry and a price, not a new code path.

Because the charge is per generated audio token rather than per submitted
character, there is no honest pre-synthesis estimate — the cost shown in History
is computed from the measured duration after the fact. Google documents that a
small share of speech requests fail with HTTP 500 because the model answered in
text; the transport retries such a response once.

## Mistral Voxtral

| | |
| --- | --- |
| Credential | `mistral.apiKey`, shared with Voxtral transcription |
| Endpoint | `POST https://api.mistral.ai/v1/audio/speech`, `Authorization: Bearer` |
| Model | `voxtral-mini-tts-2603` (the dated release, pinned) |
| Voices | Loaded at runtime from `GET /v1/audio/voices` |
| Output | MP3 or WAV; the response is JSON carrying base64, not raw bytes |
| Price | $16 / 1M output characters |
| Languages | en, fr, es, pt, it, nl, de, hi, ar |

**Mistral publishes no preset voice identifiers.** Presets and cloned voices
share one UUID space and are only discoverable at runtime, so there is no
offline list to ship. The picker is empty until a Mistral key is stored, at
which point it loads the voices the account can actually use. That is also the
first moment any Voxtral voice could be spoken, so nothing unusable is offered.
Voice cloning is out of scope; the client only reads the listing.

The documented `pcm` format is float32 little-endian rather than the int16 the
platform audio path expects, so it is not offered. Server-sent-event streaming
is documented and not used: the macOS voice pipeline plays a finished file, so
there is nothing for a progressive stream to feed. Mistral returns HTTP 403 both
for a plan that excludes Voxtral TTS and for text its moderation declined, and
the response does not separate them, so the error names both possibilities.

## Speechmatics

| | |
| --- | --- |
| Credential | `speechmatics.apiKey`, shared with Speechmatics transcription |
| Endpoint | `POST https://preview.tts.speechmatics.com/generate/<voice>?output_format=wav_16000` |
| Voices | `sarah`, `theo` (UK); `megan`, `jack` (US) |
| Output | 16 kHz mono 16-bit WAV |
| Price | $0.011 / 1,000 characters on the Pro plan |

English only, four voices, no model selector: the voice is the whole choice.
Speechmatics serves speech generation from a single global `preview.` host with
no regional variants, so the region choice that applies to their transcription
endpoints has no equivalent here — and there is no documented data-residency
guarantee for speech generation.

Speechmatics still labels this a preview and states that during preview it
stores input text and generated audio to improve the service. The Settings copy
says so. It is not waitlisted or entitlement-gated: one portal key covers speech
to text and text to speech.

Key validation probes the transcription jobs endpoint, because Speechmatics
publishes no GET endpoint on the speech host. That proves the key is live; it is
not evidence of a speech-generation entitlement, and the code does not claim it
is. The speech host rejects at its edge proxy and returns an **HTML** body on
401, so the error reader treats a failed JSON decode as expected and never
echoes the body.

## Verification

Contract tests cover request shape, endpoint and headers, credential sharing,
voice-identifier routing, catalogue parity with the picker, empty text,
cancellation, and the auth / quota / rate-limit / access-gate classification for
each provider. They run against a stubbed `URLProtocol` and spend no credit.

**Live provider responses are not verified.** No Groq, Google, Mistral or
Speechmatics key was available in this environment, and no credit was bought to
obtain one. Before this is called done, a human with existing credit should, for
each provider, save the key, confirm the picker lists the expected voices, speak
a short phrase and confirm the audio plays. Two things in particular can only be
settled that way:

- The Groq model-terms gate, which is invisible until the first synthesis.
- Mistral's preset voice list, whose identifiers are not published anywhere.

## Official contracts

- [Groq text to speech](https://console.groq.com/docs/text-to-speech) and [Orpheus models and voices](https://console.groq.com/docs/text-to-speech/orpheus)
- [Groq deprecations: PlayAI retirement](https://console.groq.com/docs/deprecations)
- [Gemini speech generation](https://ai.google.dev/gemini-api/docs/speech-generation)
- [Gemini Interactions API reference](https://ai.google.dev/api/interactions-api)
- [Mistral text to speech](https://docs.mistral.ai/studio/audio/text_to_speech) and [audio/speech endpoint](https://docs.mistral.ai/api/endpoint/audio/speech)
- [Speechmatics text to speech quickstart](https://docs.speechmatics.com/text-to-speech/quickstart)
