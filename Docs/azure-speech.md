# Azure Speech in Just Speak to It

Azure uses the existing `azure.speech.apiKey` Keychain entry (`key:region`).
No additional paid subscription, credit purchase or automatic top-up is enabled
by this integration. Access to a model depends on the resource's tier and region.

## Available paths

| Path | API | Platform |
| --- | --- | --- |
| Fast recorded-audio transcription | Speech `transcriptions:transcribe`, version `2025-10-15` | macOS and iOS |
| MAI-Transcribe-2 / 1.5 recorded audio | Same API, with the explicit enhanced-mode model | macOS and iOS; resource access required |
| Azure Speech / MAI live input | Voice Live, version `2026-04-10`, pre-deployed `gpt-4.1` session | macOS and iOS; resource endpoint required |
| Azure neural and available MAI voices | Regional synthesis and voices-list APIs | macOS TTS; shared transport and voice descriptors in SpeakCore |

MAI live input uses Azure's `mai-transcribe` identifier. It is intentionally not
labelled MAI-Transcribe-2: the live API does not promise the same version as the
file API. Voice Live assistant responses are disabled; the client never sends
`response.create`. Live shutdown drains queued audio, commits remaining audio without changing VAD,
then awaits a server acknowledgement and transcription finals within a five-second
overall budget. Azure rejects disabling turn detection after a session has started.
Timeouts return the best available transcript with an error, not a fabricated final.
Leading audio is held in the shared `StreamingAudioPreroll` until Azure's first
`session.updated`, outbound audio is bounded by the shared `StreamingAudioSendBudget`
(a stalled socket is reported as a transport failure), and a stop that lands during
the handshake waits the shared `StreamingSessionReadiness` budget before committing.
A per-turn `input_audio_transcription.failed` event does not end the session; only a
recording in which every turn failed is reported as a transcription failure.

This does not add a bring-your-own Azure OpenAI deployment. That requires its own
deployment endpoint and authentication contract; an ordinary OpenAI key is never
silently reused for Azure.

## Settings

1. Save the Azure Speech key and region in API Keys. Existing key-only values
   retain their previous `eastus` fallback; explicit regions are recommended.
2. For Voice Live, paste the HTTPS resource origin from **Keys and Endpoint**
   into **Azure resource endpoint**. Only the documented Azure custom-resource
   hostnames are accepted. The endpoint is device-local configuration, not a secret.
3. Recorded audio uses the regional Speech endpoint if the resource field is empty.
4. Choose the Azure model under Remote → Batch or Remote → Streaming.
5. On macOS, voice output loads the resource's regional voice list. MAI-Voice-2
   and Flash appear only if returned by Azure. Conventional saved voice IDs are
   preserved; the original neural voice list remains an offline fallback.

MAI voice output currently requires normal speed and pitch. Unsupported changes
produce an explicit message. MAI costs are shown as unknown rather than using the
conventional neural-voice price. MP3 output requested through the M4A preference
is saved with an MP3 extension, matching Azure's actual response container.
Conventional voice prosody uses signed relative values (`+0%`, `+0st`);
Azure rejects the unsigned zero values previously sent by the app.

## Verification

Contract tests cover endpoint validation, secret-free URLs, multipart model
selection, timing conversion, empty input, SSML escaping, MAI voice identity,
streaming transcript ordering/deduplication and shared routing/credentials.

`AzureSpeechIntegrationTests` is opt-in: supply `JSTI_AZURE_TEST_CREDENTIAL` and
`JSTI_AZURE_TEST_WAV` only in the test process environment, then run
`swift test --filter AzureSpeechIntegrationTests`. CI does not read Keychain or
spend provider credits. Use synthetic audio, never personal recordings.

The September 2026 UK South account probe returned a successful Fast Transcription
result. The compiled shared client also transcribed the fixture, and existing
Sonia neural synthesis returned valid WAV audio after the prosody correction.
The resource voice list contained 556 voices and no MAI voices. An explicit MAI-2
file request returned HTTP 400 (`Enhanced mode with model is currently not supported yet`).
This is an access/region limitation, not evidence of successful MAI inference.
The original UK South resource remains unchanged. No region/tier upgrade was performed.

On 10 September, the existing East US Foundry resource on the trial subscription
passed compiled Fast Transcription, MAI-Transcribe-2 and 1.5, neural WAV synthesis
and MAI-Voice-2 WAV synthesis checks. Azure Speech and MAI live input both returned
the expected synthetic phrase, including its trailing words after finalisation.
The portal reported GBP 143.42 trial credit remaining before these tests.
The trial exposed `turn_detection_type_change_not_allowed` during shutdown;
finalisation now retains VAD and waits for the commit/configuration acknowledgement
and pending transcription finals. All five opt-in tests pass on the corrected client.
These are compiled-client checks; installed-app microphone routing and iOS device
acceptance remain separate release gates.

For extended tests, set `JSTI_AZURE_TEST_EXTENDED=1`, the custom resource origin
in `JSTI_AZURE_TEST_ENDPOINT`, and a mono signed 16-bit little-endian 24kHz PCM
fixture in `JSTI_AZURE_TEST_PCM`, in addition to the credential and WAV above.
The synthetic WAV and PCM must say "the quick brown fox". Extended tests are
skipped without explicit configuration and never obtain credentials themselves.

## Official contracts

- [Fast transcription SDK and regional endpoint](https://learn.microsoft.com/en-us/dotnet/api/overview/azure/ai.speech.transcription-readme?view=azure-dotnet)
- [MAI transcription](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe)
- [Voice Live authentication, events and input transcription](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-how-to)
- [MAI voice names and synthesis](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-voices)
