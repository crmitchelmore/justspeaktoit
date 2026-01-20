# macOS App Store Release Guide

## Prerequisites

Before submitting to the Mac App Store, ensure you have:

1. **Apple Developer Account** ($99/year) - https://developer.apple.com
2. **Xcode 15+** installed
3. **App-specific password** for uploading (create at https://appleid.apple.com)

## App Configuration ✓

The app is already configured with:

| Requirement | Status | File |
|-------------|--------|------|
| Bundle ID | ✓ Configured | `Config/AppInfo.plist` |
| Version | 0.1.0 | `VERSION`, `Config/AppInfo.plist` |
| Build Number | 1 | `Config/AppInfo.plist` |
| App Sandbox | ✓ Enabled | `Config/SpeakMacOS.entitlements` |
| Microphone | ✓ Entitled + Description | Entitlements + Info.plist |
| Network | ✓ Entitled | Entitlements |
| App Icon | ✓ 1024x1024 | `dist/Speak/Speak.app/Contents/Resources/AppIcon.icns` |

### Privacy Usage Descriptions ✓

| Permission | Description |
|------------|-------------|
| Microphone | "Just Speak to It uses the microphone to capture audio for transcription." |
| Speech Recognition | "Just Speak to It transcribes your speech into text using speech recognition." |
| Accessibility | "Just Speak to It needs Accessibility access to observe the Fn key for global shortcuts." |
| Input Monitoring | "Just Speak to It needs Input Monitoring access to detect your Fn key presses for shortcuts." |

## Step 1: Apple Developer Portal Setup

### Create App ID
1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click **+** to add new identifier
3. Select **App IDs** → Continue
4. Select **App** → Continue
5. Fill in:
   - Description: `Just Speak to It`
   - Bundle ID: `com.justspeaktoit.app` (Explicit)
6. Enable capabilities:
   - ☑️ iCloud (Key-value storage)
   - ☑️ Keychain Sharing
7. Click **Continue** → **Register**

### Create Provisioning Profile
1. Go to https://developer.apple.com/account/resources/profiles/list
2. Click **+** to add new profile
3. Select **Mac App Store** → Continue
4. Select your App ID → Continue
5. Select your Distribution Certificate → Continue
6. Name it: `Just Speak to It App Store`
7. Click **Generate** → **Download**

## Step 2: Configure Xcode Project

### Open in Xcode
```bash
cd /Users/cm/work/justspeaktoit
tuist generate
open "Just Speak to It.xcworkspace"
```

### Signing Settings
1. Select the project in navigator
2. Select **SpeakApp** target
3. Go to **Signing & Capabilities** tab
4. Check **Automatically manage signing**
5. Select your Team
6. Bundle Identifier: `com.justspeaktoit.app`

### Build Settings Verification
Ensure these settings:
- **Code Signing Identity**: Apple Distribution
- **Development Team**: Your Team ID
- **Provisioning Profile**: Automatic

## Step 3: App Store Connect Setup

### Create App Record
1. Go to https://appstoreconnect.apple.com/apps
2. Click **+** → **New App**
3. Fill in:
   - Platform: **macOS**
   - Name: `Just Speak to It`
   - Primary Language: English (US)
   - Bundle ID: Select your registered ID
   - SKU: `justspeaktoit-macos-1`
4. Click **Create**

### App Information
Fill in the following:

**Category:**
- Primary: Productivity
- Secondary: Utilities

**Content Rights:**
- Does not contain third-party content

**Age Rating:**
- Complete questionnaire (likely 4+)

### Pricing & Availability
- Price: Free (or select tier)
- Availability: All territories

### App Privacy
1. Go to **App Privacy** section
2. Click **Get Started**
3. Data types collected:
   - **Audio Data** - Used for primary app functionality (transcription)
     - Not linked to user identity
     - Not used for tracking
   - **Usage Data** - Analytics
     - Not linked to user identity

## Step 4: Prepare Store Listing

### Screenshots Required
| Size | Dimensions | Required |
|------|------------|----------|
| 13" MacBook Pro | 2880 x 1800 | ✓ Yes |
| 16" MacBook Pro | 3456 x 2234 | Optional |
| iMac 27" | 2560 x 1440 | Optional |

**Screenshot suggestions:**
1. Main dashboard showing recording interface
2. Live transcription in action
3. History view with past recordings
4. Settings showing API configuration
5. Voice output feature (if enabled)

### App Store Description

```
Just Speak to It transforms your voice into perfectly formatted text.

FEATURES:
• Live streaming transcription with real-time display
• Multiple AI transcription providers (Deepgram, OpenAI Whisper, Apple)
• Intelligent post-processing for formatting and corrections
• Global keyboard shortcut (Fn key) for instant recording
• Personal lexicon for custom vocabulary
• Cross-platform sync with iOS companion app
• Voice output with multiple TTS providers

PRIVACY FIRST:
• Audio is processed via your chosen cloud provider
• No audio is stored without your permission
• API keys stored securely in Keychain

PERFECT FOR:
• Writers and content creators
• Developers writing documentation
• Anyone who thinks faster than they type

Requires macOS 14.0 or later.
```

### Keywords (100 characters max)
```
transcription,voice,speech-to-text,dictation,AI,whisper,deepgram,recording,productivity
```

### Support URL
```
https://justspeaktoit.com/support
```

### Privacy Policy URL
```
https://justspeaktoit.com/privacy
```

## Step 5: Build and Archive

### Using Xcode
```bash
# Open workspace
open "Just Speak to It.xcworkspace"
```

1. Select **Product** → **Archive**
2. Wait for build to complete
3. Organizer window opens automatically

### Using Command Line
```bash
# Build archive
xcodebuild -workspace "Just Speak to It.xcworkspace" \
  -scheme "SpeakApp" \
  -configuration Release \
  -archivePath ~/Desktop/JustSpeakToIt.xcarchive \
  archive

# Export for App Store
xcodebuild -exportArchive \
  -archivePath ~/Desktop/JustSpeakToIt.xcarchive \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist \
  -exportPath ~/Desktop/JustSpeakToIt-AppStore
```

## Step 6: Upload to App Store Connect

### Using Xcode Organizer
1. In Organizer, select your archive
2. Click **Distribute App**
3. Select **App Store Connect** → **Next**
4. Select **Upload** → **Next**
5. Review and click **Upload**

### Using altool (CLI)
```bash
xcrun altool --upload-app \
  --file ~/Desktop/JustSpeakToIt-AppStore/JustSpeakToIt.pkg \
  --type macos \
  --apple-id "your-apple-id@example.com" \
  --password "@keychain:AC_PASSWORD"
```

### Using Transporter App
1. Download Transporter from Mac App Store
2. Sign in with your Apple ID
3. Drag your .pkg file into the window
4. Click **Deliver**

## Step 7: Submit for Review

1. Return to App Store Connect
2. Select your app → **macOS App** version
3. Select your uploaded build
4. Complete all required fields
5. Click **Submit for Review**

### Review Notes (if needed)
```
API keys are required to use the transcription features. 
For testing, demo keys can be provided upon request.

The app requires Accessibility access for global keyboard shortcuts 
and Microphone access for recording audio.
```

## Pre-Submission Checklist

- [ ] Version number updated (CFBundleShortVersionString)
- [ ] Build number incremented (CFBundleVersion)
- [ ] All usage descriptions filled in
- [ ] App icon included (1024x1024)
- [ ] Screenshots prepared (all required sizes)
- [ ] App Store description written
- [ ] Privacy policy URL valid
- [ ] Support URL valid
- [ ] Tested on macOS 14.0+
- [ ] Tested on Apple Silicon and Intel
- [ ] No crashes or major bugs
- [ ] Sandbox entitlements minimal and justified

## Common Rejection Reasons

1. **Guideline 2.1 - App Completeness**: App crashes or has bugs
2. **Guideline 2.3 - Accurate Metadata**: Screenshots don't match app
3. **Guideline 4.2 - Minimum Functionality**: App doesn't do enough
4. **Guideline 5.1.1 - Data Collection**: Privacy policy missing/incomplete
5. **Guideline 5.1.2 - Data Use**: Unclear what data is collected

## Post-Release

After approval:
1. Set release date (manual or automatic)
2. Monitor crash reports in Xcode Organizer
3. Respond to user reviews
4. Plan next version updates
