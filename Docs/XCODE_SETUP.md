# Xcode Project Setup Guide

This guide explains how to finalize the iOS app in Xcode after completing the Swift Package Manager development phase.

## Prerequisites

- Xcode 15.0+ installed
- Apple Developer account (for device testing)
- macOS 14.0+ and iOS 17.0+ devices for testing

## Step 1: Open the Xcode Project

```bash
cd /Users/cm/work/speak-claude-s
open SpeakiOS.xcodeproj
```

The project is already created and links to the Swift packages. You should see:
- **SpeakiOSApp** target (main iOS app)
- Package dependencies: SpeakCore, SpeakiOSLib

## Step 2: Configure Entitlements

### iOS App Target

1. Select **SpeakiOSApp** target in project navigator
2. Go to **Signing & Capabilities** tab
3. Add capabilities:
   - **Keychain Sharing**
     - Add keychain group: `$(AppIdentifierPrefix)com.speak.shared`
   - **iCloud**
     - Enable Key-Value Storage
     - Container: `iCloud.com.speak.ios`
   - **App Groups**
     - Add group: `group.com.speak.ios`
   - **Background Modes** (optional for Live Activity)
     - Enable: Audio, AirPlay, and Picture in Picture

4. Link the entitlements file:
   - Build Settings → Code Signing Entitlements
   - Set to: `Config/SpeakiOS.entitlements`

## Step 3: Add Widget Extension Target (for Live Activity)

### Create Widget Extension

1. File → New → Target
2. Choose **Widget Extension**
3. Name: `SpeakWidgetExtension`
4. Language: Swift
5. **Do not** include configuration intent

### Configure Widget Target

1. **General** tab:
   - Deployment Target: iOS 17.0
   - Bundle Identifier: `com.speak.ios.widget`

2. **Build Phases** → Link Binary with Libraries:
   - Add `SpeakCore` (from Package Dependencies)

3. **Build Settings**:
   - Code Signing Entitlements: `Config/SpeakiOS.entitlements` (share with main app)

4. **Replace** widget source files:
   - Delete auto-generated Swift files
   - Add files from `SpeakWidgetExtension/` directory:
     - `TranscriptionLiveActivity.swift`
   - Add `Info.plist` from `SpeakWidgetExtension/Info.plist`

5. **Info.plist** additions to main app:
   ```xml
   <key>NSSupportsLiveActivities</key>
   <true/>
   ```

## Step 4: Configure Info.plist (Main App)

Add privacy usage descriptions to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Speak needs microphone access to transcribe your speech in real-time.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Speak uses on-device speech recognition to provide fast, private transcription.</string>

<key>NSLocalNetworkUsageDescription</key>
<string>Speak uses your local network to connect to your Mac for the "Send to Mac" feature.</string>

<key>NSBonjourServices</key>
<array>
    <string>_speaktransport._tcp</string>
</array>

<key>NSCameraUsageDescription</key>
<string>Speak needs camera access to scan QR codes for configuration transfer.</string>

<key>NSSupportsLiveActivities</key>
<true/>
```

## Step 5: Configure Signing

### Development Signing

1. Select **SpeakiOSApp** target
2. Signing & Capabilities → Automatically manage signing
3. Select your Team
4. Xcode will provision automatically

### Widget Extension Signing

1. Select **SpeakWidgetExtension** target
2. Same team as main app
3. Bundle ID must be: `<main-app-bundle-id>.widget`

## Step 6: Build and Run

### Simulator Testing (Limited)

```
Product → Destination → iPhone 15 Pro
Product → Run (⌘R)
```

**Note**: Simulator limitations:
- ❌ Speech recognition unavailable
- ❌ Live Activities unavailable
- ❌ Bonjour/local network unavailable
- ✅ UI/navigation works
- ✅ Settings persistence works

### Physical Device Testing (Required)

1. Connect iPhone via USB
2. Product → Destination → [Your iPhone]
3. Trust computer on device
4. Product → Run (⌘R)

On first run, device will prompt for:
- Microphone permission
- Speech Recognition permission
- (When using Send to Mac) Local Network permission

## Step 7: Test Core Features

### Apple Speech Transcription
1. Tap microphone button
2. Grant permissions if prompted
3. Speak - watch transcript appear
4. Tap stop
5. Verify final transcript

### Deepgram Transcription
1. Settings → API Keys → Add Deepgram key
2. Settings → Transcription → Select "Deepgram Nova-2"
3. Return to main view
4. Tap microphone → transcribe
5. Verify streaming works

### Live Activity
1. Start transcription
2. Lock device
3. Check Lock Screen for Live Activity widget
4. On iPhone 14 Pro+: Check Dynamic Island

### QR Transfer
1. Settings → Sync → Share to Another Device
2. QR code should generate
3. On another device: Scan QR code
4. Verify API keys transfer

### Send to Mac (requires macOS receiver)
1. Settings → Send to Mac → Configure
2. Should discover Macs (when receiver running)
3. Pair with code
4. Transcribe → text appears on Mac

## Step 8: Troubleshooting

### Build Errors

**"Cannot find SpeakCore in scope"**
- File → Packages → Resolve Package Versions
- Clean build folder (⇧⌘K)

**Code signing errors**
- Check that all targets have same team
- Verify entitlements paths are correct

### Runtime Issues

**Speech recognition unavailable**
- Check Info.plist has `NSSpeechRecognitionUsageDescription`
- Verify permissions granted in Settings → Privacy

**Keychain errors**
- Ensure keychain sharing entitlement is enabled
- Check access group matches: `$(AppIdentifierPrefix)com.speak.shared`

**Widget not appearing**
- Verify `NSSupportsLiveActivities` in Info.plist
- Widget extension must be running (check in Xcode targets)

## Next Steps: macOS Receiver

To complete "Send to Mac", implement on macOS side:

### Create Bonjour Service

```swift
// In SpeakApp (macOS)
import Network

class TransportServer {
    private var listener: NWListener?
    
    func start() throws {
        let params = NWParameters.tcp
        let service = NWListener.Service(type: "_speaktransport._tcp")
        
        listener = try NWListener(service: service, using: params)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener?.start(queue: .main)
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        // Handle WebSocket upgrade
        // Authenticate with pairing code
        // Forward transcripts to SmartTextOutput
    }
}
```

### Files to Create
- `Sources/SpeakApp/Transport/TransportServer.swift`
- `Sources/SpeakApp/Transport/TransportWebSocket.swift`

### Integration
- Add to main app initialization
- Settings UI to show pairing code
- Settings UI to list connected iOS devices

## Production Release

### TestFlight Beta

1. Archive: Product → Archive
2. Distribute → TestFlight
3. Upload to App Store Connect
4. Invite testers

### App Store

1. Create App Store listing
2. Add screenshots (required: 6.7", 6.5", 5.5" sizes)
3. Privacy policy URL (use `/Docs/PRIVACY.md`)
4. Submit for review

### Required for Review
- Privacy policy accessible URL
- Demo account (if applicable)
- Export compliance (if using encryption)

## Summary Checklist

- [ ] Entitlements configured (Keychain, iCloud, App Groups)
- [ ] Widget Extension target created and linked
- [ ] Info.plist permissions added
- [ ] Code signing working for all targets
- [ ] Tested on physical device (simulator won't work fully)
- [ ] Live Activity verified
- [ ] QR transfer tested between devices
- [ ] macOS receiver implemented for Send to Mac
- [ ] Privacy policy accessible
- [ ] Ready for TestFlight/App Store
