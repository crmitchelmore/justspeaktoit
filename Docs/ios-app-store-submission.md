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

The iPhone app has no local-network gateway, Bonjour transcript sender, or
browser, so its generated Info.plist declares neither
`NSLocalNetworkUsageDescription` nor `NSBonjourServices`. Public archive
verification rejects both unused declarations; the Mac receiver is separate.

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

The iOS app uses Apple CryptoKit for AES-GCM and HMAC-SHA256, Security for
Keychain/randomness, and URLSession for TLS. The PBKDF2 loop composes CryptoKit
HMAC calls; it does not embed a cipher implementation. Its package targets
(SpeakCore, SpeakSync, SpeakiOSLib) have no third-party crypto dependency.

Apple explicitly exempts encryption limited to the Apple operating system from
App Store Connect documentation. `ITSAppUsesNonExemptEncryption` is `false`
and no `ITSEncryptionExportComplianceCode` is emitted. The previous declaration
considered only purpose-based exemptions and missed this separate OS exemption.
Reassess before adding a non-system crypto implementation.

Source: [Apple encryption documentation requirements](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption).

## Device capabilities

`UIRequiredDeviceCapabilities` is `["arm64"]`. Tuist's default is `["armv7"]`, a
32-bit capability no device that can run this iOS 17, arm64-only app reports.

## Privacy policy

`https://justspeaktoit.com/privacy` is linked from Settings, both in the About
section and at the foot of the Privacy screen, through
the shared URL in `Sources/SpeakCore/PrivacyPolicy.swift`. App Review looks for the published
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
- **History and API keys in iCloud.** History, including transcript text,
  syncs to the user's own private CloudKit database automatically when the
  device is signed in to iCloud, unless the user turns off iCloud History Sync
  in Settings › Sync, which keeps History on the device. Encrypted API-Key Sync is opt-in and writes
  only passphrase-encrypted keys to the same private database. No app settings
  sync through iCloud. Data in the user's own iCloud account is not developer
  collection.

### Age rating

Nothing in the app moves it off **4+**, which is what the record already holds.
No violence, profanity, horror, gambling, contests, medical or drug content, no
in-app purchases and no unrestricted web access. Two answers to watch:

- **User-generated content: No.** Transcripts never travel between users.
- **Chat or AI chat: No.** The app does not include a chat or AI-chat interface.

### Content rights

**Does not use third-party content.** Already set correctly on the record.

### Export compliance

The app uses encryption, limited to Apple operating-system cryptography.
Select the OS-encryption exemption; the bundled `ITSAppUsesNonExemptEncryption`
value is `false`. See the implementation audit and Apple reference above.

### App Review Information

The notes on the record predate the custom keyboard, the camera QR transfer and
the current provider list. Replace them with something like this:

> Just Speak to It does not require an account, and no demo account is needed.
>
> Transcription without any API key: Apple Speech runs on device and is the
> default. Tap the microphone button to start and stop a recording. Cloud providers are
> optional. Dedicated review credentials and the matching model selection steps
> are supplied separately in private App Review information.
>
> Permissions and why each one is requested:
> - Microphone and Speech Recognition: recording and transcribing dictation.
> - Camera: Settings > Sync > Import from QR Code scans a QR code shown by the Mac app to
>   copy settings across. The camera is used for nothing else.
> - Local Network: there is no shipping Send to Mac sender or pairing screen on
>   iOS. Do not claim an available iPhone-to-Mac transfer workflow.
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

Apple explicitly requested API keys in the original rejection. Supply dedicated,
limited review credentials in private App Review information, with tested setup
steps; never commit those credentials.

### Privacy policy URL

The listing must point at `https://justspeaktoit.com/privacy`, the same document
the new in-app link opens from Settings.

## Listing metadata

Not in the repo's upload path: the release worker only writes What's New. Enter
or update these in App Store Connect › App Store › the version's English (U.K.)
localisation and App Information.

| Field | Value |
| --- | --- |
| Name (30) | Just Speak to It |
| Subtitle (30) | Private dictation, your keys |
| Category | Productivity (secondary: Utilities) |
| Keywords (100) | `dictation,speech to text,transcribe,voice typing,whisper,keyboard,notes,on-device,openai,deepgram` |
| Support URL | `https://justspeaktoit.com/support` (the July rejection cited the GitHub issues URL) |
| Marketing URL | `https://justspeaktoit.com` |
| Privacy Policy URL | `https://justspeaktoit.com/privacy` |
| Copyright | `2026` followed by the owner's legal name as on the developer account |

**Promotional text** (170):

> Speak and it is typed. Apple's on-device speech by default, or any cloud
> provider you hold the key to. No account, no subscription, no server in the middle.

**Description**:

> Just Speak to It turns your voice into text without an account and without a
> server in the middle.
>
> Tap the microphone and talk. Apple's on-device speech recognition is the
> default, so dictation works with no setup and no key. When you want a specific
> model, add your own key for a cloud provider in Settings and audio goes
> straight to that provider. Optional clean-up tidies the transcript with a
> language model you choose.
>
> Dictate anywhere:
> • Just Speak Keyboard hands dictation to the app and types the result into any text field
> • Start, stop and toggle recording from Shortcuts and the Action Button
> • A Live Activity shows recording progress on the Lock Screen and Dynamic Island
> • Recording continues when the screen locks
>
> History keeps every transcript on your device and syncs it through your own
> private iCloud, unless you turn that off. Already use the Mac app? Scan its QR code to
> copy your settings and keys across.
>
> No ads, no tracking, no analytics. Open source under the MIT licence.

## Screenshots

The iOS target ships on iPhone and iPad, so App Store Connect needs a 6.9-inch
iPhone set (1320 × 2868; 6.5-inch is the fallback) and a 13-inch iPad set
(2064 × 2752). Capture them from the real app with fictional History through the
Site Media workflow on a hosted runner:

```bash
gh workflow run site-media.yml --ref main -f ios_device="iPhone 17 Pro Max"
gh workflow run site-media.yml --ref main -f ios_device="iPad Pro 13-inch (M5)"
```

With `ios_device` set it captures only the iPhone/iPad app (light and dark) and
skips the Mac capture and clip rendering; download the `site-media-ios-*`
artefacts. The simulator name must match exactly; the job fails rather than
falling back to another size. The capture suite was written for iPhone, so
review the iPad frames before uploading. Never use screenshots that show real
History, keys or provider accounts.

## Historical App Store Connect observations

A prior audit observed App Store version **2.23.5**, created 30 January 2026,
in the **REJECTED** state and TestFlight **3.1.0 build 333**. At that audit,
the iOS app had no public release and the App Store record had one version.
These are historical observations. Fresh App Store Connect readback is required
to establish the current versions, review state, TestFlight build and public
availability before preparing a submission.

Resolution Center was read on 2 November 2026. Apple's 30 July review of
**2.23.5 (181)** reported these unresolved issues:

| Guideline | Review finding | Required verification before resubmission |
| --- | --- | --- |
| 4 — Design | Transcribe button absent on iPad Pro 11-inch (M4), iPadOS 26.6 | Verify the recording control on iPad in portrait and landscape, including a fresh install. |
| 2.1(a) — Completeness | Microphone tap displayed an error on iPad and iPhone 17 Pro Max | Complete fresh-install permission and real microphone transcription on supported hardware. Simulator transcript fixtures do not prove this. |
| 1.5 — Developer Information | GitHub issues URL did not provide adequate support information | Deploy and verify `https://justspeaktoit.com/support`, then update the listing's Support URL. |
| 2.1 — Information Needed | Apple requested API keys | Supply dedicated review credentials through private App Review information and verify the documented provider journey; do not ask reviewers to supply their own keys. |
| 5.1.1(ii) — Privacy | Camera purpose string did not explain its use with an example | Verify the signed bundle contains the current QR-code/settings/API-key-transfer explanation. |

The current source addresses the camera wording. The other rows require fresh
runtime, deployment or App Store Connect evidence; a merged change alone does
not close the rejection. Keep review credentials out of repository files,
public issues and screenshots.

For local release/reconciliation authentication, see the
[1Password credential setup](alpha-stable-release-trains.md#local-apple-release-credentials-from-1password).
Authenticate CLI access with the configured service account or desktop-app
integration before fresh readback; configured references alone do not prove
credential or API access.

## Regression cover

The July rejection remains an `UNRESOLVED_ISSUES` submission. After the owner
approves a corrected candidate and the review findings are resolved, the release
worker reuses that submission and its exact app-version item, marks the item
resolved, and verifies `READY_FOR_REVIEW` before resubmitting. It refuses
ambiguous active submissions or unrelated items; it never removes them. See
[Apple's resubmission procedure](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/manage-a-submission-with-unresolved-issues)
and [review-item update contract](https://developer.apple.com/documentation/appstoreconnectapi/reviewsubmissionitemupdaterequest/data-data.dictionary/attributes-data.dictionary).

Stable candidate 3 archived successfully on 30 October 2026 but stopped before
upload with `Extension SpeakReleaseTrain mismatch`. The widget's source plist
omitted the Stable train; Alpha generation supplied its own value and hid the
gap. Keep the explicit Stable default in the widget plist and the actual-plist
archive regression in `scripts/tests/release-train-archive.test.mjs`. Preserve
the archive identity check; a successful archive alone is not upload readiness.

`Tests/SpeakCoreTests/IOSAppStoreComplianceTests.swift` asserts each of the
above that lives in the repo. It runs in the macOS test job.
