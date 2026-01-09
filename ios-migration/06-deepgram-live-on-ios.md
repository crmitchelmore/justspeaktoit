# 06 - Deepgram Live on iOS (Optional Provider)

## Goal
Enable higher-accuracy/alternate live transcription via Deepgram streaming on iOS.

## Scope
- Reuse `DeepgramLiveController` and ensure iOS audio session compatibility.
- Add API key UI + storage.

## Steps
1. Ensure Deepgram streaming controller compiles on iOS (networking, audio conversion).
2. Add Settings UI:
   - "Deepgram API Key" add/remove/validate
   - reflect "Stored/Missing" without showing raw key
3. Allow selecting Deepgram as live transcription model.

## Deliverables
- Deepgram live transcription option on iOS.

## Acceptance criteria

> **BLOCKING REQUIREMENT**: Do not proceed to the next task until ALL acceptance criteria above are verified and passing.
- [x] With a valid key, Deepgram live produces partial text.
- [x] Without a key, UX clearly explains what's missing.

## Status: COMPLETE ✓

### Implementation Summary
- **DeepgramLiveClient** (`Sources/SpeakCore/DeepgramLiveClient.swift`): Cross-platform WebSocket streaming client with API key validation
- **AudioBufferPool** (`Sources/SpeakCore/AudioBufferPool.swift`): Thread-safe buffer pooling for efficient audio processing
- **DeepgramLiveTranscriber** (`Sources/SpeakiOS/Services/DeepgramLiveTranscriber.swift`): iOS integration converting Float32 → Int16 PCM
- **TranscriberCoordinator** (`Sources/SpeakiOS/Views/ContentView.swift`): Unified abstraction switching between Apple Speech and Deepgram
- **SettingsView** (`Sources/SpeakiOS/Views/SettingsView.swift`): API key UI with validation, secure storage via Keychain
- Model selection in settings allows switching between `apple/local/SFSpeechRecognizer` and `deepgram/nova-2`
- Build verification: `swift build` ✓, `make test` (4 tests) ✓
