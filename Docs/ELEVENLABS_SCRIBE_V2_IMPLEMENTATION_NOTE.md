# ElevenLabs Scribe v2 — STT Integration Implementation Note

> **Status:** Investigation spike — no production code ships with this note.
> **Issue:** [#341 — \[ElevenLabs\] Investigate Scribe v2 STT API fit](https://github.com/crmitchelmore/justspeaktoit/issues/341)
> **Sources:** [ElevenLabs Realtime STT docs](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime) · [ElevenLabs Scribe overview](https://elevenlabs.io/realtime-speech-to-text)

---

## Required Answers (Definitive)

### 1. Live-only vs Live + Batch?

**Both.**

ElevenLabs provides two independent STT surfaces:

| Surface | Endpoint | Protocol |
|---|---|---|
| **Batch / file** | `POST https://api.elevenlabs.io/v1/speech-to-text` | REST (multipart or binary body) |
| **Streaming / live** | `wss://api.elevenlabs.io/v1/speech-to-text` | WebSocket (binary PCM16 frames) |

Both are production-ready with the `scribe_v2` model. This means ElevenLabs can serve both the existing batch-transcription path (via `TranscriptionProviderRegistry`) **and** a new live-streaming path (via `SwitchingLiveTranscriber`).

---

### 2. macOS-first vs Cross-platform-first?

**macOS-first.**

The credential seam (`elevenlabs.apiKey`, stored via `SecureAppStorage` in `SpeakApp`) lives in `SpeakApp/TextToSpeech/`, which is macOS-only. iOS issue #345 is a dependency on this spike; nothing from #345 should merge before this note and its follow-up implementation close. The SpeakCore placement question (see §7 below) is the key blocker for iOS parity. macOS ships first while that architectural call is made.

---

### 3. One key vs Separate STT key?

**One key.** ElevenLabs uses a single account-level API key for all API surfaces — TTS, STT (batch and streaming), and account management. The existing `elevenlabs.apiKey` stored in the macOS Keychain covers Scribe v2 STT with no additional credential. The `validateAPIKey` path in `ElevenLabsClient.swift` (`GET /v1/user`) also validates STT permissions because they are not separately scoped in ElevenLabs' permission model.

---

## Transport, Endpoint Shape, and Framing

### WebSocket streaming

```
Endpoint:  wss://api.elevenlabs.io/v1/speech-to-text
Auth:      xi-api-key header on the WebSocket handshake request
           (NOT a query parameter — see §Security below)
Audio:     Binary frames, PCM16 LE, 16 kHz, mono
Encoding:  Raw PCM — no opus/AAC encapsulation required
Model:     Sent in the JSON initialisation message after the WS opens
```

**Handshake → init message → audio loop → terminate:**

1. Open WebSocket with `xi-api-key` HTTP header.
2. Send a JSON initialisation message:
   ```json
   {
     "type": "websocket_config",
     "model_id": "scribe_v2",
     "language_code": "en"
   }
   ```
3. Stream binary PCM16 audio frames.
4. Send `{"type": "end_of_stream"}` JSON text frame to flush and finalise.
5. Receive remaining events, then close.

### Batch REST

```
Endpoint:  POST https://api.elevenlabs.io/v1/speech-to-text
Auth:      xi-api-key header (same as existing TTS client)
Body:      multipart/form-data  →  audio file + model_id field
Response:  {"language_code": "en", "text": "...", "words": [...]}
```

The batch response shape maps directly to `TranscriptionResult` in `SpeakCore`.

---

## Partial vs Final Event Behaviour

The streaming WebSocket emits `transcript` JSON events for every utterance boundary:

```json
{
  "type": "transcript",
  "transcript": "hello world",
  "is_final": false,
  "words": [
    { "text": "hello", "start": 0.0, "end": 0.4, "confidence": 0.99 },
    { "text": "world", "start": 0.5, "end": 0.8, "confidence": 0.97 }
  ]
}
```

- `is_final: false` → interim/partial result; display but do not commit.
- `is_final: true` → stable final segment; accumulate into the full transcript.

This maps directly to the `(text: String, isFinal: Bool)` callback pattern already used by `DeepgramLiveController` and `AssemblyAILiveController`.

---

## Security: Auth Mechanism for WebSocket

**Header-based — not query parameter.**

`URLSessionWebSocketTask` supports custom headers via `URLRequest` during the WebSocket handshake (same API as existing `ElevenLabsClient` REST calls). The `xi-api-key` header is passed in the initial HTTP upgrade request and is **not** visible in the WebSocket URL, proxy logs, or network captures after the TLS handshake completes.

The query-parameter form (`?xi_api_key=...`) exists in the ElevenLabs spec as a fallback for environments that cannot set headers (e.g. browser `WebSocket` API). Swift's `URLSessionWebSocketTask` is not constrained in this way. The macOS implementation **must** use the header form — matching `ElevenLabsClient.swift`'s existing pattern — to avoid credential exposure in proxy logs.

**Key scope:** The `elevenlabs.apiKey` credential covers TTS + STT. If the key leaks, both surfaces are compromised simultaneously. This is acceptable for a single-user macOS app where the key lives in the Keychain and is never transmitted in plaintext. However, if ElevenLabs ever introduces scoped sub-keys, STT should migrate to a separate credential to limit blast radius.

**Audio data retention:** ElevenLabs processes audio server-side to produce transcriptions. Per their privacy policy, audio sent to Scribe is not retained for model training by default (same position as their TTS audio). Follow-up implementation should surface this in the privacy settings note if one is added.

---

## Performance: Minimum Chunk Duration Floor

| Parameter | Scribe v2 | AssemblyAI (existing) |
|---|---|---|
| **Minimum frame** | ≥ 100 ms (3 200 bytes @ 16 kHz PCM16 mono) | ≥ 50 ms (1 600 bytes) |
| **Preferred frame** | 100 ms (3 200 bytes) | 100 ms (3 200 bytes) |
| **Error for sub-minimum** | WebSocket close (code TBD — verify during implementation) | Close code 3007 |

The existing `minimumChunkBytes = 1600` / `preferredChunkBytes = 3200` constants in `TranscriptionManager.swift` (lines 1230–1231) were sized for AssemblyAI's 50 ms floor. For Scribe v2 the same `preferredChunkBytes = 3200` value satisfies the 100 ms minimum, so the framing constants **can be reused unchanged** for the ElevenLabs live controller. The `minimumChunkBytes` guard should be raised to 3 200 for the ElevenLabs path — or the controller should enforce this at its own layer rather than lowering the shared constant.

**Claimed latency:** ElevenLabs positions Scribe v2 at ~200–300 ms end-to-end for English. This is consistent with `DeepgramLiveController` (`estimatedLatencyMs: 200`) and should be reflected in the `ModelCatalog.liveTranscription` entry at registration time.

---

## Reliability: Reconnection and Failure Path

### Session resume

**Not supported.** Scribe v2 WebSocket sessions are stateless — each connect is a cold start with a fresh initialisation message. This matches the existing pattern in `AssemblyAILiveController` and `DeepgramLiveController`, which also do not resume sessions.

### Recommended reconnect strategy

Mirror the AssemblyAI dual-host pattern:

1. **Primary**: `wss://api.elevenlabs.io/v1/speech-to-text`
2. **No secondary EU host** — ElevenLabs does not publish a separate EU streaming endpoint (unlike AssemblyAI). Retry once on the same host on transient failure before surfacing an error to the user.

### Key close codes to document during implementation

| Scenario | Expected signal |
|---|---|
| Invalid / expired key during active session | Close code 1008 (Policy Violation) or HTTP 401 before upgrade |
| Server-side timeout (idle stream) | Close code 1001 (Going Away) |
| Audio format / duration violation | Close code TBD — verify against live API during follow-up |
| Rate limit | HTTP 429 before upgrade |

The follow-up implementation must capture and map these to user-visible error messages. The pattern from `AssemblyAILiveController` (show error, do not crash, persist session to History before cleanup) is the correct template.

---

## Language Handling

Specify `language_code` (ISO 639-1, e.g. `"en"`, `"fr"`) in the initialisation message. Omit or pass `null` to enable automatic language detection. Scribe v2 supports 30+ languages. The existing `language` parameter on `configure(language:model:)` in `LiveTranscriptionController` maps directly to this field.

---

## Unsupported / Deferred Features

| Feature | Status |
|---|---|
| Speaker diarization | **Not supported in streaming.** Diarization is available on the batch REST endpoint only (`diarization: true` in the request body). Do not implement in the live controller — note this as a non-goal. |
| Custom vocabulary / key terms | Not available on Scribe v2 streaming (unlike AssemblyAI `keyterms_prompt`). Deferred. |
| Punctuation control | Automatic; no configuration surface in v2. |
| Turn/utterance boundary events | `is_final: true` serves as the utterance boundary; no separate `SpeechStarted`/`SpeechEnded` events to tap for HUD animation (use audio power metering as today). |

---

## Capability-to-Class Mapping

| Capability confirmed | Maps to existing class | Action required |
|---|---|---|
| **Live streaming** | `SwitchingLiveTranscriber` — add `if model.hasPrefix("elevenlabs/")` branch → `ElevenLabsLiveController` | New `ElevenLabsLiveController` conforming to `LiveTranscriptionController` |
| **Batch file transcription** | `TranscriptionProviderRegistry` — add `providers["elevenlabs"] = ElevenLabsTranscriptionProvider()` | New `ElevenLabsTranscriptionProvider` conforming to `TranscriptionProvider` |
| **API key storage / validation** | `SecureAppStorage` (`elevenlabs.apiKey`) + `ElevenLabsClient.validateAPIKey` | **Reuse existing** — no new Keychain entry needed |
| **Model catalog entry (live)** | `ModelCatalog.liveTranscription` | Append `Option(id: "elevenlabs/scribe-v2-streaming", ...)` |
| **Model catalog entry (batch)** | `ModelCatalog.batchTranscription` | Append `Option(id: "elevenlabs/scribe_v2", ...)` |

---

## SpeakCore vs SpeakApp Client Placement

**Recommendation: Keep in `SpeakApp` for the macOS-first implementation; plan a `SpeakCore` migration only when iOS (#345) is ready to integrate.**

Rationale:

- `ElevenLabsClient` (TTS) already lives in `SpeakApp/TextToSpeech/`. The new STT client shares the same `baseURL`, `xi-api-key` header pattern, and `SecureAppStorage` dependency.
- `SecureAppStorage` is a `SpeakApp` type; `SpeakCore` uses `SecureStorage` (protocol). A `SpeakCore`-resident ElevenLabs client would need to work against the protocol, adding a layer of indirection that is not justified until a second platform consumer (iOS) actually needs it.
- When iOS #345 integrates: refactor into a shared `ElevenLabsAPIClient` in `SpeakCore` (accepting a `SecureStorage` protocol), and have both `SpeakApp` and `SpeakiOSLib` instantiate it. At that point the `xi-api-key` + base URL logic centralises once, and key validation becomes reusable.

**Decision: `SpeakApp` now, `SpeakCore` on the iOS integration PR.**

---

## Recommended Rollout Order

1. **This spike (issue #341):** Implementation note (this document). Gates all follow-up work.
2. **macOS batch provider** (`ElevenLabsTranscriptionProvider` + `ModelCatalog.batchTranscription` entry): Low-risk, REST-only, reuses existing credential. Ship independently as a small PR.
3. **macOS live streaming controller** (`ElevenLabsLiveController` + `ModelCatalog.liveTranscription` entry + `SwitchingLiveTranscriber` routing): Medium complexity; WebSocket lifecycle, error mapping, and framing. Ship as a separate PR.
4. **iOS integration (issue #345):** After macOS live controller is stable; refactor shared client into `SpeakCore` at this point.

---

## Summary of Official Sources Used

- ElevenLabs Realtime STT API reference: `https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime`
- ElevenLabs Scribe overview: `https://elevenlabs.io/realtime-speech-to-text`
- ElevenLabs general API authentication: `https://elevenlabs.io/docs/api-reference/authentication`
- Existing codebase references: `ElevenLabsClient.swift`, `TranscriptionManager.swift` (lines 1230–1231, 2013–2143), `ModelCatalog.swift` (lines 109–144), `TranscriptionProviderRegistry.swift`
