# Batch transcription providers: Cartesia, Gladia, Speechmatics

File (batch) transcription for three providers that previously only had a live
streaming path. Each is a **Batch** picker entry only — nothing here changes the
Streaming or Text-to-Speech pickers, and the existing streaming identifiers are
untouched, so a user's saved live selection is preserved.

| Catalogue ID | Picker name | Credential | macOS | iOS |
| --- | --- | --- | --- | --- |
| `cartesia/ink-whisper` | Cartesia Ink Whisper (Batch) | `cartesia.apiKey` | yes | yes |
| `gladia/solaria-1` | Gladia Solaria-1 (Batch) | `gladia.apiKey` | yes | yes |
| `speechmatics/enhanced` | Speechmatics Enhanced (Batch) | `speechmatics.apiKey` | yes | no |
| `speechmatics/standard` | Speechmatics Standard (Batch) | `speechmatics.apiKey` | yes | no |

Every provider issues **one account key** covering realtime and batch, so each
batch entry reuses the Keychain item the live provider already stores. No extra
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

## Platform restriction: Speechmatics is macOS-only

The iOS app has no Speechmatics credential field — `AppSettings` stores no
`speechmatics.apiKey`, matching the existing treatment of the Speechmatics live
entry. The batch entries are therefore filtered out of the iOS Batch picker
rather than shown as options that could never resolve a key.
`PlatformFeatureVisibilityTests.testSpeechmaticsBatchIsHiddenOnIOSBecauseThereIsNoCredentialField`
pins that behaviour; lifting the restriction means adding the key field to
`AppSettings` and its API-keys screen, at which point the filter line and that
test change together.

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
