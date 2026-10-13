# Alibaba Model Studio transcription

## Supported routes

| Selection | Wire model | Path | Limits |
| --- | --- | --- | --- |
| Alibaba Fun-ASR-Flash (June 2026) | `fun-asr-flash-2026-06-15` | Synchronous DashScope recorded audio | 5 minutes; Beijing or Singapore |
| Alibaba Fun-ASR (Streaming) | `fun-asr-realtime` | Genuine duplex WebSocket PCM ASR | Beijing or Singapore; automatic language detection |
| Alibaba Qwen3.5-Omni-Plus | `qwen3.5-omni-plus` | Recorded audio, Chat Completions text SSE | 3 hours; Beijing or Singapore |
| Alibaba Qwen3.8-Omni-Flash | `qwen3.8-omni-flash` | Recorded audio, Chat Completions text SSE | 3 hours; all six configured regions |

macOS and iOS use the same `SpeakCore` catalogue, wire clients and secure
credential. Windows/Linux pickers deliberately exclude these routes: their
native hosts have not qualified the Alibaba configuration UI and transport.
Unsupported desktop requests fail explicitly, never through OpenRouter.

All recorded routes currently accept **local inline files only**, up to
7,499,997 bytes (encoded Base64 smaller than 10 MB). WAV, MP3, M4A, AAC, AMR,
Ogg, Opus and FLAC are accepted; native Apple decoding also must succeed.
There is no automatic compression, splitting, public upload or different-model
fallback. Large recordings must be split or use another explicitly selected
provider. The longer asynchronous `fun-asr` service needs a publicly reachable
audio URL; it is not offered because the app records private local files.

Qwen Omni is general audio understanding prompted for verbatim transcription,
not a dedicated ASR endpoint. Its SSE is text output for a **finished recording**,
not a claim of live audio transcription. Qwen3.8 thinking is explicitly disabled;
only content deltas are inserted, never reasoning or generated speech. A `stop`
finish reason is required; truncated, filtered or length-limited output fails
instead of presenting a partial result as complete. Digitally silent recordings
are handled locally without sending audio or generating placeholder text.

## Configuration and credential boundary

In API Keys, choose **Alibaba workspace for new keys**, choose the region, enter
the workspace ID (for example `llm-...`), then save the matching regional key in
the Alibaba Model Studio key row. Copy the workspace ID from Alibaba's console,
not its full URL. The key must have access to that workspace and selected model.
Saving checks configuration locally; authorization, entitlement and quota are
checked on the actual transcription request, not by a billable validation probe.

The encrypted `alibaba.apiKey` item contains a JSON object with `region`,
`workspace` and `apiKey`. QR transfer and passphrase-encrypted key sync transfer
this entire value, so importing a Singapore key cannot quietly pair it with a
Beijing preference. New-key form preferences are only input drafts: changing
them does not change a saved credential. Save a replacement key to change
workspaces or regions.

Large QR transfers use a bounded authenticated compressed envelope and require
updated software on both devices. See [configuration transfer](configuration-transfer.md)
for compatibility, the physical QR limit and explicit oversized-transfer errors.

Only `https://{workspace}.{region}.maas.aliyuncs.com` and its corresponding `wss`
origin are constructed. Workspace IDs must be a single DNS label; URLs, paths,
ports, userinfo, `trial` and host substitution are rejected. HTTPS redirects
must remain on the exact origin. DashScope legacy domains and trial domains
are intentionally unsupported; the provider recommends workspace domains and
stopped adding new features to legacy DashScope domains on September 30, 2026.
Keys are region-specific; the client does not attempt to infer a key's region
and never retries another region. A server rejection reaches the user.

Endpoint region determines access/data storage, while the Alibaba console's
workspace **deployment range** determines inference location. A Frankfurt
endpoint alone is not a guarantee of EU-only inference.

Fun-ASR uses automatic language detection in recorded and live modes. No
undocumented language fields or contextual formatting prompt are sent. Qwen
Omni gets the selected language as a prompt hint, omitting Automatic; it is
instructed to preserve the spoken language and never translate or answer the
recording. Existing post-transcription processing remains separate.

## Live contract

The shared client sends `run-task`, waits for `task-started`, then sends binary
16 kHz mono PCM16. A five-second/256-frame admission bound reports stalled
transport rather than dropping audio. Sends are single-flight and ordered.
Partials replace the sentence identified by `sentence_id` (or documented
`begin_time` when no sentence ID is supplied), including empty retractions.
Final sentence corrections replace that identity; genuine repeated utterances
at new identities are kept. Authoritative snapshots feed the native hosts.

Finish drains admitted PCM, sends `finish-task` and waits for `task-finished`
inside one five-second budget. Closure, an unfinished sentence or timeout is
an error; locked text is returned only for recovery. Cancellation tears down
immediately, resumes waiting finish calls and does not reconnect. Late callbacks
and deadlines are scoped to their original run.

## Source evidence and migration decisions

Primary documentation read October 13, 2026:

- [ASR model overview](https://help.aliyun.com/zh/model-studio/asr-model):
  distinguishes recorded Fun-ASR-Flash, long-file Fun-ASR and genuine Fun-ASR
  WebSocket models. Some overview tables render snapshot separators oddly;
  the dedicated model page supplies the actual hyphenated API model ID.
- [Fun-ASR-Flash model](https://help.aliyun.com/zh/model-studio/fun-asr-flash):
  explicitly identifies `fun-asr-flash-2026-06-15` and its five-minute limit.
- [Recorded ASR guide](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide):
  Flash synchronous multimodal-generation input and `output.text` /
  `output.output.sentence.text` response, unlike the async public-URL service.
- [Realtime ASR guide](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide):
  duplex task protocol, readiness, binary audio, sentence replacement and finish.
- [Qwen3.5-Omni-Plus](https://www.alibabacloud.com/help/en/model-studio/qwen3-5-omni-plus):
  confirms audio input/text output and the still-valid chart model.
- [Qwen Omni guide](https://www.alibabacloud.com/help/en/model-studio/qwen-omni):
  now recommends `qwen3.8-omni-flash` for audio understanding/text output; documents
  six regions, inline audio limits, text SSE, modalities and `reasoning_effort`.
- [Chat Completions API](https://www.alibabacloud.com/help/en/model-studio/qwen-api-via-openai-chat-completions):
  `input_audio.data` uses a URL or Base64 **data URL**, with the audio format.
- [Region/workspace boundaries](https://help.aliyun.com/zh/model-studio/regions):
  regional keys/models are not interchangeable; workspace domains are recommended.

The chart's `Fun-Realtime-ASR-preview` label is **not** registered as an API
identifier. No primary evidence reviewed here establishes that its benchmark
score belongs to the current Flash snapshot. New IDs describe documented
products without importing benchmark equivalence or manufacturing migrations.
No existing Alibaba selection exists to migrate; existing providers/defaults
are unchanged.

Request fixtures, lifecycle, cancellation, limits and native silence handling
are tested with synthetic audio/credentials. No billable Alibaba request was
made. Account/model availability and live service behavior still need an
authorized short provider acceptance run before release.
