# Speak Privacy & Data Handling

## Overview

Speak is designed with privacy in mind. This document explains what data is collected, where it goes, and how you can control it.

## Audio Data

### What is captured?
- **Microphone audio** is captured only while actively transcribing (when you tap the record button)
- Audio is processed in real-time and is **not stored** on your device after transcription
- Apple Speech processes microphone audio on-device when the device and selected language support it. Its fallback can
  use Apple's speech-recognition servers. If you separately enable cloud post-processing or voice output, transcript or
  assistant-response text may also be sent to that feature's provider.

### Where does audio go?

| Provider | Data Location | Processing |
|----------|---------------|------------|
| Apple Speech | Device or Apple cloud | Audio is transcribed on-device when supported; otherwise Apple's speech service may process it |
| Deepgram | Cloud | Audio streamed to Deepgram for transcription |
| Cartesia | Cloud | Audio streamed to Cartesia for transcription |
| Gladia | Cloud | Audio streamed to Gladia for transcription |
| Modulate | Cloud | Audio streamed to Modulate for transcription |
| AssemblyAI | Cloud | Audio streamed to AssemblyAI for transcription |
| Soniox | Cloud | Audio streamed to Soniox for transcription |
| ElevenLabs | Cloud | Audio streamed to ElevenLabs for transcription |
| OpenAI | Cloud | Audio streamed to OpenAI for transcription |
| xAI | Cloud | Audio streamed to xAI for transcription |

This table covers live providers available in the iOS app. macOS also supports Speechmatics streaming. Selectable iOS
batch models upload recorded audio to OpenAI for supported OpenAI models or through OpenRouter for other remote models.
The in-app iOS live-provider disclosure derives its list from the same model catalogue and platform-support metadata
used by the transcription picker, so newly supported live providers appear automatically. When enabled,
post-processing sends transcript text to OpenRouter and voice output sends text to Soniox.

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
- **Apple Speech**: For language-model download when needed, and for recognition when on-device processing is unavailable
- **Cloud transcription providers**: When actively transcribing with a cloud model
- **Send to Mac**: Only on your local network (no internet required)
- **iCloud Sync**: When syncing settings (optional)

### What is sent to cloud providers?

When using a cloud transcription provider:
- Audio stream (in real-time)
- Language/model selection
- App-supplied language/model metadata, but no separate account identifier supplied by Speak. Spoken audio itself may
  contain names or other personal information.

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

### macOS diagnostics

Production macOS builds use Sentry's EU service for reliability monitoring. The
Sentry SDK sends:

- Crash and error reports
- Performance traces (sampled at 20%)
- Automatic app sessions, associated with a persistent random installation ID
- Automatic diagnostic breadcrumbs, and failed HTTP-request metadata for the
  app's own update domain only

Sentry is disabled in debug builds and test runs. `sendDefaultPii` is disabled,
and the data is not used to track users across other companies' apps or websites.
Just Speak to It does not send transcript text, microphone audio, clipboard
contents, API keys, email addresses, or names to Sentry. Every event passes
through a redaction step that removes credentials from request headers, URL query
items and breadcrumb data before transmission.

The macOS dashboard's transcription history and usage charts are stored locally;
they are not product-analytics events sent to the developer.

### Optional product analytics (direct-download macOS only)

The direct-download/Sparkle build offers an explicit opt-in to anonymous product
analytics hosted in PostHog EU Cloud (Frankfurt). Declining does not affect any
feature. Until you opt in, the app creates no analytics installation identifier,
queues no events and makes no PostHog request. You can withdraw consent at any
time in Settings; doing so immediately stops collection and deletes the local
analytics identifier and queued events.

The initial rollout sends only daily app activity, onboarding progress and the
first successful transcription. Properties are selected from a fixed catalogue
and use coarse buckets. Just Speak to It never sends transcripts, audio, prompts,
clipboard text, keystrokes, API keys, screen content, names or email addresses.
Each Mac uses a separate random identifier that is not synced through iCloud and
is not linked to Sentry. Raw product events are retained for no more than 12
months and are not used for advertising or cross-company tracking.

The Mac App Store build and all iOS/keyboard targets compile this transport out.

### iOS diagnostics

The iOS app does not currently initialise Sentry or another
developer-operated analytics SDK. Apple may provide the developer with
aggregated App Store and crash diagnostics under Apple's own privacy terms.

### Identifiability

The Sentry installation ID is random and is not an account identifier. Just
Speak to It does not set a Sentry user name or email address. Diagnostic data is
not linked to a known identity and is not used for advertising or cross-app
tracking.

## Questions?

For privacy questions, contact: [hello@justspeaktoit.com](mailto:hello@justspeaktoit.com)

---

*Last updated: August 2026*
