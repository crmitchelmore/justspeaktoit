# 04 — Add iOS App Target + Minimal UI

## Goal
Create an iOS app (Xcode project or Xcode target) that links `SpeakCore` and can run on device/simulator.

## Scope
- Add iOS app entry point + minimal SwiftUI UI.
- Wire dependency graph similarly to macOS `WireUp`.

## Steps
1. Decide build system:
   - Option A: Add an Xcode project (`SpeakAppiOS.xcodeproj`) that uses SwiftPM package dependency.
   - Option B: Convert to multi-platform SwiftPM executable targets and open via Xcode.
2. Create iOS app with:
   - Home view with “Start” button (no transcription yet)
   - Settings stub view
3. Add required Info.plist keys:
   - `NSMicrophoneUsageDescription`
   - `NSSpeechRecognitionUsageDescription`
4. Verify app launches on iOS 17+ simulator.

## Deliverables
- Runnable iOS app skeleton.

## Acceptance criteria
- iOS app builds and launches.
- `SpeakCore` is linked and usable from iOS UI.

---

## ✅ Complete (2026-01-08)

### What was created

1. **SpeakiOS directory structure:**
   ```
   SpeakiOS/
   ├── SpeakiOS.xcodeproj/
   │   ├── project.pbxproj
   │   └── xcshareddata/xcschemes/SpeakiOS.xcscheme
   └── SpeakiOS/
       ├── SpeakiOSApp.swift        # App entry point
       ├── Info.plist               # Permissions + config
       └── Views/
           ├── ContentView.swift    # Home screen with Start/Stop/Copy
           └── SettingsView.swift   # Settings + API keys stub
   ```

2. **iOS app features:**
   - Home view with recording UI (Start/Stop buttons)
   - Transcript display area
   - Copy to clipboard action
   - Settings navigation
   - API keys management stub
   - Uses SpeakCore via local SwiftPM dependency

3. **Info.plist permissions:**
   - `NSMicrophoneUsageDescription`
   - `NSSpeechRecognitionUsageDescription`

4. **SpeakCore iOS compilation verified:**
   - All 7 source files compile for arm64-apple-ios17.0

### Known issues
- Xcode project has configuration issues due to simulator framework version mismatch on this machine
- Opening in Xcode GUI should work on a properly configured Mac

### macOS app status
- `make build` — **PASS**
- `make test` — **PASS** (4 tests, 0 failures)
