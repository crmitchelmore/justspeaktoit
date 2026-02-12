# AssemblyAI Universal Streaming — Fix & Feature Plan

## References

- **Universal Streaming docs**: https://www.assemblyai.com/docs/universal-streaming
- **Message sequence**: https://www.assemblyai.com/docs/speech-to-text/universal-streaming/message-sequence
- **Voice agents guide**: https://www.assemblyai.com/docs/speech-to-text/universal-streaming/voice-agents
- **Turn detection**: https://www.assemblyai.com/docs/speech-to-text/universal-streaming/turn-detection
- **Keyterms prompting**: https://www.assemblyai.com/docs/speech-to-text/universal-streaming/keyterms-prompting
- **Multilingual**: https://www.assemblyai.com/docs/speech-to-text/universal-streaming/multilingual-transcription
- **Universal-3 Pro (prompting)**: https://www.assemblyai.com/docs/getting-started/universal-3-pro
- **Prompt engineering guide**: https://www.assemblyai.com/docs/pre-recorded-audio/prompt-engineering

## Key Files

| File | Purpose |
|------|---------|
| `Sources/SpeakApp/AssemblyAITranscriptionProvider.swift` | WebSocket client, response models, provider |
| `Sources/SpeakApp/TranscriptionManager.swift:879-1170` | `AssemblyAILiveController` — turn handling, audio processing |
| `Sources/SpeakApp/AppSettings.swift` | All settings: `SpeedMode`, `postProcessingSystemPrompt`, polish config |
| `Sources/SpeakApp/PostProcessingManager.swift` | LLM-based post-processing (the thing pre-processing replaces) |
| `Sources/SpeakApp/LivePolishManager.swift` | Live tail-rewrite polish during transcription |
| `Sources/SpeakApp/MainManager.swift` | Orchestrates recording → transcription → post-processing flow |
| `Sources/SpeakApp/SettingsView.swift` | UI for all settings including post-processing prompt |

---

## Problem Statement

The user sees duplicated text during live transcription, e.g.:
> "don't change branch Don't change, Branch. i want you"

### Root Cause Analysis

**Bug 1 — Duplicate final segments:** With `format_turns=true`, AssemblyAI sends **two** end-of-turn messages for the same `turn_order`:
1. Unformatted: `{turn_is_formatted: false, end_of_turn: true, transcript: "don't change branch"}`
2. Formatted: `{turn_is_formatted: true, end_of_turn: true, transcript: "Don't change, Branch."}`

The current callback `onTranscript: ((String, Bool) -> Void)?` (line 18 of AssemblyAITranscriptionProvider.swift) only passes `(transcript, end_of_turn)` — no `turn_is_formatted` or `turn_order`. So `handleTranscript` (TranscriptionManager.swift:998-1012) treats both as separate finals and appends both to `finalSegments`.

**Bug 2 — Interim accumulation:** During a turn, AssemblyAI's `transcript` field is the *full turn text so far* (immutable transcriptions — it grows: `"don't"` → `"don't change"` → `"don't change branch"`). But `handleTranscript` concatenates `fullTranscript + " " + currentInterim` (line 1009), which works for Deepgram-style partials but double-counts for AssemblyAI because the interim already contains the full turn.

**Current problematic code path:**
```
parseResponse → onTranscript?(turn.transcript, turn.end_of_turn)
    → handleTranscript(text:isFinal:)
        if isFinal → finalSegments.append(segment) // APPENDS both unformatted AND formatted
        else → currentInterim = text; display = fullTranscript + " " + currentInterim // DOUBLE-COUNTS
```

---

## Approach

### Phase 1: Fix the duplication bug (critical)

**Strategy:** Make `AssemblyAITurnResponse` non-private so the controller receives the full turn struct. Track `turn_order` to handle replacement semantics.

**Detailed changes:**

#### 1a. `AssemblyAITranscriptionProvider.swift` changes

- Make `AssemblyAITurnResponse` internal (remove `private`). It's already `Decodable`; add `utterance` field.
- Change `onTranscript` callback from `((String, Bool) -> Void)?` to `((AssemblyAITurnResponse) -> Void)?`.
- In `parseResponse`, pass the full decoded turn object instead of just `(turn.transcript, turn.end_of_turn)`.

**Current (line 18):**
```swift
private var onTranscript: ((String, Bool) -> Void)?
```
**New:**
```swift
private var onTranscript: ((AssemblyAITurnResponse) -> Void)?
```

**Current `start` signature (line 34-36):**
```swift
func start(
    onTranscript: @escaping (String, Bool) -> Void,
    onError: @escaping (Error) -> Void
)
```
**New:**
```swift
func start(
    onTranscript: @escaping (AssemblyAITurnResponse) -> Void,
    onError: @escaping (Error) -> Void
)
```

**Current `parseResponse` (line 192-195):**
```swift
case "Turn":
    let turn = try JSONDecoder().decode(AssemblyAITurnResponse.self, from: data)
    guard !turn.transcript.isEmpty else { return }
    onTranscript?(turn.transcript, turn.end_of_turn)
```
**New:**
```swift
case "Turn":
    let turn = try JSONDecoder().decode(AssemblyAITurnResponse.self, from: data)
    onTranscript?(turn)
```
(Remove the empty transcript guard — we need to handle turns with empty transcript but non-empty `utterance` or `words`.)

**Response model changes (line 508-524):**
```swift
// Change from private to internal
struct AssemblyAITurnResponse: Decodable {
    let type: String
    let turn_order: Int
    let turn_is_formatted: Bool
    let end_of_turn: Bool
    let transcript: String
    let end_of_turn_confidence: Double?
    let words: [AssemblyAIStreamWord]?
    let utterance: String?          // NEW
    let language_code: String?      // NEW (for multilingual)
    let language_confidence: Double? // NEW (for multilingual)
}

struct AssemblyAIStreamWord: Decodable {
    let text: String
    let word_is_final: Bool
    let start: Int
    let end: Int
    let confidence: Double?
}
```

#### 1b. `TranscriptionManager.swift` — `AssemblyAILiveController` changes

**Add state tracking (around line 893):**
```swift
private var currentTurnOrder: Int = -1
private var formatTurnsEnabled: Bool = true  // matches the format_turns=true in connection
```

**Replace `handleTranscript(text:isFinal:)` (lines 998-1012) with:**
```swift
private func handleTurn(_ turn: AssemblyAITurnResponse) {
    // Skip empty transcripts unless it's an end-of-turn (which finalises the turn)
    guard !turn.transcript.isEmpty || turn.end_of_turn else { return }

    if turn.end_of_turn {
        if formatTurnsEnabled && !turn.turn_is_formatted {
            // Unformatted end-of-turn: update interim but DON'T commit yet.
            // The formatted version is coming next and will replace this.
            currentInterim = turn.transcript
            rebuildDisplay()
            return
        }

        // This is the definitive final (formatted if enabled, or unformatted if not)
        let segment = TranscriptionSegment(startTime: 0, endTime: 0, text: turn.transcript)

        // Replace existing segment for this turn_order, or append if new
        if let idx = finalSegments.lastIndex(where: { _ in currentTurnOrder == turn.turn_order }) {
            finalSegments[idx] = segment
        } else {
            finalSegments.append(segment)
        }

        fullTranscript = finalSegments.map(\.text).joined(separator: " ")
        currentInterim = ""
        currentTurnOrder = -1
        delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)
    } else {
        // Ongoing turn — replace interim (NOT append)
        currentTurnOrder = turn.turn_order
        currentInterim = turn.transcript
        rebuildDisplay()
    }
}

private func rebuildDisplay() {
    let displayText = fullTranscript.isEmpty
        ? currentInterim
        : fullTranscript + " " + currentInterim
    delegate?.liveTranscriber(self, didUpdatePartial: displayText)
}
```

**Update the `transcriber?.start` call (lines 961-975) to use the new callback:**
```swift
transcriber?.start(
    onTranscript: { [weak self] turn in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleTurn(turn)
        }
    },
    onError: { ... } // unchanged
)
```

**Update `start()` reset (line 935-938) to include:**
```swift
currentTurnOrder = -1
```

---

### Phase 2: Use `word_is_final` for better partial display

**What:** The last word in the `words` array may be a sub-word (e.g. "son" before "sonny" is finalised). The `transcript` field only contains finalised words, but the `words` array shows the non-final last word.

**Implementation in `handleTurn`:**
When building the interim display, append the last non-final word (from `words`) as a "tentative" suffix. This shows the user what's being heard without waiting for finalisation.

```swift
// In handleTurn, for non end_of_turn:
var displayTranscript = turn.transcript
if let lastWord = turn.words?.last, !lastWord.word_is_final {
    if !displayTranscript.isEmpty {
        displayTranscript += " "
    }
    displayTranscript += lastWord.text  // tentative word
}
currentInterim = displayTranscript
```

**Optional enhancement:** If the UI supports attributed strings, show the tentative word in a lighter colour/opacity. For now, just showing it as plain text is an improvement.

---

### Phase 3: Adopt `utterance` field for pre-emptive processing

**What:** The API populates `utterance` when an utterance (sub-turn speech segment) is complete, even before `end_of_turn`. This arrives faster than the end-of-turn signal.

**Implementation:**
- In `handleTurn`, when `turn.utterance` is non-nil and non-empty, trigger the live polish pipeline immediately (if `usesLivePolish` speed mode is active):

```swift
if let utterance = turn.utterance, !utterance.isEmpty {
    delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
}
```

- Add `didDetectUtteranceBoundary` to the `LiveTranscriptionSessionDelegate` protocol.
- In `TranscriptionManager` (the delegate implementation), wire this to `LivePolishManager.polishNow()`.

---

### Phase 4: New API features

#### 4a. `force-endpoint` — Send ForceEndpoint before Terminate

**File:** `AssemblyAITranscriptionProvider.swift`, `stop()` method (line 123-137)

**Current:**
```swift
func stop() {
    isStopping = true
    // Send Terminate message
    let terminateMsg = #"{"type":"Terminate"}"#
    ...
    webSocketTask?.cancel(...)
}
```

**New:**
```swift
func stop() {
    isStopping = true
    bufferPool.logMetrics()

    guard let webSocketTask, webSocketTask.state == .running else {
        self.webSocketTask = nil
        return
    }

    // 1. Send ForceEndpoint to flush the current turn
    let forceMsg = #"{"type":"ForceEndpoint"}"#
    webSocketTask.send(.string(forceMsg)) { [weak self] _ in
        // 2. Brief delay to receive the final turn response
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 3. Then send Terminate
            let terminateMsg = #"{"type":"Terminate"}"#
            webSocketTask.send(.string(terminateMsg)) { _ in }
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            self?.webSocketTask = nil
        }
    }
}
```

#### 4b. `captioning-defaults` — Better endpointing for captioning

**File:** `AssemblyAITranscriptionProvider.swift`, `start()` method (line 42-47)

**Add to query items:**
```swift
URLQueryItem(name: "min_end_of_turn_silence_when_confident", value: "560"),
```

This is AssemblyAI's recommendation for live captioning (vs 400ms default which is optimised for voice agents).

#### 4c. `keyterms-support` — Domain-specific term boosting

**Files:** `AppSettings.swift`, `AssemblyAITranscriptionProvider.swift`, `AssemblyAILiveController`

**AppSettings.swift additions:**
```swift
// In DefaultsKey enum:
case assemblyAIKeyterms

// New published property:
@Published var assemblyAIKeyterms: String {
    didSet { store(assemblyAIKeyterms, key: .assemblyAIKeyterms) }
}

// In init:
assemblyAIKeyterms = defaults.string(forKey: DefaultsKey.assemblyAIKeyterms.rawValue) ?? ""
```

The user enters comma-separated terms (e.g. "AssemblyAI, Universal-3 Pro, Keanu Reeves"). Max 100 terms, each ≤50 chars.

**AssemblyAITranscriptionProvider.swift** — add to WebSocket URL query items:
```swift
// Parse comma-separated keyterms and add as repeated query params
let keyterms = keytermsList.filter { !$0.isEmpty && $0.count <= 50 }.prefix(100)
for term in keyterms {
    urlComponents.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: term))
}
```

**Cost note:** Keyterms prompting costs an additional $0.04/hour.

#### 4d. `multilingual-support` — Non-English streaming

**File:** `AssemblyAITranscriptionProvider.swift`, `start()` method

Supported languages: English, Spanish, French, German, Italian, Portuguese.

```swift
// Determine speech model based on language
let isEnglish = language == nil || language?.hasPrefix("en") == true
let speechModel = isEnglish ? "universal-streaming-english" : "universal-streaming-multi"
urlComponents.queryItems?.append(URLQueryItem(name: "speech_model", value: speechModel))
```

This requires the language to be passed through `configure(language:model:)` → stored → used in `start()`.

#### 4e. `dynamic-config` — Mid-session configuration updates

**File:** `AssemblyAITranscriptionProvider.swift`

**Add new method to `AssemblyAILiveTranscriber`:**
```swift
func updateConfiguration(_ config: [String: Any]) {
    guard let webSocketTask, webSocketTask.state == .running else { return }
    var payload = config
    payload["type"] = "UpdateConfiguration"
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else { return }
    webSocketTask.send(.string(json)) { [weak self] error in
        if let error {
            self?.logger.error("Failed to send config update: \(error.localizedDescription)")
        }
    }
}
```

**Use cases:**
- Update `keyterms_prompt` mid-session
- Adjust `end_of_turn_confidence_threshold` dynamically
- Adjust `min_end_of_turn_silence_when_confident`

---

### Phase 5: Pre-processing prompt (the big feature)

#### Background

Universal-3 Pro supports a `prompt` parameter (up to 1,500 words) that guides transcription at the model level. This controls:
- Verbatim vs clean output (disfluencies, false starts)
- Output formatting (punctuation, capitalisation, numbers)
- Domain context (jargon, technical terms)
- Entity spelling (proper nouns, brands)
- Audio event tags ([laughter], [music])
- Code-switching / multilingual
- Speaker attribution

This is functionally identical to our `postProcessingSystemPrompt` but happens *during* transcription — zero extra latency, zero LLM cost.

**Important API constraint:** `prompt` and `keyterms_prompt` CANNOT be used together. Choose one.

#### 5a. `preprocess-prompt` — Wire prompt to WebSocket connection

**File:** `AssemblyAITranscriptionProvider.swift`, `start()` method

The `prompt` parameter is NOT a query parameter — it is part of the initial configuration. Looking at the API docs, for streaming it should be sent as a query parameter or in the initial connection. Based on the batch API pattern:

```swift
// In start() — add prompt to query items if non-empty
if !prompt.isEmpty {
    urlComponents.queryItems?.append(URLQueryItem(name: "prompt", value: prompt))
}
```

**Pass prompt through the chain:**
- `AssemblyAILiveTranscriber.init` gains an optional `prompt: String?` parameter
- `AssemblyAILiveController.configure(language:model:)` gains access to `appSettings.postProcessingSystemPrompt`
- `createLiveTranscriber` passes it through

#### 5b. `auto-disable-postprocess` — Skip post-processing when pre-processing is active

**File:** `MainManager.swift` (around lines 515-525)

**Current logic (line 515-518):**
```swift
if appSettings.speedMode.usesLivePolish
    && appSettings.skipPostProcessingWithLivePolish {
    // skip post-processing
}
```

**Add additional condition:**
```swift
// Also skip post-processing when using AssemblyAI with a pre-processing prompt
let usingAssemblyAIPreprocessing = appSettings.selectedModel.contains("assemblyai")
    && !appSettings.postProcessingSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

if usingAssemblyAIPreprocessing {
    // Pre-processing prompt is active — STT model already produces styled output
    // Skip post-processing to avoid double-processing
} else if appSettings.speedMode.usesLivePolish
    && appSettings.skipPostProcessingWithLivePolish {
    // existing logic
} else if appSettings.postProcessingEnabled {
    // existing post-processing flow
}
```

#### 5c. `ui-relabel` — Relabel prompt settings in SettingsView

**File:** `SettingsView.swift`

**Changes:**
1. Rename the section header from "Post-Processing" to "Transcription Prompt" (or "Processing Prompt")
2. Add explanatory text:
   - When AssemblyAI is selected: "This prompt is sent directly to the transcription model (pre-processing). No additional LLM cost or latency."
   - When other providers are selected: "This prompt is sent to an LLM after transcription (post-processing). Requires an OpenRouter API key."
3. Add a help/info icon with a popover explaining:
   - **Pre-processing** = prompt sent to STT model at connection time. Zero latency. Only AssemblyAI.
   - **Post-processing** = prompt sent to LLM after transcription. Works with any provider. Adds latency + cost.
   - Both use the same prompt text field — the system routes automatically.

**Example prompt suggestions to show in placeholder text:**
```
"Produce clean, human-readable transcription. Fix spelling and punctuation. 
Include filler words like 'um' and 'uh' only when they add meaning."
```

#### 5d. `prompt-keyterms-guard` — Mutual exclusivity validation

**File:** `AssemblyAITranscriptionProvider.swift`, `start()` method

```swift
// prompt and keyterms_prompt are mutually exclusive per AssemblyAI API
if !prompt.isEmpty && !keyterms.isEmpty {
    logger.warning("prompt and keyterms_prompt cannot be used together. Using prompt only.")
    // Don't add keyterms to URL
} else if !keyterms.isEmpty {
    // Add keyterms
}
```

**Also in SettingsView:** Show a warning label when both are populated:
```swift
if !appSettings.postProcessingSystemPrompt.isEmpty && !appSettings.assemblyAIKeyterms.isEmpty {
    Label("Prompt and keyterms cannot be used together. Prompt takes priority.",
          systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
}
```

---

### Phase 6: Structural improvements

#### `decode-extras` — Language detection fields

Already covered in Phase 1 model changes. The `language_code` and `language_confidence` fields are added to `AssemblyAITurnResponse`. Surface them to the delegate when present:

```swift
if let langCode = turn.language_code {
    logger.info("Detected language: \(langCode) (confidence: \(turn.language_confidence ?? 0))")
    // Could display in UI or use for auto-switching
}
```

---

## Dependency Graph

```
Phase 1 (critical):
  fix-turn-model ──→ fix-turn-tracking ──→ fix-interim-display
                                        └──→ force-endpoint

Phase 2:
  fix-turn-tracking ──→ word-final-display

Phase 3:
  fix-turn-model ──→ utterance-field

Phase 4 (independent):
  captioning-defaults (standalone)
  keyterms-support (standalone) ──→ prompt-keyterms-guard
  decode-extras (standalone) ──→ multilingual-support
  dynamic-config (standalone)

Phase 5:
  preprocess-prompt (standalone) ──→ auto-disable-postprocess
                                 └──→ ui-relabel
```

## Implementation Order (recommended)

1. **fix-turn-model** + **decode-extras** + **captioning-defaults** (all independent, do in parallel)
2. **fix-turn-tracking** + **fix-interim-display** (depend on fix-turn-model)
3. **force-endpoint** + **word-final-display** + **utterance-field** (depend on fix-turn-tracking/model)
4. **preprocess-prompt** + **keyterms-support** (independent features)
5. **auto-disable-postprocess** + **ui-relabel** + **prompt-keyterms-guard** (depend on preprocess/keyterms)
6. **multilingual-support** + **dynamic-config** (lower priority)

## Testing Strategy

- **Phase 1 fix verification:** Run the app, speak a sentence, confirm no duplication. The formatted version should replace the unformatted one. Check debug logs for `turn_order` tracking.
- **Pre-processing prompt:** Set a prompt like "Include filler words. Use exclamation marks for emphasis." — confirm the raw AssemblyAI output reflects the prompt without any post-processing LLM call.
- **Keyterms:** Add domain terms, speak them, confirm improved recognition.
- **ForceEndpoint:** Stop recording mid-sentence, confirm the partial text is flushed as a final turn.
