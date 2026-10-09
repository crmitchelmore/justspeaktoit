# Azure Speech in Just Speak to It

Azure uses the existing `azure.speech.apiKey` Keychain entry (`key:region`).
No additional paid subscription, credit purchase or automatic top-up is enabled
by this integration. Access to a model depends on the resource's tier and region.

## Available paths

| Path | API | Platform |
| --- | --- | --- |
| Fast recorded-audio transcription | Speech `transcriptions:transcribe`, version `2025-10-15` | macOS, iOS and Windows |
| MAI-Transcribe-2 / 1.5 recorded audio | Same API, with the explicit enhanced-mode model | macOS, iOS and Windows; resource access required |
| Azure Speech / MAI live input | Voice Live, version `2026-04-10`, pre-deployed `gpt-4.1` session | macOS, iOS and Windows; resource endpoint required |
| Azure neural voices, MAI-Voice-2.1 and MAI-Voice-2.1-Flash | Regional synthesis and voices-list APIs | macOS TTS; shared transport and MAI catalogue in SpeakCore |

MAI live input uses Azure's `mai-transcribe` identifier. It is intentionally not
labelled MAI-Transcribe-2: the live API does not promise the same version as the
file API. Voice Live assistant responses are disabled; the client never sends
`response.create`. Live shutdown drains queued audio, commits remaining audio without changing VAD,
then awaits a server acknowledgement and transcription finals within a five-second
overall budget. Azure rejects disabling turn detection after a session has started.
Timeouts return the best available transcript with an error, not a fabricated final.
Leading audio is held in the shared `StreamingAudioPreroll` until Azure's first
`session.updated`, outbound audio waits in a queue bounded by frames and by five
seconds of PCM and is sent one message at a time (a stalled socket is reported as a
transport failure), and a stop that lands during the handshake waits the shared
`StreamingSessionReadiness` budget before committing.
A per-turn `input_audio_transcription.failed` event does not end the session; only a
recording in which every turn failed is reported as a transcription failure. Only an
empty-buffer answer to the client's own final commit is benign: any other server
error, including one that names the commit or the finalisation barrier, ends the
session as a failure.

This does not add a bring-your-own Azure OpenAI deployment. That requires its own
deployment endpoint and authentication contract; an ordinary OpenAI key is never
silently reused for Azure.

## Settings

1. Save the Azure Speech key and region in **API Keys → Azure Speech API Key**.
   This single card shares its credential between transcription and voice output. Existing key-only values
   retain their previous `eastus` fallback; explicit regions are recommended.
2. For Voice Live, paste the HTTPS resource origin from **Keys and Endpoint**
   into **Azure resource endpoint** (on Windows, Settings → Azure Speech resource…).
   Only the documented Azure custom-resource hostnames are accepted. The endpoint is device-local configuration, not a secret.
3. Recorded audio uses the regional Speech endpoint if the resource field is empty.
4. Choose the Azure model under Remote → Batch or Remote → Streaming.
5. On macOS, voice output loads the resource's regional voice list. Conventional
   saved voice IDs are preserved; the original neural voice list remains an
   offline fallback.

### MAI voices

MAI-Voice-2.1 (highest fidelity) and MAI-Voice-2.1-Flash (low latency) were
released on 1 October 2026 and are in public preview on Azure Speech. They use
the same key, regional `cognitiveservices/v1` synthesis endpoint and SSML as
neural voices; the model is the voice-name suffix, for example
`en-US-Harper:MAI-Voice-2.1-Flash`. No new credential or endpoint is needed.

`AzureMAIVoiceCatalog` in SpeakCore is the one definition of the MAI models,
their published prices and eight curated English speakers (Harper, Olivia,
Grant and Ethan in en-US; Emily and Harry in en-GB; Isla in en-AU; Priya in
en-IN), each offered with both models. The macOS picker projects that catalogue.
Microsoft documents both models as globally accessible, with requests routed to
the regions that serve them, so the curated voices are offered even when a
regional voice list omits them. The resource's own list still supplies every
other MAI speaker and locale, and older MAI models it still serves
(MAI-Voice-2, MAI-Voice-1). Speakers such as Harper exist in many locales, so MAI
voices are named with their locale and model, for example
"Harper (en-US, MAI-Voice-2.1)". A saved MAI voice keeps that name offline,
including locales with a script or variant such as `zh-Hans-CN`. A curated
voice that the resource also lists keeps the catalogue's traits (accent,
multilingual, low latency).

Failed synthesis keeps Azure's own response text (whitespace collapsed, at most
300 characters plus an ellipsis, with an exact key echo removed). This diagnostic
can still contain user content and must not be logged. Only when that
text says the voice or model is unavailable does an MAI request report that the
resource cannot use MAI voices; a malformed request is reported as such. Region
coverage is still settling: Microsoft's MAI voice page lists 14 serving regions,
while the region table marks 9.

MAI voice output currently requires normal speed and pitch. Unsupported changes
produce an explicit message. MAI-Voice-2.1 is estimated at $22 and Flash at $15
per million characters; older MAI models have no published rate here and are
shown as unknown rather than using the conventional neural-voice price.
MAI-Transcribe-2 recorded audio is estimated at its $0.10 per hour launch price,
which Microsoft offers only until 31 December 2026. The pricing table is
maintained by hand: replace that rate when Microsoft publishes the standard
price. MP3 output requested through the M4A preference
is saved with an MP3 extension, matching Azure's actual response container.
Conventional voice prosody uses signed relative values (`+0%`, `+0st`);
Azure rejects the unsigned zero values previously sent by the app.

## Verification

### Local Entra proxy (batch/live transcription and TTS)

`scripts/azure-speech-proxy.py` is a dependency-free Python 3 bridge for
subscriptions that disable Azure resource keys. Sign in with `az login` and
grant the signed-in account **Cognitive Services Speech User** on the resource.
The proxy uses Azure CLI's Speech-scoped Entra token, caches it in memory and
refreshes it before expiry. It does not create an app registration, save an
Entra token or change subscription authentication policies.

Start it with an explicit subscription and custom resource endpoint:

```bash
python3 scripts/azure-speech-proxy.py \
  --subscription YOUR_SUBSCRIPTION_ID \
  --resource https://YOUR_RESOURCE.cognitiveservices.azure.com \
  --token-file /path/to/private-directory/azure-proxy-token \
  --port 8765
```

The parent directory must already exist. The token file is created with mode
`600` and reused on restart. It is a local client credential, **not an Azure API
key**. Keep it out of source control. Native clients send its value in
`Ocp-Apim-Subscription-Key` for HTTP or `api-key` for WebSocket upgrades; both
headers are consumed locally and never forwarded. Azure receives an Entra bearer
token and the fixed inference request, never the local token.
Do not omit the local token: loopback alone does not prevent another
local process or a browser from attempting to spend your Azure quota.

This is a **trusted-machine development tool**, not a security boundary against
malicious local software. Plaintext loopback does not authenticate the server:
another process occupying the configured port could receive the local token and
recording. A health response checks compatibility, not server identity. Start the
intended proxy before configuring the app, keep the token private, and do not use
this transport on an untrusted/shared host. It never exposes an Entra token to the
app. Capture, resampling and local-model inference remain native and in-process;
only explicitly selected Azure cloud requests use this user-operated relay.

Only these native-client routes are accepted:

| Local route | Upstream route |
| --- | --- |
| `POST /cognitiveservices/v1` | `/tts/cognitiveservices/v1` |
| `GET /cognitiveservices/voices/list` | `/tts/cognitiveservices/voices/list` |
| `POST /speechtotext/transcriptions:transcribe?api-version=2025-10-15` | Same path and pinned API version |
| WebSocket `/voice-live/realtime?api-version=2026-04-10&model=gpt-4.1` | Same route on the resource's `.services.ai.azure.com` host |
| `GET /health` | Local readiness only; does not verify Azure model access |

Synthesis uses the existing Azure SSML body and `X-Microsoft-OutputFormat`
header. It supports the app's current MP3 and WAV formats. The server binds only
to `127.0.0.1`, requires the exact Host header and local token, rejects browser
requests, redirects, external SSML audio/lexicon references and arbitrary
forwarding targets, and bounds request size, response size and concurrency.
It never logs tokens, SSML or Azure response bodies. Errors are explicit;
expired sign-in requires `az login` again. All inference still uses the selected
corporate identity, subscription, permissions and applicable policies.

Recorded-audio transcription forwards the app's multipart WAV and definition
unchanged. The proxy accepts Fast Transcription, MAI-Transcribe-2 and 1.5, optional
locales and phrase lists; uploaded WAV files only, never audio URLs. Multipart
uploads are limited to 32 MiB. Unsupported models, options and oversized uploads
are rejected explicitly. Azure error status codes are preserved for bad inputs,
authentication and rate limits without returning provider bodies that might
contain recordings or credentials.
Uploads have a 30-second total receive deadline; upstream response bodies have
a 180-second total deadline. Saturated admission returns HTTP 503. The app checks
the complete multipart size before constructing or sending an oversized upload.

Voice Live tunnels native WebSocket frames over certificate-validated TLS to the
same resource's Foundry host. It preserves the existing shared client's readiness,
audio ordering and finalisation protocol, with text-only transcription and no
assistant responses. The tunnel has a 60-second idle limit, one-hour session
limit, 256 MiB upload limit and 64 MiB download limit; four concurrent HTTP/live
connections share the proxy's admission limit. A failed upgraded tunnel closes
with WebSocket error 1011 rather than returning an HTTP-shaped success.

**Builds containing the local-proxy changes can use it for batch and live transcription:**

1. Set **Azure resource endpoint** to `http://127.0.0.1:8765`.
2. In **API Keys → Azure Speech API Key**, save `local-proxy/` followed by the value
   of the private token file. This is the local proxy credential, not an Entra
   token or Azure key; the existing Azure credential slot is used. It replaces
   that build's Azure credential, so retain your direct Azure key separately if
   you plan to switch back. Save the endpoint before validating the token.
   Both saving and **Check Validity** use the local `/health` route for proxy
   credentials, never the regional TTS route. A successful save confirms local
   proxy compatibility for transcription only, not Azure model access or TTS support.
3. Select **Remote → Batch → Azure MAI-Transcribe-2 (Preview)**, or Azure Fast
   Transcription, for recorded audio. For live transcription select
   **Remote → Streaming → Azure MAI Transcribe (Voice Live, Preview)** or Azure Speech.

Only the literal IPv4 loopback origin with an explicit port is allowed; enter
`127.0.0.1`, not `localhost`, a LAN address, a path or a query. The shared transcription
clients require the `local-proxy/` credential prefix before sending anything to
loopback and strips it from the local request header. An ordinary Azure key is
never sent to the proxy, and a proxy credential is never sent to Azure.
Direct Azure HTTPS endpoint validation is unchanged. Direct TTS still rejects
proxy credentials; the app's TTS settings do not route through this endpoint.

**Previously installed Alpha builds still reject loopback endpoints; an app
update containing these changes is required.** No installed app or saved
credentials are modified by running the script. Voice output in the app still
uses its regional endpoint; the proxy's TTS routes remain usable by standalone
native clients. This proxy implements the existing Voice Live `mai-transcribe`
model, **not MAI-Transcribe-2-Streaming**. The latter is a separate deployment/API
at `/mai/v1/realtime` with a different session and event contract.
No TLS interception, Entra app registration or API-key policy exemption is needed.

Run the offline proxy checks with:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_azure_speech_proxy.py' -v
```

`AzureLocalProxyTests` runs the actual shared batch client against a stub to
check credential isolation and multipart model selection. Its opt-in live test
uses `JSTI_AZURE_PROXY_TOKEN_FILE`, `JSTI_AZURE_TEST_ENDPOINT` and
`JSTI_AZURE_TEST_WAV` (a synthetic canonical 16 kHz PCM16 mono WAV containing
"the quick brown fox jumps over the lazy dog"). With those explicitly configured,
run `SPEAK_PORTABLE_CORE=1 swift test --filter AzureLocalProxyTests`; otherwise
the batch check is skipped and CI never reads credentials or spends Azure quota.
Set `JSTI_AZURE_PROXY_STREAMING=1` as well to opt into the real shared Voice Live
client check. It sends the synthetic fixture in paced 100 ms PCM chunks, requires
live text before stopping and the full expected final phrase without errors,
and checks both `mai-transcribe` and `azure-speech`.
Preserve `Package.resolved` when switching to the dependency-free portable graph.

On 7 October 2026, the loopback proxy returned HTTP 200 and valid WAV and MP3
audio for both `en-US-Harper:MAI-Voice-2.1` and
`en-US-Harper:MAI-Voice-2.1-Flash`, using a fixed synthetic phrase. Voice listing
returned 958 entries. Incorrect local tokens returned 401 and browser-origin
requests returned 403. These receipts verify native HTTP requests through the
proxy, not integration with the installed app.

The upgraded proxy also transcribed a synthetic "the quick brown fox jumps over
the lazy dog" recording through Fast Transcription, MAI-Transcribe-2 and
MAI-Transcribe-1.5, each returning HTTP 200 and the complete expected phrase.
The compiled shared `AzureBatchTranscriptionClient` separately passed the
opt-in loopback test with Fast Transcription and MAI-Transcribe-2. The macOS app
compiled with the endpoint/credential changes; the installed Alpha application
was not replaced or configured by these checks.

The streaming proxy then passed the compiled shared `AzureVoiceLiveClient` check
for both `mai-transcribe` and `azure-speech` on the same Entra-authenticated
resource. Both produced live text before finalisation and retained the complete
synthetic phrase through stop, without client errors. Fast and MAI-Transcribe-2
batch requests passed again on the upgraded server. These are real client/proxy
receipts, not installed-Alpha microphone acceptance or proof of the dedicated
MAI-Transcribe-2-Streaming API.

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
acceptance remain separate release gates. The live-input receipts predate the
shared portable Voice Live client that macOS, iOS and Windows now use; its newer
Entra/loopback receipt is recorded above.

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
- [MAI-Voice-2.1 and Flash launch and pricing](https://microsoft.ai/news/our-first-streaming-transcription-model)
- [MAI-Transcribe-2 launch pricing](https://microsoft.ai/news/mai-transcribe-2)
- [Speech regions, including MAI voices and MAI-Transcribe](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/regions)
