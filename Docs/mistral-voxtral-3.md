# Mistral Voxtral 3

The 20 October 2026 models are explicit **public-preview** choices. Existing
Voxtral 2 selections and defaults remain unchanged. All direct Mistral models
reuse the existing `mistral.apiKey` credential; OpenRouter is not involved.

| Choice | API model | Published estimate |
| --- | --- | --- |
| Mini file transcription | `voxtral-mini-transcribe-3-0` | $0.0035/min |
| Small file transcription | `voxtral-small-transcribe-3-0` | $0.004/min |
| Live transcription | `voxtral-mini-transcribe-realtime-3-0` | $0.008/min |
| Speech generation | `voxtral-mini-tts-3-0` | $16/million characters |

File and live transcription appear in their respective shared model pickers.
Mac voice output exposes a Mistral model picker; select TTS 3 there explicitly.
The existing voice library and selected voice are reused. Emotion and pace tags
may be included in input text; free-form style instructions are unavailable at
launch. The app continues to reject unsupported numeric speed, pitch and SSML.
The desktop host retains its existing pinned voice-output model policy.

Live transcription uses 16 kHz mono PCM16 with the existing 480 ms delay. Its
initial session configuration precedes audio. Stopping drains admitted audio,
sends the model's end sequence, and waits for the authoritative complete text.
The app does not opt in to v3 turn detection, realtime diarization or speaker
references. Language detection remains automatic for live transcription.
Batch vocabulary hints use `context_bias`; no word timestamps are requested.
A file response arriving progressively remains a file transcription operation,
not a live microphone model. Realtime TTS is outside the current file playback
architecture and is not offered.

## Sources and verification limits

- [Migration and aliases](https://docs.mistral.ai/studio/audio/migrate-from-voxtral-2)
- [Mini model and price](https://docs.mistral.ai/models/voxtral-mini-transcribe-3-0)
- [Small model and price](https://docs.mistral.ai/models/voxtral-small-transcribe-3-0)
- [Realtime model and price](https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-3-0)
- [Realtime wire lifecycle](https://docs.mistral.ai/studio/audio/speech-to-text/transcribe-in-realtime)
- [TTS model and price](https://docs.mistral.ai/models/voxtral-mini-tts-3-0)
- [TTS request/response](https://docs.mistral.ai/studio/audio/text-to-speech/quickstarts/generate-speech)

These contracts were checked on 20 October 2026. Provider contract tests use
synthetic credentials/audio and injected transports. Actual account access,
provider inference, microphone/device behavior and installed-release delivery
are separate gates; catalogue presence does not prove any of those outcomes.
