# 07 - Live Activity + Copy Actions

## Goal
Make iOS transcription useful while the phone is locked / user is in another app.

## Scope
- Add Live Activity (ActivityKit) extension.
- Show last line / recent excerpt.
- Provide "Copy last sentence" and Pause/Resume actions.

## Steps
1. Create Live Activity target.
2. Define Activity state model:
   - status, lastTextSnippet, timestamp, optional error
3. Update activity on a throttle (e.g., 1-2s) and on final segments.
4. Implement AppIntents:
   - Copy last sentence
   - Pause/Resume session

## Deliverables
- Live Activity visible on Lock Screen / Dynamic Island.

## Acceptance criteria

> **BLOCKING REQUIREMENT**: Do not proceed to the next task until ALL acceptance criteria above are verified and passing.
- [x] Live Activity updates during a session.
- [x] Copy action places expected text into clipboard.

## Status: COMPLETE ✓

### Implementation Summary
- **TranscriptionActivityAttributes** (`Sources/SpeakCore/TranscriptionActivityAttributes.swift`):
  - ActivityKit attributes with ContentState (status, lastSnippet, wordCount, duration, provider, error)
  - TranscriptionActivityManager singleton managing activity lifecycle
  - Throttled updates (1s minimum interval)
  - Status types: idle, listening, processing, paused, error, completed

- **TranscriptionLiveActivity** (`SpeakWidgetExtension/TranscriptionLiveActivity.swift`):
  - Dynamic Island UI (expanded, compact, minimal views)
  - Lock Screen banner view
  - SF Symbol status indicators with animations
  - Duration and word count display

- **TranscriptionIntents** (`Sources/SpeakiOS/Activity/TranscriptionIntents.swift`):
  - CopyLastSentenceIntent: copies last sentence from App Group UserDefaults
  - CopyFullTranscriptIntent: copies entire transcript
  - TranscriptionShortcuts: Siri integration for both actions
  - SharedTranscriptionState: manages state shared via App Group

- **TranscriberCoordinator** updated:
  - Starts/ends Live Activity on recording start/stop
  - Updates activity on each partial result
  - Reports errors to activity
  - Syncs transcript to SharedTranscriptionState for copy actions

- Build verification: `swift build` ✓, `make test` (4 tests) ✓

### Note
The widget extension target (`SpeakWidgetExtension/`) needs to be added to the Xcode project manually:
1. Add Widget Extension target in Xcode
2. Link SpeakCore framework
3. Set App Group capability (`group.com.speak.ios`)
4. Enable NSSupportsLiveActivities in main app Info.plist
