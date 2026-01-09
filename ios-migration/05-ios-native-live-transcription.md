# 05 — iOS Native Live Transcription (Apple Speech)

## Goal
Implement reliable low-latency live transcription on iOS using Apple Speech + AVAudioEngine.

## Scope
- Implement `NativeAppleLiveTranscriber` (iOS-compatible).
- Handle interruptions and route changes.
- Render live partial transcript in UI.

## Steps
1. ✅ Implement iOS audio session setup:
   - category: `.playAndRecord`
   - mode: `.measurement`
   - options: `allowBluetooth`, `defaultToSpeaker` (as appropriate)
2. ✅ Implement live controller using:
   - `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest`
   - `AVAudioEngine` input tap
3. ⏳ Integrate with existing `TranscriptionManager` and `SwitchingLiveTranscriber`.
   - Note: iOS uses standalone `iOSLiveTranscriber` for now (simpler than full integration)
4. ✅ Add a "Start/Stop" session UI and show partial text.

## Implementation Files
- `SpeakiOS/SpeakiOS/Services/AudioSessionManager.swift` - iOS audio session handling
- `SpeakiOS/SpeakiOS/Services/iOSLiveTranscriber.swift` - Apple Speech live transcription
- `SpeakiOS/SpeakiOS/Views/ContentView.swift` - UI wired to transcriber

## Deliverables
- ✅ iOS live transcription code implemented (on-device where possible).

## Acceptance criteria

> **BLOCKING REQUIREMENT**: Do not proceed to the next task until ALL acceptance criteria above are verified and passing.
- On a real device, starting a session yields partial transcripts within ~1–2s.
- Stop returns a final transcript result.
- Interruption (phone call / Siri) ends gracefully with a clear error.

## Status: IMPLEMENTATION COMPLETE, TESTING BLOCKED

**Environment Issue**: CoreSimulator version mismatch prevents xcodebuild from running:
- Current: 1048.0.0
- Required: 1051.17.7

**To verify acceptance criteria**:
1. Open `SpeakiOS/SpeakiOS.xcodeproj` in Xcode on a properly configured Mac
2. Select a physical iOS device or working simulator
3. Build and run (Cmd+R)
4. Test: tap Start, speak, verify partial text appears within 1-2s
5. Test: tap Stop, verify final result
6. Test: trigger Siri mid-recording, verify graceful error handling

**Code verification completed**:
- All iOS source files parse successfully with `xcrun --sdk iphoneos swiftc -parse`
- SpeakCore cross-compiles for iOS target
- macOS build and tests still pass
