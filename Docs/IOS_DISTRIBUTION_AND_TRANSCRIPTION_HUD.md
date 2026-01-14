# iOS provisioning + signing (Mac)

_Last updated: 2026-01-14_

## Bundle/sign so it installs on devices

### A. Identifiers
- App target bundle id: currently `com.justspeaktoit.ios`
- Widget extension bundle id: currently `com.justspeaktoit.ios.JustSpeakToItWidgetExtension`

If you’re shipping under your own developer account, change these to a reverse-DNS you own (e.g. `com.yourcompany.speak` and `com.yourcompany.speak.widget`).

### B. Certificates / provisioning
In Xcode (Targets → **Signing & Capabilities**):
1. Select your **Team** (your Apple Developer team)
2. Enable **Automatically manage signing**
3. Build/Run on a connected device (Xcode will create/manage development profiles)

### C. Entitlements / capabilities
The iOS target uses `SpeakiOS.entitlements`.

- **App Groups**: currently `group.com.justspeaktoit.ios`
  - If you change bundle IDs, you may also want to rename the App Group.
  - Ensure the **app + widget extension** both have the same App Group entitlement if they share data.

### D. Install / distribute
- Local install: Xcode **Run** on device.
- TestFlight: Xcode **Product → Archive → Distribute App → TestFlight** (requires App Store Connect record).
- Ad Hoc: archive + export with an Ad Hoc profile (requires collecting device UDIDs).

#### Automation (what can be automated)
You generally **can’t fully automate initial certificate enrollment** (Apple login / 2FA / accepting agreements is a one-time manual step), but you *can* automate:
- creating/updating provisioning profiles on the build machine (via Xcode automatic signing)
- building an `.xcarchive` and exporting an `.ipa`

This repo includes `scripts/ios-build-ipa.sh` which runs `xcodebuild archive` + `xcodebuild -exportArchive` using **automatic signing**:

```bash
# Development IPA
EXPORT_METHOD=development ./scripts/ios-build-ipa.sh

# Ad Hoc IPA (requires you to have an Ad Hoc profile + registered device UDIDs)
EXPORT_METHOD=ad-hoc ./scripts/ios-build-ipa.sh
```

Notes:
- It uses `-allowProvisioningUpdates`, so you must be logged into Xcode on that machine.
- For CI, the usual approach is **fastlane match** (store certs/profiles in an encrypted repo) or manually installing a distribution cert + provisioning profile as CI secrets.

### E. Permissions strings
The iOS app target is using **generated Info.plist** keys:
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

That’s enough to avoid the “missing usage description” crash when requesting mic/speech permissions.

### F. Known install blocker fixed
The widget extension deployment target was incorrectly set to **iOS 26.2**; it’s now **iOS 17.0** so it can install on real devices.

