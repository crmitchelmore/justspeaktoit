# Batch transcription providers

File (batch) transcription for Cartesia, Gladia, Speechmatics, Smallest AI,
Reson8 and StepFun. Existing streaming identifiers and saved live selections
are untouched. Reson8 also adds a genuine live route; Pulse Pro and StepAudio 3
remain batch-only. Nothing here changes Text-to-Speech.

| Catalogue ID | Picker name | Credential | macOS | iOS |
| --- | --- | --- | --- | --- |
| `cartesia/ink-whisper` | Cartesia Ink Whisper (Batch) | `cartesia.apiKey` | yes | yes |
| `gladia/solaria-1` | Gladia Solaria-1 (Batch) | `gladia.apiKey` | yes | yes |
| `speechmatics/enhanced` | Speechmatics Enhanced (Batch) | `speechmatics.apiKey` | yes | no |
| `speechmatics/standard` | Speechmatics Standard (Batch) | `speechmatics.apiKey` | yes | no |
| `smallest/pulse-pro` | Smallest AI Pulse Pro | `smallest.apiKey` | yes | yes |
| `reson8/resonant-1` | Reson8 Resonant-1 | `reson8.apiKey` | yes | yes |
| `stepfun/stepaudio-3-asr-max` | StepFun StepAudio 3 ASR Max | `stepfun.apiKey` | yes | yes |

## Pulse Pro, Reson8 and StepAudio 3

The three direct file routes share `FileSpeechBatchClient` in SpeakCore and are
also wired into the portable desktop host. Their separate credentials appear in
API Keys and explicit encrypted configuration transfer; existing model choices
and defaults are unchanged. Requests use fixed official origins and refuse all
redirects, cap the response at 8 MiB, time out after 120 seconds, and cancel
the transport when the calling task is cancelled. The app caps these
in-memory file uploads at **25 MiB** (an app safety bound, not a claimed vendor
limit). Source recordings are never deleted by these clients.

- **Pulse Pro**: `POST https://api.smallest.ai/waves/v1/stt/?model=pulse-pro`,
  Bearer authorization, raw recording bytes, word timestamps. English only:
  Automatic sends `en`; an explicitly selected non-English language fails
  before upload. The official Standard plan is $0.004/minute. Successful empty
  transcripts stay empty. Supported encoded containers include the app's WAV
  and M4A recordings; headerless PCM requires metadata and is not accepted here.
- **Reson8**: `POST https://api.reson8.dev/v1/speech-to-text/prerecorded`,
  `Authorization: ApiKey`, raw recording bytes, word timings in milliseconds.
  Automatic omits the language hint; supported explicit codes are `de`, `en`,
  `es`, `fr`, `fy`, `it`, `nl`, `pl`, `pt`, `sv`. Unsupported hints fail before
  upload. The public API currently exposes **no base-model selector**:
  `reson8/resonant-1` is the app's stable selection identifier for the
  provider-served engine, not an on-wire guarantee of a pinned model version.
  No guessed `model` query is sent and no unverified price is displayed.
- **StepAudio 3**: `POST https://api.stepfun.com/v1/audio/asr/sse`,
  Bearer authorization, JSON containing one base64-encoded recording and
  `audio.input.transcription.model=stepaudio-3-asr-max`. Supports WAV, M4A,
  MP3 and OGG containers. The SSE `transcript.text.done` text is authoritative;
  EOF without done or an `error` event fails instead of returning partial text
  as success. Corrected final text discards stale delta timings. This is
  **recorded audio**, not live microphone streaming, so no StepAudio entry is
  added to the live picker. Published pricing is **2.8 CNY/hour**; history keeps
  CNY and the USD comparison deliberately leaves it unknown.

Reson8 also has a genuine live route, `reson8/resonant-1-streaming`, on macOS,
iOS and shared native desktop hosts. `Reson8LiveClient` opens
`wss://api.reson8.dev/v1/speech-to-text/realtime` with PCM16 mono configuration
and header-only ApiKey authorization. Audio waits for the real handshake; at
most five seconds/256 frames are admitted, with one send in flight. Interims
replace the current hypothesis (including retractions), while timestamped
finals retain genuine repeated utterances. Stop drains admitted PCM, sends one
correlated `flush_request`, and requires its `flush_confirmation` within a
five-second whole-finish budget. Timeout, stalled sends or early closure report
an error before releasing confirmed text as recovery material. Cancellation,
replacement sessions and late callbacks cannot affect a new run.

Official contracts checked 2026-10-13:
[Pulse Pro quickstart](https://docs.smallest.ai/models/speech-to-text/pre-recorded/quickstart),
[model card](https://docs.smallest.ai/model-cards/speech-to-text/pulse-pro),
[audio formats](https://docs.smallest.ai/models/speech-to-text/pre-recorded/audio-formats),
[Reson8 prerecorded](https://docs.reson8.dev/api/speech-to-text/prerecorded.md),
[realtime](https://docs.reson8.dev/api/speech-to-text/realtime.md),
[languages](https://docs.reson8.dev/speech-to-text/features/languages/),
[Resonant-1 announcement](https://www.reson8.dev/blog/benchmarks),
[StepFun SSE](https://platform.stepfun.com/docs/zh/api-reference/audio/asr-sse.md),
[pricing](https://platform.stepfun.com/docs/zh/guides/pricing/details.md).

**No billable provider calls were made.** Request/parsing/lifecycle tests use
synthetic credentials and fake HTTP/WebSocket transports. Real account access,
vendor engine selection, accuracy, and Windows/Linux native microphone/provider
receipts remain release acceptance checks, not claims established by unit tests.

Cartesia, Gladia and Speechmatics issue **one account key** covering realtime
and batch, so their batch entries reuse the Keychain item the live provider
already stores. No extra
endpoint, region, deployment or scope field is introduced. A saved key is never
treated as proof of entitlement: the batch call is what establishes access, and
an account without batch access surfaces the provider's own rejection.

## Shapes

`Sources/SpeakCore/BatchTranscriptionJob.swift` holds what the asynchronous job
APIs share: the on-disk multipart snapshot (the recording is copied in 64 KiB
chunks and never held in memory), the polling loop, cancellation checks, the
non-2xx rejection, and the credential boundary. Cartesia's `/stt` endpoint answers in one round trip and keeps
its own single-shot client.

A non-2xx response becomes `TranscriptionProviderError.httpError(status, body)`,
which is the vocabulary the rest of the app already renders: the iOS routes
re-map it to `IOSBatchTranscriptionError.httpError` with the provider name.
Authentication (401, 403) and quota (402, 429) failures therefore reach the user
as the provider's own message rather than a flattened generic string.

### Cartesia — `CartesiaBatchClient`

`POST https://api.cartesia.ai/stt`, multipart, `Authorization: Bearer`,
`Cartesia-Version` header, model `ink-whisper`. One request, one response. The
documented language default is English, so "Automatic" sends no language field.

### Gladia — `GladiaBatchClient`

Three steps against `https://api.gladia.io`, all authenticated with the
`x-gladia-key` header:

1. `POST /v2/upload` with the recording in the `audio` part → `audio_url`.
2. `POST /v2/pre-recorded` with `{audio_url, model: "solaria-1", language_config}`
   → `{id, result_url}`. "Automatic" sends an empty `languages` array with
   `code_switching: true`, which is Gladia's documented way to ask for detection.
3. Poll `result_url`. `queued` and `processing` keep polling; `done` yields
   `result.transcription.full_transcript` plus per-utterance timings; `error`
   fails immediately. An unrecognised status is treated as still running, so a
   new intermediate state cannot abort a job that would have succeeded.

`result_url` arrives inside a provider response and is polled with the account
key attached, so it is only honoured while it stays on the configured Gladia
origin (scheme, host and effective port). An off-origin `result_url` is
discarded in favour of the documented `<baseURL>/v2/pre-recorded/{id}` endpoint,
and a response offering neither is an invalid response. Redirects are held to
the same boundary: `x-gladia-key` is a custom header, so URLSession would carry
it across a cross-origin hop that `Authorization` would not survive.

Once Gladia has accepted a job it bills until the job finishes, so every path
that abandons one -- cancellation in either spelling, and the local polling
deadline -- issues a best-effort `DELETE /v2/pre-recorded/{id}`. The delete runs
detached, because the usual reason to be making it is that the surrounding task
is already cancelled and URLSession would fail the request before it left the
device.

### Speechmatics — `SpeechmaticsBatchClient`

Three steps against `https://eu1.asr.api.speechmatics.com` — the same regional
host the existing key validator probes — with `Authorization: Bearer`:

1. `POST /v2/jobs`, multipart, with a `config` JSON part and the recording in
   `data_file` → `{id}`. `operating_point` carries the tier (`enhanced` or
   `standard`); Speechmatics also accepts the newer `model` field for these
   values. "Automatic" sends `language: "auto"`.
2. Poll `GET /v2/jobs/{id}`. `running` and `queued` keep polling; `done`
   proceeds; `rejected`, `deleted` and `expired` fail immediately with the job's
   own error message.
3. `GET /v2/jobs/{id}/transcript?format=json-v2`. Word items become timed
   segments; punctuation is appended to the word its `attaches_to` names and
   never becomes a segment of its own.

Cancelling issues a best-effort `DELETE /v2/jobs/{id}?force=true`.

## Platform restriction: Speechmatics batch is macOS-only

The iOS app now stores `speechmatics.apiKey` — the Speechmatics live provider
added the field and its API-keys row — so the credential is no longer what
holds the batch entries back. What does is the upload path:
`IOSBatchTranscriptionRoute` has no Speechmatics case, so a visible entry would
fall through to the OpenRouter route and send the audio to the wrong service.
The batch entries are therefore filtered out of the iOS Batch picker.
`PlatformFeatureVisibilityTests.testSpeechmaticsBatchIsHiddenOnIOSBecauseThereIsNoUploadRoute`
pins that behaviour. Lifting the restriction means adding a `.speechmatics`
route and its `transcribeWithSpeechmatics` client call, at which point the
filter line and that test change together.

Cartesia and Gladia are wired on both platforms:
`IOSBatchTranscriptionRoute` sends each identifier to its own shared client, and
`ModelCredentialResolver` resolves the provider's own key rather than the
OpenRouter fallback.

## Verification status

Request construction, job-state handling, cancellation (including the
provider-side job delete on every abandonment path), the Gladia credential
boundary, authentication and quota failures, silent-recording finalisation and
transcript parsing are covered by
`Tests/SpeakCoreTests/GladiaBatchClientTests.swift`,
`Tests/SpeakCoreTests/GladiaBatchClientSecurityTests.swift`,
`Tests/SpeakCoreTests/SpeechmaticsBatchClientTests.swift`,
`Tests/SpeakCoreTests/SpeechmaticsBatchClientLifecycleTests.swift`,
`Tests/SpeakCoreTests/BatchTranscriptionJobTests.swift` and
`Tests/SpeakCoreTests/CartesiaBatchClientTests.swift`, against recorded response
shapes taken from the published API references.

Nothing here has been exercised against a live Gladia or Speechmatics account:
there are no credentials for either provider, so the wire shapes are those of
the published references and the origin and redirect constraints are verified
against the documented endpoints rather than observed traffic. If Gladia ever
serves `result_url` from a host other than the configured base URL, the client
will fall back to the job-id endpoint rather than follow it.

**Not yet verified against live provider responses.** No Gladia or Speechmatics
credit was available when this landed, so the Gladia and Speechmatics request and
response shapes above are implemented from the documentation rather than
confirmed by a real job. Before relying on either in a release, run one short
recording through each with a real key and confirm: the upload/job-creation
response fields, the terminal status strings, and the transcript payload keys.
