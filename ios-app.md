# iOS Speak App Plan (Live Transcription + Config Sync)

## 0) Goals

1. **iOS app** that can do **livestreaming transcription** (partial updates while speaking) with a UX that’s genuinely useful on iPhone.
2. **Configuration sync** between macOS and iOS, especially **API keys** (Deepgram, Rev.ai, OpenRouter, etc.) and core preferences (models, locale, post-processing toggles).
3. Reuse as much of the existing macOS code as possible (notably `TranscriptionManager`, provider registry, and `SecureAppStorage`).

## 1) Reality constraints (important)

iOS has hard limits that shape the product:

- **No system-wide text insertion** like macOS Accessibility-based “type into any app”. iOS apps generally cannot write into other apps’ text fields.
- **Background mic capture** is possible only under specific conditions (Audio background mode), is interruption-prone (calls, Siri, Bluetooth route changes), and must be handled carefully.
- **Capturing audio from other apps** (e.g., Zoom/Teams audio) is generally **not possible**. Expect “phone-on-table” meeting capture via the mic.

So the iOS product must be designed around: **(a) capture + display**, **(b) share/export**, **(c) copy-to-clipboard**, and **(d) tight “handoff to Mac” flows**, rather than pretending we can “type anywhere”.

## 2) Product concept: how transcription is actually used on iOS (creative but realistic)

### 2.1 Primary mode: “Session” capture with *Live Activity + Clipboard*
**Core idea:** iOS Speak runs a transcription session and continually updates a Live Activity (Lock Screen / Dynamic Island) with:

- current status (listening / paused / offline)
- last line / last ~160 chars of transcript
- a big action: **Copy last sentence** (or “Copy last 15s”) to clipboard
- a second action: **Send to Mac** (handoff) / “Append to current note”

This makes transcription usable while the phone is locked or you’ve switched apps.

Implementation notes:
- The app itself owns microphone capture (in foreground or with Audio background mode).
- Live Activity updates should be **throttled** (e.g., every 1–2 seconds, or on punctuation/final segments) to stay within ActivityKit expectations.
- “Copy last sentence” is an AppIntent that updates clipboard inside the host app when invoked.

### 2.2 Secondary mode: “PiP Transcript Card” (optional, advanced)
If we want a more “always visible” experience without illegal overlays:

- Run a tiny “video” render of the transcript and present it as **Picture-in-Picture**.
- User can float the transcript card above other apps.

Caveats:
- PiP is designed for video; implementing a text-rendered video stream is extra work.
- PiP controls are not fully customizable.

Recommendation: treat PiP as a later enhancement; Live Activity gets us 80% of the value with less risk.

### 2.3 “Send to Mac” as the true cross-app workflow
Since iOS can’t type into arbitrary fields, we make the *Mac* the place where “insert into active app” happens.

Flow:
- iOS transcribes.
- iOS streams final text chunks to the macOS app (near-real-time) using a secure channel.
- macOS app uses its existing output system (`SmartTextOutput`, Accessibility/Paste) to insert where the cursor is.

This effectively turns iOS into a **wireless microphone + speech front-end** for the Mac.

## 3) Architecture: split into shared Core + two UIs

### 3.1 Create a shared SwiftPM module
Refactor into:

- `SpeakCore` (new library target)
  - `TranscriptionManager` + live controllers (Apple Speech, Deepgram live)
  - `TranscriptionProviderRegistry` + batch providers (Rev.ai, OpenAI, etc.)
  - `OpenRouterAPIClient`
  - `SecureAppStorage` (made cross-platform; see below)
  - shared models (`HistoryItem`, `TranscriptionResult`, etc.) where useful

- `SpeakApp` (macOS app target)
  - mac-only things: status bar, hotkeys, accessibility insertion, HUD window

- `SpeakAppiOS` (new iOS app target)
  - SwiftUI UI for sessions + history + settings
  - Live Activity extension target

This keeps business logic unified while allowing platform-specific UX.

### 3.2 Conditional compilation
Use `#if os(iOS)` / `#if os(macOS)` for:

- audio device selection (`AudioInputDeviceManager` differs)
- permissions differences
- keychain query attributes

Goal: the transcription pipeline code remains shared.

## 4) Livestreaming transcription on iOS (implementation plan)

We already have:
- **Apple Speech live** via `SFSpeechRecognizer` + `AVAudioEngine` (currently `NativeOSXLiveTranscriber`).
- **Deepgram streaming live** via `DeepgramLiveController` which resamples to 16kHz PCM16.

### 4.1 iOS Live transcription controller
Create `NativeIOSLiveTranscriber` (or rename to `NativeAppleLiveTranscriber`) that:

- uses `AVAudioSession` configuration (`.playAndRecord`, `.measurement`, `allowBluetooth` as needed)
- handles interruptions (phone calls, Siri), route changes, and “recording permission changed”
- uses `SFSpeechAudioBufferRecognitionRequest` with partial results

Keep interface identical to existing `LiveTranscriptionController` so `SwitchingLiveTranscriber` works on both platforms.

### 4.2 Deepgram on iOS
`DeepgramLiveController` should mostly work; add iOS-specific audio-session setup and make sure background audio behavior is correct.

### 4.3 “Model selection” parity
Reuse `AppSettings.liveTranscriptionModel`.
- default on iOS should be **Apple on-device** for latency + reliability
- allow Deepgram live when key is present

### 4.4 Session semantics
On iOS, a “session” should produce:
- incremental partial transcript
- a final transcript
- optional audio file (user toggle; can be large; default off)

Store sessions locally first; optional sync later.

## 5) Syncing configuration between macOS and iOS (especially API keys)

### 5.1 Split “preferences” vs “secrets”
- **Preferences** (locale, selected models, toggles): sync via **iCloud Key-Value Store** or **CloudKit private DB**.
- **Secrets** (API keys): sync via **iCloud Keychain** or a **manual secure transfer**.

### 5.2 Recommended approach for API keys: Shared Keychain Access Group + iCloud Keychain
Today macOS stores one consolidated blob:
- service: `com.github.speakapp.credentials`
- account: `speak-app-secrets`
- payload: semicolon-delimited `NAME=value` pairs

Plan to share across devices:
1. Enable **Keychain Sharing** entitlement in both apps.
2. Use a shared access group, e.g. `$(AppIdentifierPrefix)com.speak.sharedkeychain`.
3. Mark the item **synchronizable** (`kSecAttrSynchronizable = true`) so it can travel via iCloud Keychain.
4. Keep accessibility at `kSecAttrAccessibleAfterFirstUnlock`.

Notes:
- This requires both apps to be signed under the same Team ID and have matching entitlements.
- iCloud Keychain must be enabled on the user’s Apple ID (we should detect and message if not).

### 5.3 Fallback if iCloud Keychain is unavailable: QR “pair and transfer”
Provide a one-time secure transfer flow:
- macOS app shows a QR code containing an encrypted payload of the secrets/settings.
- iOS app scans, decrypts, stores into its keychain.

Crypto approach:
- Use CryptoKit.
- Generate an ephemeral keypair per transfer; encrypt via X25519 + ChaChaPoly.
- QR contains public key + ciphertext.

This avoids storing secrets in CloudKit directly.

### 5.4 Syncing preferences
Implement a `SettingsSync` layer:
- Use `NSUbiquitousKeyValueStore` for small preferences (strings/bools).
- For structured data (pronunciation dictionary, lexicon), use CloudKit later.

Conflict resolution:
- last-write-wins per field.
- display a “Synced from Mac” / “Synced from iPhone” toast for transparency.

## 6) iOS UX plan (screens)

### 6.1 Home: “New Session”
- Large Start/Stop button
- live scrolling transcript
- quick actions: Copy, Share, Send to Mac
- indicator: selected model (Apple/Deepgram), locale, mic level

### 6.2 History
- list of sessions (timestamp, duration, model)
- open detail view: transcript + export options

### 6.3 Settings
- “Sync” section: status, last sync time, re-pair
- “API Keys” section: view which providers are configured (don’t show raw values)
- “Transcription” section: choose live model, language, punctuation options

### 6.4 Live Activity
- status + last line
- buttons: Copy last sentence, Pause/Resume, Send to Mac

## 7) “Send to Mac” transport options

### Option A (recommended): CloudKit “mailbox”
- iOS writes transcript chunks to CloudKit private DB
- macOS watches for updates and consumes them

Pros: works across networks, no local discovery needed.
Cons: latency + CloudKit complexity; needs careful cost/limits handling.

### Option B: Local network (Bonjour + WebSocket)
- macOS advertises a service
- iOS connects when on same Wi‑Fi, streams chunks directly

Pros: low-latency.
Cons: NAT/VPN issues; not always available.

### Option C: Push-to-Mac via APNs (not recommended early)
Adds infra.

Recommendation: implement **B first** for “same-room” speed, and optionally add **A** later for “anywhere” reliability.

Security:
- Pairing step establishes a shared secret.
- Each message is authenticated (HMAC) and optionally encrypted.

## 8) Milestones

### Milestone 1 — iOS MVP (local-only)
- iOS app target
- on-device live transcription (Apple Speech)
- transcript view + copy/share
- local session history

### Milestone 2 — Provider parity
- Deepgram live on iOS
- batch providers (Rev.ai/OpenAI/OpenRouter) on iOS
- API key entry in iOS settings (stored via keychain)

### Milestone 3 — Config sync
- shared keychain + iCloud Keychain sync OR QR transfer
- preferences sync (KV store)

### Milestone 4 — Live Activity
- lock screen / Dynamic Island controls
- copy last sentence

### Milestone 5 — Send-to-Mac
- Bonjour/WebSocket transport
- macOS “remote input” mode: inserts received transcript into active app via existing `SmartTextOutput`

## 9) Testing & validation

- Unit tests in `SpeakCore` for:
  - keychain serialization format (round trip)
  - provider selection logic (`TranscriptionProviderRegistry`)
- Manual test matrix:
  - permissions denied / granted
  - interruptions (call, Siri)
  - background/lock screen behavior
  - AirPods/Bluetooth route switching
  - iCloud Keychain on/off

## 10) Open questions

1. iOS minimum version? (Recommendation: iOS 17+ if we want a clean Live Activity + modern APIs.)
2. Do we need speaker diarization on iOS (Rev.ai supports it, but mic-only capture may limit usefulness)?
3. Should iOS record and keep audio by default (storage/privacy trade-off)?
4. Is “Send to Mac” expected to be near-real-time (stream) or “send final transcript only”?

