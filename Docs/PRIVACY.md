# Speak Privacy & Data Handling

## Overview

Speak is designed with privacy in mind. This document explains what data is collected, where it goes, and how you can control it.

## Audio Data

### What is captured?
- **Microphone audio** is captured only while actively transcribing (when you tap the record button)
- Audio is processed in real-time and is **not stored** on your device after transcription
- When using on-device Apple Speech, audio **never leaves your device**

### Where does audio go?

| Provider | Data Location | Processing |
|----------|---------------|------------|
| Apple Speech | On-device | Audio stays on your iPhone/Mac |
| Deepgram | Cloud (US) | Audio streamed to Deepgram servers |

## API Keys

### Storage
- API keys are stored in the **iOS/macOS Keychain**, Apple's secure credential storage
- Keys are encrypted at rest and protected by your device passcode/biometrics
- Keys can optionally sync via **iCloud Keychain** (end-to-end encrypted)

### What we never do
- We never transmit your API keys to our servers
- We never log or store API keys in plaintext
- We never share your credentials with third parties

## Network Activity

### When does Speak connect to the internet?
- **Apple Speech**: Only for initial language model download (if needed)
- **Deepgram**: When actively transcribing via Deepgram
- **Send to Mac**: Only on your local network (no internet required)
- **iCloud Sync**: When syncing settings (optional)

### What is sent to cloud providers?

When using Deepgram:
- Audio stream (in real-time)
- Language/model selection
- No personal identifiers

## Local Network (Send to Mac)

### How it works
- Uses Bonjour for device discovery (local network only)
- Connection authenticated with pairing code
- Transcript text sent directly to your Mac
- **No data leaves your local network**

### Permissions
- iOS will prompt for Local Network access on first use
- Required only for "Send to Mac" feature
- Can be disabled in Settings → Privacy & Security → Local Network

## Data You Can Delete

### Clear all API keys
Settings → API Keys → Clear each key individually

### Clear pairing data
Settings → Send to Mac → (macOS: regenerate pairing code)

### Clear all app data
Uninstall and reinstall the app, or use iOS Settings → Speak → Reset

## Analytics & Telemetry

Speak does **not** collect:
- Usage analytics
- Crash reports (beyond what Apple collects)
- Personal information
- Transcription content

## Questions?

For privacy questions, contact: [your contact email]

---

*Last updated: January 2026*
