# OpenRouter audio models

The Mac and iPhone use one shared live catalogue for OpenRouter's dedicated
transcription and speech endpoints. Audio chat models remain on their existing
chat route. Direct provider and local models keep their existing settings.

## Choose a model

In Remote Batch transcription settings, open **Browse OpenRouter Audio** (on Mac,
**Browse OpenRouter speech-to-text models**). In voice-output settings, open the
OpenRouter speech browser. Search by name or description, filter by provider, and
inspect model-specific voices, capabilities, retirement dates, and pricing.

Selecting a model updates the normal batch or speech preference. A missing model
remains selected and appears unavailable in the browser; it is never silently
replaced. A provider can still reject a retired model or an unavailable voice.
Use the browser to choose a replacement. Mac dictation profiles have no speech
voice override; they continue to use the app's voice-output default.

Discovery requests only model metadata. It has a six-hour cache, a manual refresh,
and a visible stale-cache fallback during outages. It does not store API keys,
test transcripts, input text, or audio in the catalogue. The existing OpenRouter
key is reused for model requests. No separate provider account is needed in Speak.

## Test before selecting

The model detail screen makes the cloud transfer and possible charges explicit.
Choose an audio file to test transcription, or enter text for a speech preview.
No microphone permission is needed for the file test. Tests do not add content
to History. Cancel or leave the screen to discard results. Preview speech uses
an owned temporary file, removed after playback, interruption, failure, or exit.

Voices come from each model's metadata. When no voices are listed, a user can
enter a provider-documented voice ID or try the provider default. There is no
global copied voice list. An omitted voice can fail if the model requires one.
Requests omit speed rather than assume every model supports that parameter.
The normal speech speed setting adjusts playback locally; exported audio keeps
the provider's original speed.

## Transport and limits

- Dedicated STT uses `/api/v1/audio/transcriptions` with a JSON audio payload.
  Supported file extensions are WAV, MP3, FLAC, M4A, OGG, WebM, and AAC; the local
  upload limit is 25 MiB. Provider-specific limits can be lower.
- Dedicated speech uses `/api/v1/audio/speech` and explicitly requests MP3.
  The client streams bounded chunks to disk, with a 32 MiB response limit.
  Playback starts after the response is complete; progressive playback is not
  implemented in this change.
- Audio requests have a 120-second total deadline, cancellation, redirect refusal,
  private temporary files, bounded JSON responses, and status-only provider errors.
  Input text is limited to 64 KiB; provider limits can be lower.
- Provider-supplied STT cost and duration are retained in the normal result. The
  speech endpoint returns raw bytes without billable cost, so cost stays unknown.
  Catalogue price keys and values are displayed without inventing billing units.

## Verification and remaining work

Offline contract tests cover live-catalogue decoding, cache refresh/failure,
dedicated endpoint classification, selection persistence, credentials, payloads,
sanitised errors, limits, cancellation, and temporary-file ownership. Both native
targets must compile and pass their existing test gates before merge. Paid-provider
acceptance across the changing catalogue is separate from these mocked contracts.

Issue #821 remains open for progressive speech playback, provider-specific cost
enrichment and capability controls, and full real-provider/device qualification.
This change delivers discovery, explicit testing, selection, and normal STT/TTS
routing on both platforms without claiming those remaining checks are complete.

## API references

- [Models API](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
- [Speech to text](https://openrouter.ai/docs/guides/overview/multimodal/stt)
- [Text to speech](https://openrouter.ai/docs/guides/overview/multimodal/tts)

The public catalogue was checked on 5 September 2026 and returned 38 dedicated
audio models. The app deliberately does not hard-code that count or model list.
