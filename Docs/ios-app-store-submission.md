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
| `NSLocalNetworkUsageDescription` | **Send to Mac** (#1640): finding the user's Mac over Bonjour and sending it a transcript |

`NSBonjourServices` lists only the train's Send to Mac service
(`transportServiceType` in `ReleaseTrains.json`, for example `_speakalpha._tcp`).
`scripts/verify-release-train-archive.py` fails an iOS archive whose purpose
string is missing or whose Bonjour list differs from that one service.

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

The app and each enabled extension ship their own `PrivacyInfo.xcprivacy`:

- `SpeakiOSApp/PrivacyInfo.xcprivacy`
- `JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy`
- `JustSpeakKeyboard/PrivacyInfo.xcprivacy`
- `JustSpeakShare/PrivacyInfo.xcprivacy` (optional)
- `JustSpeakWatch/PrivacyInfo.xcprivacy` (optional)
- `JustSpeakWatchWidget/PrivacyInfo.xcprivacy` (optional)

Apple scans each binary, including statically linked SpeakCore and SpeakiOSLib
code, so every bundle declares the required-reason categories its own and linked
sources reference. A missing declaration earns ITMS-91053.
`Tests/SpeakCoreTests/RequiredReasonAPIManifestTests.swift` maps each bundle to
its source roots and fails when a category is referenced but not declared, or a
reason is not an approved first-party code for its category.

The app, keyboard and phone widget declare active keyboards
(`UITextInputMode.activeInputModes`) under `54BD.1`: the keyboard and the
keyboard setup screen read the count to decide whether dictation can hand back
to the previous keyboard, which changes what the user sees. The widget links
SpeakiOSLib, which contains that setup screen. `3EC4.1` is not used because a
systemwide keyboard is not the app's primary functionality.

The app also declares system boot time under `35F9.1`: shared transcription
retry helpers use uptime to measure elapsed time. They do not transmit raw
uptime. This is the timer/elapsed-event reason in Apple's
[required-reason API reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
The keyboard, phone widget and Share extension link SpeakCore, so they declare
`35F9.1` as well. The Share extension stages a user-selected file locally, but
its linked SpeakCore binary retains UserDefaults/AppStorage and App Group file
attribute references, so it declares own-app and App Group defaults reasons and
`C617.1` too. Watch transfers to the user's
paired phone. Neither declares direct service collection; Watch does not
declare required-reason APIs absent from its current code and linked binary.

The app manifest declares six collected data types. Audio data covers the
recording sent to the transcription provider. Other user content covers
transcript text, which leaves the device separately when post-processing sends
it to a language model or voice output sends it to a speech provider. Crash
and performance data, other diagnostics and the installation ID cover the shared Sentry configuration. The App Store
Connect nutrition label must agree with this file.

macOS has separate manifests under `Sources/SpeakApp/Resources/AppStore/` and
`Direct/`. Tuist selects exactly one and packages it at
`Contents/Resources/PrivacyInfo.xcprivacy`; SwiftPM includes the Direct resource.
Both declare cloud audio/text and installation-linked diagnostics. Direct
additionally declares opt-in product interactions and the Analytics purpose
for its separate, resettable installation ID. These identifiers are not used
for cross-app tracking. The `APP_STORE` build excludes the product-analytics
transport and its Analytics-purpose declarations, not Sentry diagnostics.
The Mac App Store surface remains retired from the
release trains; maintaining its build configuration does not re-enable it.
See [Apple's manifest placement rules](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
and [data-use declarations](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests).

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
the shared URL in `Sources/SpeakCore/App/PrivacyPolicy.swift`. App Review looks for the published
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

**Data not linked to you: two content types.** These declarations cover the
app's provider routes; verify the selected providers' practices as part of
the candidate privacy report and disclosure review.

| Type | Purpose | Basis in the code |
| --- | --- | --- |
| Audio Data | App Functionality | Recordings go to the transcription provider chosen in Settings |
| Other User Content | App Functionality | Post-processing sends transcript text to a language model; voice output sends it to a speech provider |

**Data linked to you: four diagnostic/identifier types.** Collection is
optional and off until the user agrees to **Send crash reports and
diagnostics** (first-run onboarding, a one-time prompt for existing users, and
Settings › Privacy); `SentryManager.start()` does nothing before that, and
turning it off closes the SDK and deletes its on-device queue, crash reports and
installation ID. Apple's label still declares the types, because a consenting
user's data is collected. Sentry's
`SentryClient` supplies a random installation ID when the app has not assigned
a user, and `SentryHub` puts that ID in release-health sessions. Neither
`sendDefaultPii = false` nor credential scrubbing removes that linkage.
Apple's [linked-data definition](https://developer.apple.com/app-store/app-privacy-details/#linked-data)
includes linkage through a device, not only a real-world name.

| Type | Purpose | Basis in the code |
| --- | --- | --- |
| Crash Data | App Functionality | Sentry crash/error reports associated with the installation ID |
| Performance Data | App Functionality | Sentry samples 20% of launch and network timings |
| Other Diagnostic Data | App Functionality | Diagnostic context and release-health sessions, also declared by the Sentry SDK |
| Device ID | App Functionality | Random Sentry installation ID; not IDFA, IDFV or a hardware identifier |

Answer **No** to every other category, including Contact Info, Health, Financial
Info, Location, Contacts, Browsing History, Search History, Usage
Data, Purchases and Sensitive Info. Distinguish these flows when entering the
answers:

- **Identifiers.** Declare Sentry's installation ID as Device ID above.
  Separately, `DeviceIdentityStore` keeps a pairing device ID in the
  Keychain and only sends it to a paired Mac over the local network.
- **Usage Data and Diagnostics.** The iOS app initialises no product-analytics SDK, so
  Usage Data stays No until issue #776 ships opt-in PostHog to iOS. The app
  (not its extensions) runs Sentry after the diagnostics opt-in, sharing the
  Mac's `SentryManager` consent gate, configuration and credential scrubber, so
  Diagnostics declares Crash Data, Performance Data and Other Diagnostic Data as
  above.
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
> default. Tap **Transcribe** at the bottom of the main screen to start, and Stop to finish. Cloud providers are
> optional. Dedicated review credentials and the matching model selection steps
> are supplied separately in private App Review information.
>
> Permissions and why each one is requested:
> - Microphone and Speech Recognition: recording and transcribing dictation.
> - Camera: Settings > Sync > Import from QR Code scans a QR code shown by the Mac app to
>   copy settings across. The camera is used for nothing else.
> - Local Network: Settings > Sync & Transfer > Send to Mac finds the user's Mac on the
>   local network and pairs with the six-digit code the Mac shows. A History
>   item's context menu then sends that transcript to the paired Mac. It needs
>   the free direct-download Mac app from justspeaktoit.com with Send to Mac
>   turned on; nothing else is sent over the local network.
> - Background audio: recording continues when the screen locks, which is the
>   point of a dictation app.
>
> Just Speak Keyboard is a custom keyboard extension. Full Access is used only
> to reach the shared App Group container, so the keyboard can hand dictation to
> the container app and receive the text back. The keyboard is fully usable
> for editing and switching keyboards without Full Access; dictation is disabled
> with an explanation. The extension sends nothing to any server of ours.
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
> No ads, no cross-app tracking, no product analytics. Crash reports are sent only
> if you agree, and you can turn them off at any time. Open source
> under the MIT licence.

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
artefacts. Runs for different devices use separate concurrency groups, so both
can be dispatched at once. The simulator name must match exactly; the job fails rather than
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

## App Review rejection replies

Paste these into Resolution Center for the matching submission. Each one
describes the change made in the build being resubmitted, so upload a new
build containing it first, and replace the App Review Information notes with the
text in [App Review Information](#app-review-information) (iOS) or the
`scripts/mac-review-notes.rb` text (Mac).

### iOS 2.23.5, Guideline 4 — Design (Transcribe button on iPad)

What changed: the build Apple reviewed put recording behind a single
**Transcribe** tab. On iPadOS 18 and later a `TabView` draws its tabs as a
floating bar at the top of the window, so the control Apple looked for was not
where it sits on iPhone. The tab bar has since been removed. The main screen now
has one primary button, labelled **Transcribe** with a microphone icon, pinned to
the bottom of the screen. It is not inside a tab bar, so it stays there in every
size class, in both orientations and in Split View and Stage Manager. Its title comes from the shared `ForegroundRecordControl`
policy, which `ForegroundRecordControlTests` covers. The app no longer nests two
`NavigationStack`s around the main screen. The fix has not yet been tried on an
iPad: complete the `ipad-transcribe-control-first-run` manual check on the
candidate build before you send either iOS reply.

> Thank you for the review. In the build you reviewed, recording sat behind a
> single "Transcribe" tab, which iPadOS draws as a tab bar at the top of the
> window. We have removed the tab bar. The main screen now has one button,
> labelled "Transcribe" with a microphone icon, fixed to the bottom of the screen
> on iPhone and iPad, in portrait and landscape, and in Split View and Stage
> Manager. To try it: open the app and tap Transcribe at the bottom of the
> screen; tap Stop to finish.

### iOS 2.23.5, Guideline 2.1(a) — App Completeness (error on Microphone tap)

What changed: transcription needs no account or API key; on-device Apple Speech
is the default model. The first tap asks for microphone and speech recognition
access. If Apple's on-device speech assets are not installed yet, the app falls
back to Apple's speech recogniser. If that recogniser is unavailable as well, the
alert offers **Prepare Apple Model**, which downloads the assets. If access is
denied, the alert explains this and offers **Open Settings**. Start-failure
alerts are titled **Can't Start Recording**, not a bare "Error". iPad copy no
longer mentions "this iPhone" or the Dynamic Island (#1598, fixed in #1645).

> Thank you for the review. Just Speak to It needs no account or API key:
> on-device Apple Speech is the default. To test: open the app, tap Transcribe
> at the bottom of the screen, allow microphone and speech recognition access
> when asked, speak a sentence, then tap Stop. The transcript appears on screen
> and in History. If access is declined, the app explains why it cannot record
> and offers a button to open Settings. If the device has not yet downloaded
> Apple's on-device speech model, the app uses Apple's speech recogniser instead,
> or offers a "Prepare Apple Model" button that downloads it. Optional cloud
> providers, and the credentials for them, are described in App Review
> Information.

### Mac App Store — `com.apple.security.network.server`

Applies to the stable record (`com.justspeaktoit.mac.appstore`) and the Alpha
record. Apple documents the entitlement as allowing "other computers to
initiate network connections to your sandboxed app"
([network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)).
Only the direct-download build's **Send to Mac** receiver listened (a
Network.framework Bonjour listener for `_speakalpha._tcp`); the iPhone and iPad
sender (#1640) pairs only with that direct-download build. The App Store build therefore drops the entitlement,
`NSLocalNetworkUsageDescription` and `NSBonjourServices`, and compiles out the
receiver, its Settings card and its search entry (`SendToMacAvailability`).
`EntitlementsTests`, `AppStoreInfoPlistTests` and
`scripts/verify-release-train-archive.py` fail if any of them returns. The local
automation interface uses a UNIX domain socket in the app container, which needs
no network entitlement. `scripts/mac-review-notes.rb` adds the network
explanation below to the App Review Information notes and replaces the earlier
listener note.

> Thank you for the review. The new build removes the
> com.apple.security.network.server entitlement. The Mac App Store version
> accepts no incoming network connections: it has no network listener, Bonjour
> service or "Send to Mac" receiver, which is a feature of the direct-download
> version only. The app keeps com.apple.security.network.client for outgoing
> HTTPS and WebSocket connections to the speech-to-text and text-processing
> providers the user chooses in Settings. With the default on-device Apple Speech
> model, transcription needs no account, API key or network connection.

## Regression cover

Apple's `IntentDescription` documentation requires a short, sentence-case
description ending with a period:
[IntentDescription](https://developer.apple.com/documentation/appintents/intentdescription).
An App Store Connect ITMS-90626 upload notice for iOS 3.2.0 (build 1000.1.1)
also rejected App Intent descriptions containing `iPhone` or `Siri`. The
macOS-runnable `testAppleAppIntentDescriptionsAvoidRejectedTerms` scans app
and extension sources for both platforms. It checks those two rejected terms
and the final period, and fails unsupported description expressions rather
than silently omitting them. It does **not** establish sentence case,
shortness, localized compiler metadata, or every App Store validation rule.

The same notice came back for builds 1000.1.4 onward, which re-uploaded a
source from before the fix. Apple publishes no list of the terms it rejects,
so `scripts/ios/check-app-intents-terms.py` (run by `make lint`) applies a
conservative one: Siri and Apple device names (iPhone, iPad, iPod, Apple
Watch, Apple TV, Apple Vision, Vision Pro, AirPods, HomePod, CarPlay). It
checks every App Intents title, description, parameter, entity, enum case,
parameter summary and App Shortcut phrase in Swift sources that import
`AppIntents`. With `--metadata`, it checks every localized string in the
compiled `Metadata.appintents` instead; CI's iOS build runs it on the
simulator products, and the archive verifier applies it before upload. Say
"a locked device" or "voice commands" instead.

When Apple rejects an upload during processing, no build record appears.
`scripts/release-apple.rb` therefore reads the app's `buildUploads`
(`GET /v1/apps/{id}/buildUploads`). A `FAILED` state fails `distribute`,
`upload-status` and the hourly reconciler with Apple's error codes, and
writes an `invalid` receipt, so the same binary is not uploaded again.

`scripts/verify-release-train-archive.py`, already invoked before release
export/upload, checks the **actual bundled** privacy manifests, their audited
required reasons, collected-data field types, microphone/speech purpose
strings and excluded Store product analytics. It also reads the compiler's
`Metadata.appintents/extract.actionsdata`: every localized string is checked
for the rejected terms, and description keys for the final period; App Shortcuts are limited to ten,
phrases must contain the application-name placeholder, and the iOS app must
register at least one. Xcode merges a static library's actions into the app
but drops its `autoShortcuts`, so `TranscriptionShortcuts` lives in the app
target (`SpeakiOSApp/`) and includes the library's intents through
`AppIntentsPackage`. CI's iOS build runs `scripts/ios/check-app-shortcuts.py`,
which requires every declared shortcut in the built app. Unrecognized localized
description alternatives fail for explicit review rather than being ignored.
This does not validate every localization or Apple's server-side rules.
A dependency's manifest cannot stand
in for the app's own resource. Nested Watch apps and complications use the
Watch App Group, not the phone's group. All owned bundles must agree on
version, build, train and source. Fixtures cover missing/misplaced/malformed
manifests, missing uptime reasons, diagnostic installation linkage, compiler
descriptions, shortcut limits/phrases, purpose strings, wrong Watch groups and
companion identity, and the Store sandbox. These are admission checks, not
proof that SDK internals or runtime data flows satisfy every review policy.

The wider source audit also checked
[Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
2.4.5 (Mac Store sandbox/self-updates), 2.5.4/2.5.14 (background audio and
recording indicators), 4.4.1 (keyboard input without Full Access), and
5.1.1/5.1.2 (privacy, consent and third-party AI sharing), plus
[App Shortcuts guidance](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts).
Existing Store compilation guards exclude Sparkle and external executable
model runtimes. The keyboard's blocked Full Access state disables dictation,
not its editing keys or next-keyboard control. Real-device microphone,
locked/background recording and consent/withdrawal behavior still need
release-candidate evidence. Sentry diagnostics have their own opt-in, separate
from the Direct-only product-analytics opt-in; unit tests cover the gate and
withdrawal, but the signed candidate's network behaviour, on-device deletion and
Sentry's retention setting are owner checks in `Docs/manual-checks.yml`. Static
metadata tests cannot close those gates or the App Store Connect findings.

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
