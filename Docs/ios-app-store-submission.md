# iOS App Store submission readiness

What App Review and the App Store Connect upload pipeline check that the repo
controls, where each answer lives, and what is still owed outside the code.

## Purpose strings (guideline 5.1.1)

Every purpose string is declared in `Project.swift` on the `SpeakiOS` target and
is read verbatim by App Review. A string must name the data, the feature that
needs it and where the data goes.

| Key | Feature that triggers it |
| --- | --- |
| `NSMicrophoneUsageDescription` | Recording for transcription; discloses that audio reaches the chosen provider |
| `NSSpeechRecognitionUsageDescription` | Apple speech recognition, including its server-side path |
| `NSCameraUsageDescription` | `QRScannerCoordinator`, reading the configuration QR code the Mac app shows |
| `NSLocalNetworkUsageDescription` | Send to Mac, paired with `NSBonjourServices` |

Two failure modes to avoid. A string that denies using the capability at all
("a linked library requires this declaration") is a rejection. So is one that
omits off-device transmission when the feature transmits.

## Purpose strings in extensions

Apple scans each binary in the upload separately. The keyboard extension
compiles `KeyboardDictationEngine.swift` in every configuration, so its binary
references `AVAudioApplication.requestRecordPermission` and `SFSpeechRecognizer`
even when the `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE` flag is off and the handoff
path is the only one reachable. The extension therefore always ships
`JustSpeakKeyboard/Info.plist`, which declares both strings. Gating them on the
flag produces ITMS-90683 on upload and traps the dictation path at runtime.

## Privacy manifests

Three bundles ship a `PrivacyInfo.xcprivacy`, one per binary:

- `SpeakiOSApp/PrivacyInfo.xcprivacy`
- `JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy`
- `JustSpeakKeyboard/PrivacyInfo.xcprivacy`

Both extensions link SpeakCore, which reads the App Group defaults and file
attributes, so both declare the matching required-reason categories. A missing
declaration earns ITMS-91053.

The app manifest declares two collected data types. Audio data covers the
recording sent to the transcription provider. Other user content covers
transcript text, which leaves the device separately when post-processing sends
it to a language model or voice output sends it to a speech provider. The App
Store Connect nutrition label must agree with this file.

## Export compliance

The app implements AES-GCM and PBKDF2 through CryptoKit to encrypt the user's
own API keys for end-to-end encrypted iCloud and CloudKit key sync.
Confidentiality of user data is not one of the Category 5 Part 2 exemptions
Apple lists, which are authentication, digital signature, DRM, medical and
banking. `ITSAppUsesNonExemptEncryption` is therefore `true`.

Consequence: every build sits in Missing Compliance in App Store Connect until
the export questions are answered. If documentation is required, submit it in App Store Connect. After Apple
approves it, use the key value shown beside the approved documentation:

```sh
TUIST_ITS_ENCRYPTION_COMPLIANCE_CODE=<code from App Store Connect> tuist generate
```

An unset or empty value leaves the key out of the bundle, which is deliberate: a
placeholder would ship an invalid code.

## Device capabilities

`UIRequiredDeviceCapabilities` is `["arm64"]`. Tuist's default is `["armv7"]`, a
32-bit capability no device that can run this iOS 17, arm64-only app reports.

## Privacy policy

`https://justspeaktoit.com/privacy` is linked from Settings, both in the About
section and at the foot of the Privacy screen, through
`Sources/SpeakiOS/Views/PrivacyPolicy.swift`. App Review looks for the published
policy from inside the app, not only in the listing metadata.

## The answers to every App Store Connect compliance question

Everything below is derived from the code, and each answer names the file or
behaviour it rests on. Read the export compliance section before acting: the
classification is the developer's legal responsibility, and Apple says so
explicitly. These are the facts and a reading of them, not legal advice.

### App privacy, the nutrition label

App Privacy is not in the App Store Connect API, so this is entered by hand. It
must agree with `SpeakiOSApp/PrivacyInfo.xcprivacy`.

**Data used to track you: none.** No advertising identifier, no ATT prompt, no
tracking domains. `NSPrivacyTracking` is false.

**Data linked to you: none.** Nothing collected is tied to an identity the app
holds.

**Data not linked to you: two types.**

| Type | Purpose | Basis in the code |
| --- | --- | --- |
| Audio Data | App Functionality | Recordings go to the transcription provider chosen in Settings |
| Other User Content | App Functionality | Post-processing sends transcript text to a language model; voice output sends it to a speech provider |

Answer **No** to every other category, including Contact Info, Health, Financial
Info, Location, Contacts, Browsing History, Search History, Identifiers, Usage
Data, Diagnostics, Purchases and Sensitive Info. Three of those deserve the
reasoning written down, because they look like yes and are not:

- **Identifiers.** `DeviceIdentityStore` keeps a device id, but it lives in the
  Keychain and is only sent to a paired Mac over the local network. It never
  reaches a server of ours.
- **Usage Data and Diagnostics.** The iOS app initialises no analytics or crash
  SDK. Sentry is linked by the macOS target only. This answer changes the day
  issue #776 ships opt-in PostHog to iOS.
- **History and settings in iCloud.** CloudKit writes to the user's own private
  database. Data in the user's own iCloud account is not developer collection.

### Age rating

Nothing in the app moves it off **4+**, which is what the record already holds.
No violence, profanity, horror, gambling, contests, medical or drug content, no
in-app purchases and no unrestricted web access. Two answers to watch:

- **User-generated content: No.** Transcripts never travel between users.
- **Chat or AI chat: No.** The OpenClaw chat surface is behind the
  `SHOW_OPENCLAW_TAB` build flag and is absent from release builds. If that flag
  is ever switched on for a shipping build, re-answer this question first.

### Content rights

**Does not use third-party content.** Already set correctly on the record.

### Export compliance

The two questions and their answers:

1. **Does your app use encryption?** **Yes.** CryptoKit AES-GCM and PBKDF2
   encrypt the user's own API keys for the end-to-end encrypted CloudKit key
   sync, alongside OS-provided HTTPS and Keychain.
2. **Does it qualify for an exemption under Category 5 Part 2?** **No.** Apple
   lists five: medical end-use, intellectual property protection,
   authentication or digital signature or decryption only, banking and money
   transactions, and short key lengths. Encrypting user secrets for
   confidentiality with AES-256-GCM is none of them.

Use the questions in App Store Connect to determine which documentation is
required for this app. Submit any required documents there and, after Apple
approves them, inject the key value shown beside the approved documentation:

```sh
TUIST_ITS_ENCRYPTION_COMPLIANCE_CODE=<code from App Store Connect> tuist generate
```

See [Apple's encryption documentation procedure](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).
Any applicable export classification, reporting or country-specific obligations
are separate from this Apple key. A BIS report does not issue the key used by
`ITSEncryptionExportComplianceCode`. Confirm those obligations for the actual
product and distribution territories before submission.

### App Review Information

The notes on the record predate the custom keyboard, the camera QR transfer and
the current provider list. Replace them with something like this:

> Just Speak to It does not require an account, and no demo account is needed.
>
> Transcription without any API key: Apple Speech runs on device and is the
> default. Tap Transcribe to start and stop a recording. Cloud providers are
> optional and need the reviewer's own key, entered in Settings > API Keys.
>
> Permissions and why each one is requested:
> - Microphone and Speech Recognition: recording and transcribing dictation.
> - Camera: Settings > Transfer from Mac scans a QR code shown by the Mac app to
>   copy settings across. The camera is used for nothing else.
> - Local Network: Send to Mac transfers a finished transcript to a paired Mac
>   over Bonjour. Optional, and off until configured.
> - Background audio: recording continues when the screen locks, which is the
>   point of a dictation app.
>
> Just Speak Keyboard is a custom keyboard extension. Full Access is used only
> to reach the shared App Group container, so the keyboard can hand dictation to
> the container app and receive the text back. The keyboard is fully usable
> without Full Access: it falls back to the handoff path and tells the user what
> is unavailable. It sends nothing to any server of ours.
>
> A Live Activity shows recording progress on the Lock Screen and Dynamic
> Island. Start Recording, Stop Recording, Toggle Recording and transcript-copy
> actions are registered in Shortcuts, which is how the Action Button flow works.

If cloud transcription should be reviewable, attach a provider key in the review
notes rather than leaving the reviewer on Apple Speech alone.

### Privacy policy URL

The listing must point at `https://justspeaktoit.com/privacy`, the same document
the new in-app link opens from Settings.

## The rejection already on the record

The iOS app has never been released. App Store version **2.23.5**, created
30 January 2026, is in the **REJECTED** state, and it is the only version the
record has ever had. Everything since has gone to TestFlight, currently 3.1.0
build 333.

The reason is not recoverable from here. The App Store Connect API does not
expose Resolution Center, and no rejection email survives in the mailbox. Read
Resolution Center in App Store Connect before preparing a new submission,
because the original reason may still apply and none of the work in this
document addresses it.

## Regression cover

`Tests/SpeakCoreTests/IOSAppStoreComplianceTests.swift` asserts each of the
above that lives in the repo. It runs in the macOS test job.
