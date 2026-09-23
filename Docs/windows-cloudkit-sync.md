# Windows CloudKit sync

Windows syncs History with the Mac by reading and writing the **existing**
CloudKit records through CloudKit Web Services. The Apple apps keep their
native CloudKit framework path. Setup and the user-facing behaviour are in
[Windows development: iCloud sync](windows-development.md#icloud-sync).

Status: source, portable tests and Windows loopback tests only. No request in
this repository's tests reaches iCloud. A live Mac to Windows receipt needs the
CloudKit Console setup listed in that section.

## Findings

**No Mac credential can be the web API token.** The Mac and iPhone apps use
the operating system's CloudKit session through their entitlements. They hold
no web token, and the repository and CI workflows contain none (no workflow
references a CloudKit secret). CloudKit Web Services needs a developer **API
token** that the container owner creates in CloudKit Console, plus a per-user
`ckWebAuthToken` from an Apple ID web sign-in. Windows takes the API token as a
build setting (`CLOUDKIT_WEB_API_TOKEN`) and reports "iCloud sync is not
available in this build" without it.

**The Mac's synced API keys can be read, with the passphrase.**
`CloudKitKeySync` stores each key as an `EncryptedSecret` record with plain
`Bytes` fields: an AES-256-GCM ciphertext, nonce and tag. It does not use
`CKRecord.encryptedValues`. The key is PBKDF2-HMAC-SHA256 (210,000 iterations)
over the user's key-sync passphrase and a random salt, which is stored with a
verifier in the `EncryptedSecretMetadata` record `api-key-sync-metadata`. iCloud
access alone cannot read the keys, and neither can Windows: the user enters the
same passphrase they set on the Mac, just as a new Apple device joining key sync
does. Nothing on the Apple side was changed or weakened. Windows imports keys
only after the user opts in, stores them in Credential Manager, keeps only the
derived key, and never writes keys to iCloud.

**Schema deployment is not recorded here.** Web Services only see record types
deployed to Production. The repository has no receipt of a Production
deployment. [Alpha and Stable release trains](alpha-stable-release-trains.md)
lists "deploy the matching CloudKit schemas" as outstanding rollout evidence. A
working Mac App Store sync in Production would imply the Stable types exist,
but that has not been verified from here. The owner must confirm it in CloudKit
Console.

**Settings do not sync to Windows.** The Mac's six synced settings use
`NSUbiquitousKeyValueStore`, which has no web API. Only History (and, opt-in,
API keys) come across.

## Which container

| Container | Written by | Windows |
|---|---|---|
| `iCloud.com.justspeaktoit` | Mac App Store build (Stable) | Joined: History, API keys |
| `iCloud.com.justspeaktoit.alpha` | Mac App Store Alpha | Not used: Windows builds have no Alpha identity yet and resolve the Stable train |
| `iCloud.com.justspeaktoit.ios` (`.alpha`) | iPhone | Not joined; a separate container |

The direct (Developer ID) Mac build ships without CloudKit entitlements, so its
History is not in iCloud. Windows chooses the container from
`ReleaseTrains.json` through `SyncContainerFamily.macOS`.

## Record format

The shipped Apple data defines the format. `Sources/SpeakSync/SyncSchema.swift`
holds it once; the native `CKRecord` mappers and the web transport both use it.

| Item | Existing format |
|---|---|
| Zone | `TranscriptionHistoryZone` in the private database |
| History | `TranscriptionHistory`, record name = entry UUID, nine fields: `entryID` String, `createdAt` Date, `rawTranscription` String?, `postProcessedText` String?, `model` String, `duration` Double, `wordCount` Int64, `originPlatform` String, `updatedAt` Date. Deletions are CloudKit tombstones. No assets: audio never leaves the device. Windows writes `originPlatform` `windows`. |
| Compare Models | `ModelComparisonRound`, name `comparison-<UUID>`, flat fields and a JSON `payload`. A transport exists; Windows does not sync rounds yet. |
| API keys | `EncryptedSecret`, name `secret-<unpadded base64url identifier>`, `ciphertext`/`nonce`/`tag` Bytes, `updatedAt` Date, `isDeleted` Int64; one `EncryptedSecretMetadata` record with the salt and verifier. The identifier list is `SyncSchema.EncryptedSecret.syncableIdentifiers`. |
| Conflicts | History: a CloudKit copy at least as new as the local entry wins. Saves are conditional on the fetched record (`CONFLICT` and `EXISTS` stay pending and retry). |
| Cursors | Each client keeps its own cursor and advances it only after its store commits. A native `CKServerChangeToken` is not a web `syncToken`, so Windows replays the zone once on first sync. |

## Protocol

From Apple's
[CloudKit Web Services Reference](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/index.html):

- Requests go to
  `https://api.apple-cloudkit.com/database/1/<container>/<environment>/<database>/…`
  with `ckAPIToken` and, for private data, `ckWebAuthToken` in the query.
- Without a session the service answers `421 AUTHENTICATION_REQUIRED` with a
  `redirectURL`. After an Apple ID sign-in the browser is redirected to the API
  token's sign-in callback with `?ckWebAuthToken=…`. Each token is good for one
  round trip; every response carries its replacement. Apple's CloudKit JS reads
  it from `X-Apple-CloudKit-Web-Auth-Token`, falling back to
  `X-Apple-CloudKit-Session`, and so does this client.
- The client uses `changes/zone`, `records/lookup`, `records/modify` (`create`,
  `update` with `recordChangeTag`, `forceDelete`, `atomic: false`),
  `zones/modify` and `users/caller`. None of them needs a queryable index. The
  key reader looks records up by name instead of querying.

## Source layout

- `Sources/SpeakSync` (portable except `appleSyncSources` in `Package.swift`):
  `SyncSchema` and codecs, `HistorySyncCoordinator` and
  `ComparisonSyncCoordinator` (which the Apple engines now run on the main
  actor), `CloudKitWebServicesClient` with a FIFO session gate and bounded
  retries, the History and Compare Models web transports,
  `CloudKitWebSyncAccount` (caller identity and zone creation),
  `EncryptedSecretEnvelope` and the read-only `CloudKitWebKeySync`.
- `Sources/SpeakDesktopSync` (portable): `DesktopHistorySyncStore` maps desktop
  records onto the shared entry and keeps synced copies audio-less;
  `DesktopCloudSyncStateStore` holds cursors, the bound account and
  acknowledgements; `DesktopCloudSyncService` runs sign-in, passes and key
  import; `DesktopCloudSyncConfiguration` resolves the build-time token.
- `Sources/SpeakWindowsPlatform/WindowsCloudKitNative.swift` with
  `Sources/CWindowsSupport/WindowsHTTP.cpp`, `WindowsLoopback.cpp` and
  `WindowsCrypto.cpp`: the WinHTTP transport, the 127.0.0.1 listener and the
  CNG envelope primitives.
- `Sources/SpeakWindows/WindowsCloudSync.swift` and
  `Sources/CWindowsSupport/WindowsCloudSyncSettings.cpp`: the dialog, sign-in
  and History updates in the window.

## Tests

- `Tests/SpeakTestSupport/FakeCloudKitWebServer.swift` is a stateful fake of
  the endpoints above: per-user private databases, change tags, tombstones, an
  ordered feed with paging, rotating single-use web auth tokens and the
  documented error codes.
- `Tests/SpeakSyncTests` and `Tests/SpeakDesktopSyncTests` run against it on
  every platform: Mac-format records in and out, edits and tombstones through
  the cursor, both conflict directions, paging, expiry, account switches,
  consent, key unlock, wrong or reset passphrases and misfiled key records.
- `Tests/SpeakWindowsPlatformTests/WindowsCloudKitNativeTests.swift` serves the
  fake over a real loopback socket through WinHTTP, checks the sign-in callback
  and cancellation, and holds CNG to the independent PBKDF2 and AES-GCM vectors
  that the Apple implementation also meets.

## Limits

| Capability | Status |
|---|---|
| Change notifications | Not available to web clients for these subscriptions; Windows polls every five minutes and after each saved transcript. |
| Expired cursor | No documented error code identifies an expired `syncToken`; it surfaces as a sync error. |
| Loopback callback | Unverified until the API token is created. If CloudKit Console refuses `http://127.0.0.1:47823/cloudkit-sign-in`, a custom URI scheme through the MSIX manifest is needed instead. |
| Token size | Credential Manager holds up to 2,560 bytes per credential. A longer web auth token would fail to save and ask for sign-in again. |
| Compare Models, iPhone History, settings, Handoff | Not wired on Windows. |
