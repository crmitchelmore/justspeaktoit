# One CloudKit container for Mac and iPhone (#1119)

The owner chose `iCloud.com.justspeaktoit` (the Mac container; Alpha:
`iCloud.com.justspeaktoit.alpha`) as the one container for History and
encrypted API-key sync. Windows and Linux already use it through CloudKit Web
Services, and the retired Mac App Store build wrote it. The iPhone moves into
it; nothing on the Mac side changes. The direct-download Mac build still ships
without CloudKit entitlements, so it joins only once it has a provisioning
profile that carries them.

## How the move works

- `TUIST_IOS_SHARED_CLOUD_CONTAINER=1 tuist generate` adds the Mac container to
  the iOS app's `com.apple.developer.icloud-container-identifiers` (keeping the
  old `iCloud.com.justspeaktoit.ios` entry) and sets the Info.plist flag
  `SpeakSharedCloudContainer`. `SyncConfiguration.family` reads that flag, so a
  build only opens a container it is entitled to. The flag is off by default.
- `release-ios.yml` sets the flag from the repository variable
  `IOS_SHARED_CLOUD_CONTAINER` (`1` turns it on). The archive verifier then
  expects both containers in the signed entitlements.
- On the first launch in the new container, `SyncContainerTransition` clears the
  old container's change tokens, zone/subscription markers and the iPhone's
  acknowledged-History set, so every iPhone re-pushes its local History. It also
  clears the key-sync account marker: encrypted API-key sync turns off and the
  user enables it again (same passphrase) to upload keys to the shared
  container. Nothing is deleted from either container, and rolling the flag back
  resets the same way.

## Owner steps (Apple Developer portal; agents cannot do these)

1. **App IDs.** Certificates, Identifiers & Profiles › Identifiers ›
   `com.justspeaktoit.ios` › iCloud › Configure: tick `iCloud.com.justspeaktoit`
   as well as `iCloud.com.justspeaktoit.ios`, then Save. Do the same for
   `com.justspeaktoit.ios.alpha` with `iCloud.com.justspeaktoit.alpha`.
2. **Profiles.** Nothing to do by hand: release builds fetch the App Store
   profiles through the App Store Connect API and replace any that lack the
   containers ([details](ios-testflight-release.md#provisioning-profiles)).
   Run the **Apple App IDs and profiles** workflow to regenerate and check them
   ahead of a build.
3. **Schema.** In CloudKit Console, check that the Production schema of
   `iCloud.com.justspeaktoit` (and `.alpha`) has every record type that the
   `iCloud.com.justspeaktoit.ios` Production schema has. If one is missing,
   deploy the Development schema to Production.
4. **Turn it on.** Set the repository variable `IOS_SHARED_CLOUD_CONTAINER` to
   `1`. The next Alpha iOS build signs with both containers.
5. **Check.** Run `iphone-shared-icloud-container` on
   <https://justspeaktoit.com/qa>. The direct-download Mac app has no CloudKit
   entitlement, so the check reads the shared container in CloudKit Console
   (or on a Windows/Linux build with sync configured) rather than on the Mac.

After the check passes, remove `SyncContainerFamily.iOS`, the flag and the
legacy entitlement entry, and close #1119.
