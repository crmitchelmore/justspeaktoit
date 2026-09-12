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
the export questions are answered. To stop the prompt, file the annual
self-classification report with the Bureau of Industry and Security, then
export the approval code before generating:

```sh
TUIST_ITS_ENCRYPTION_COMPLIANCE_CODE=<code from BIS> tuist generate
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

## Still owed outside the repo

These cannot be resolved by a commit.

1. Answer the export compliance questions on the first build uploaded after this
   change, or supply the BIS code as above.
2. Keep the App Store Connect privacy nutrition label in step with
   `SpeakiOSApp/PrivacyInfo.xcprivacy`, including the other user content entry.
3. Give App Review notes covering the custom keyboard: what Full Access is for,
   and that the keyboard stays usable without it.
4. Provide a working API key or point review at the on-device Apple Speech path,
   so a reviewer without a key can still exercise the app.
5. Confirm the listing's privacy policy URL resolves to the same document the
   in-app link opens.

## Regression cover

`Tests/SpeakCoreTests/IOSAppStoreComplianceTests.swift` asserts each of the
above that lives in the repo. It runs in the macOS test job.
