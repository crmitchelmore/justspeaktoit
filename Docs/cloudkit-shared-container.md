# One CloudKit container for Mac and iPhone (#1119)

The owner chose `iCloud.com.justspeaktoit` (Alpha: `iCloud.com.justspeaktoit.alpha`)
as the one container for History and encrypted API-key sync. Windows and Linux
already use it through CloudKit Web Services, and the retired Mac App Store
build wrote it. The iPhone has moved into it; nothing on the Mac side changed.
The direct-download Mac build still ships without CloudKit entitlements, so it
joins only once it has a provisioning profile that carries them.

## Configuration

- `ReleaseTrains.json` holds one `cloudContainer` per train, read through
  `ReleaseTrain.cloudContainer` and `SyncConfiguration.containerIdentifier` on
  every platform. `scripts/generate-release-train-config.py` keeps the watch
  projection in step. `iosCloudContainer` remains only as the legacy iPhone
  container (`ReleaseTrain.legacyIOSCloudContainer`,
  `SyncConfiguration.legacyContainerIdentifier`); the old
  `macCloudContainer`/`iosCloudContainer` properties forward and are deprecated.
- `SpeakiOS.entitlements` lists both containers, so the migration can still read
  the legacy one. Alpha builds get the `.alpha` pair through `trainPlistPath`.
- Release builds fetch App Store profiles through the App Store Connect API and
  require both containers (`release-ios.yml`, `apple-profiles.yml`); the archive
  verifier expects exactly the two. `release-ios.yml` still sets
  `TUIST_IOS_SHARED_CLOUD_CONTAINER=1` so frozen sources that predate this
  change, which joined only behind that flag, build the same way.

## The one-time iPhone migration

1. **Reset.** At launch, `SyncContainerTransition` sees the container change
   and clears every container-scoped marker: History and comparison change
   tokens, History and key-sync zone/subscription markers, the key-sync change
   token and the iPhone's acknowledged-History set. The key-sync account
   fingerprint is moved to `speak.keysync.legacyAccountIdentifier` instead of
   being deleted.
2. **History.** After `HistorySyncEngine.initialize`,
   `migrateLegacyContainerHistoryIfNeeded()` reads every History record from the
   legacy container and pushes each one through `upload(entry:)`, the normal
   push path, so a newer copy already in the shared container wins. The first
   `sync()` then pulls the shared container into local History. The copy is
   marked done (`speak.sync.legacyContainerHistoryCopied`) only after every
   entry is acknowledged, or when the legacy zone does not exist; a failure
   retries on the next launch. iCloud sync switched off copies nothing.
3. **API keys.** CloudKit user record names differ per container, so
   `CloudKitKeySync` compares the set-aside fingerprint with the legacy
   container's account. The same account keeps key sync on and queues the
   carry-over (`speak.keysync.legacyContainerCopyPending`); another account is
   handled as an iCloud account change. On the next sync the shared container
   gets passphrase metadata with the legacy salt (the same passphrase keeps
   working), legacy keys are applied locally, the shared container's newer
   copies win, and every local key is re-encrypted and uploaded through the
   normal upload path. If the shared container already uses a different
   passphrase, key sync turns off and asks for it.

Nothing is deleted from either container. Alpha iPhones that ran a build with
the earlier `IOS_SHARED_CLOUD_CONTAINER` flag already reset and turned key sync
off; they still copy legacy History once and re-enable key sync by hand.

## Owner steps

1. **App IDs.** Certificates, Identifiers & Profiles › Identifiers ›
   `com.justspeaktoit.ios` › iCloud › Configure must include
   `iCloud.com.justspeaktoit` and `iCloud.com.justspeaktoit.ios`;
   `com.justspeaktoit.ios.alpha` must include `iCloud.com.justspeaktoit.alpha`
   and `iCloud.com.justspeaktoit.ios.alpha`. The App Store Connect API cannot
   assign containers, so this is portal-only.
2. **Profiles.** Nothing to do by hand: run the **Apple App IDs and profiles**
   workflow to regenerate and check them ahead of a build
   ([details](ios-testflight-release.md#provisioning-profiles)). The stored
   `IOS_APPSTORE_PROFILE`/`ALPHA_IOS_APPSTORE_PROFILE` secrets are only a
   fallback for frozen sources older than the API fetch.
3. **Schema.** In CloudKit Console, check that the Production schema of
   `iCloud.com.justspeaktoit` (and `.alpha`) has every record type that the
   `iCloud.com.justspeaktoit.ios` Production schema has. If one is missing,
   deploy the Development schema to Production.
4. **Check.** Run `iphone-shared-icloud-container` and
   `iphone-legacy-container-migration` on <https://justspeaktoit.com/qa>. The
   direct-download Mac app has no CloudKit entitlement, so the checks read the
   shared container in CloudKit Console (or on a Windows/Linux build with sync
   configured) rather than on the Mac.

After the checks pass on Stable, a later release can drop the legacy
entitlement entry, `SyncContainerFamily.iOS`, the migration and the deprecated
properties, delete the unused `IOS_SHARED_CLOUD_CONTAINER` repository variable,
and close #1119.
