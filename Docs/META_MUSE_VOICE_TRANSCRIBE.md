# Meta Muse Voice Transcribe

Just Speak to It uses Meta Model API's dedicated speech-to-text contract for
Muse Voice Transcribe 1.0. It does not route audio through Muse Spark text
inference.

## Supported paths

- **Live:** `wss://api.meta.ai/v1/asr/realtime`. The app sends a JSON handshake,
  followed by mono signed PCM16 at 24 kHz in binary frames. It uses
  `ENDPOINTING`; partial `transcript` events update the live display and only
  `speechComplete` finalises an utterance. Stopping sends `endStream` and drains
  final events before closing.
- **File:** `POST https://api.meta.ai/v1/asr/transcribe`. Imported and recorded
  audio is converted locally to mono signed PCM16 WAV at 16 kHz, then uploaded
  as multipart fields named `request` and `audio`.

File requests are limited by Meta to 10 minutes and a 32 MB request body.
Realtime sessions retry once when a transient transport/backend failure occurs
before the handshake is accepted. Policy failures, authentication failures,
rate limits, malformed events, and later backend failures are surfaced without
silently switching providers.

## Language and vocabulary bias

The app maps its preferred spoken language to Meta's language-name hint and
supports the 25 languages Meta lists as validated:

Arabic, Bengali, Dutch, English, French, German, Hebrew, Hindi, Indonesian,
Italian, Japanese, Kannada, Korean, Malay, Mandarin Chinese, Marathi, Polish,
Portuguese, Spanish, Tagalog, Tamil, Telugu, Thai, Turkish, and Vietnamese.

Automatic detection remains active when no supported language is selected.
Recognition keywords can contain up to 100 comma- or newline-separated names,
places, acronyms, or domain terms. Biasing is a hint and does not force output.

## Current representation limits

Meta exposes diarisation and speaker labels, but Just Speak to It's normal live
dictation result has no speaker-labelled transcript representation. The app
therefore uses endpointing rather than exposing a misleading diarisation toggle.
Batch turn timestamps are preserved as transcript segments. Meta does not
provide word-level timestamps, confidence scores, sound events, emotion labels,
or transcript reformatting on this API.

API keys are stored under `meta.apiKey` in the Keychain. Validation probes the
speech-to-text endpoint itself with 80 ms of silent PCM WAV so a Muse Voice Transcribe
permission problem is detected during onboarding rather than at first recording.

Sources: [Meta speech-to-text guide](https://dev.meta.ai/docs/speech-to-text/) and
[Voice API reference](https://dev.meta.ai/docs/api-reference/voice).
