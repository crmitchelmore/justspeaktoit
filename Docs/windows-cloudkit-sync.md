# Windows CloudKit sync

Windows syncs History with the Mac by reading and writing the **existing**
CloudKit records through CloudKit Web Services. The Apple apps keep their
native CloudKit framework path. Setup and the user-facing behaviour are in
[Windows development: iCloud sync](windows-development.md#icloud-sync).
Linux runs the same shared flow with its own adapters and the same API token
and callback; see [Linux development: iCloud sync](linux-development.md#icloud-sync).
Everything below applies to both unless it names one.

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
| History | `TranscriptionHistory`, record name = entry UUID, nine fields: `entryID` String, `createdAt` Date, `rawTranscription` String?, `postProcessedText` String?, `model` String, `duration` Double, `wordCount` Int64, `originPlatform` String, `updatedAt` Date. Deletions are CloudKit tombstones. No assets: audio never leaves the device. Windows writes `originPlatform` `windows`, Linux `linux`. |
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
  `CloudKitWebSyncAccount` (caller identity, account binding and zone
  creation), `EncryptedSecretEnvelope` and the read-only `CloudKitWebKeySync`.
  A web History pass is bound to the session its account was validated in:
  its requests run in that session, and `CloudKitWebSessionFence` (a
  `HistorySyncPassFence`) admits its cursor, change and acknowledgement writes
  only while that session is current, under the same gate as sign-in and
  sign-out. Rebinding the account holds that gate too. The store's commit
  (`persistRemoteChanges`) is not admitted; it may only commit or report what
  the admitted steps applied.
- `Sources/SpeakDesktopSync` (portable): `DesktopHistorySyncStore` maps desktop
  records onto the shared entry and keeps synced copies audio-less, and its
  commit only reports records already saved; `DesktopCloudSyncStateStore`
  holds cursors, the bound account, acknowledgements and imported-key
  bookkeeping; `DesktopCloudSyncService` runs sign-in, one pass at a time and
  key import, with every History write, key change, key-sync key and success
  time admitted in the validated session (`DesktopCloudSyncSteps`). It writes
  nothing more once the session ends, a feature is turned off or the pass is
  cancelled; earlier writes stay. Turning key import on or off takes a
  revision, so an earlier turn-on still in progress stores nothing once a later
  change begins, and a key saved by hand is written once its mark is saved;
  `DesktopCloudSyncWork` owns a host's sync tasks so shutdown stops new work
  and drains what runs within a bound; `DesktopCloudSyncConfiguration`
  resolves the build-time token; `DesktopLoopbackListener` and
  `DesktopCloudSyncSignIn.awaitCallback` wait for the sign-in callback on a
  host's listener.
- `Sources/SpeakDesktopHost/DesktopHostCloudSync.swift` (portable): the flow
  both hosts run, generic over the host platform: the settings' actions
  (Apply, Sign in, Sign out, Sync now), the loopback sign-in, the periodic
  pass, `DesktopCloudSyncWork` ownership for shutdown, status lines and the
  controller's synced-History presentation. A host supplies only
  `DesktopHostCloudSyncNative`: how the settings show state, the listener,
  the browser launch, its origin platform and where its choices live.
- `Sources/SpeakWindowsPlatform/WindowsCloudKitNative.swift` with
  `Sources/CWindowsSupport/WindowsHTTP.cpp`, `WindowsLoopback.cpp` and
  `WindowsCrypto.cpp`: the WinHTTP transport, the 127.0.0.1 listener and the
  CNG envelope primitives.
- `Sources/SpeakWindows/WindowsCloudSync.swift` and
  `Sources/CWindowsSupport/WindowsCloudSyncSettings.cpp`: the Windows
  specialisation and its dialog.
- `Sources/SpeakLinuxPlatform/LinuxCloudKitNative.swift` and
  `LinuxEnvelopeCryptography.swift` with `Sources/CLinuxSupport/LinuxLoopback.c`
  and `LinuxCrypto.c`: the FoundationNetworking URLSession transport, the
  Secret Service vault, the POSIX 127.0.0.1 listener and the OpenSSL envelope
  primitives. `Sources/SpeakLinux/LinuxCloudSync.swift` and
  `Sources/CLinuxSupport/LinuxCloudSync.c`: the Linux specialisation, its
  window group and the sign-in page launch.

## Tests

- `Tests/SpeakTestSupport/FakeCloudKitWebServer.swift` is a stateful fake of
  the endpoints above: per-user private databases, change tags, tombstones, an
  ordered feed with paging, rotating single-use web auth tokens and the
  documented error codes.
- `Tests/SpeakSyncTests` and `Tests/SpeakDesktopSyncTests` run against it on
  every platform: Mac-format records in and out, edits and tombstones through
  the cursor, both conflict directions, paging, expiry, account switches,
  consent, key unlock, wrong or reset passphrases and misfiled key records.
  Held fixtures interrupt a pass between pages, batches and steps with a
  sign-in, sign-out, History or key import turned off or cancellation
  (including a transport that returns regardless), interrupt turning key import
  on, and interleave account validations. A sync state file that cannot be
  written shows that a typed key is not saved without its mark. Host shutdown
  ownership is tested through `DesktopCloudSyncWork`.
- `Tests/SpeakDesktopHostTests/DesktopHostCloudSyncTests.swift` runs the shared
  host flow on every platform with a fake platform and a scripted listener:
  sign-in through the callback, History both ways with the host's origin, a
  remote deletion of the selected transcript, sign-out, a replaced and a
  timed-out sign-in, a build without a token and shutdown.
- `Tests/SpeakLinuxPlatformTests/LinuxCloudKitNativeTests.swift` serves the fake
  over a real loopback socket and runs the desktop sync service through
  URLSession and OpenSSL (History both ways, key import, token rotation),
  checks the callback, idle connections and cancellation;
  `LinuxEnvelopeCryptographyTests` holds OpenSSL to the same vectors as CNG.
- `Tests/SpeakWindowsPlatformTests/WindowsCloudKitNativeTests.swift` serves the
  fake over a real loopback socket through WinHTTP, checks the sign-in callback
  and cancellation, and holds CNG to the independent PBKDF2 and AES-GCM vectors
  that the Apple implementation also meets.
- The Windows executable's `--self-test` runs `WindowsPostProcessingSelfTest`:
  the post-processing dialog's Apply through the real controller and settings
  queue with a synthetic sync key hook, covering a typed and a blank key, a
  setting saved while the key is saved, queued Applies, refused saves and
  closing midway.

## Changing Apple ID

Signing out keeps this PC's sync state, so signing back in as the same Apple
ID resumes where it stopped. Each pass, and turning key import on, first
compares the signed-in user with the bound one. A different user resets the
state kept for the previous one: the History cursor, acknowledgements, the
marks for recordings deleted on its Mac, which API keys were imported, and the
last sync time. Nothing is deleted from History or Credential Manager, and the
previous account's iCloud data is untouched. Linux behaves the same, with the
Secret Service keyring in place of Credential Manager and `linux` as the
origin of its own recordings.

What then reaches the new account is a product decision still open for
review. Current behaviour, by kind of record:

- **Recordings made on this PC** (audio here, origin `windows`) upload to the
  new account, as on a first sign-in. A recording the previous account had
  deleted on its Mac, and this PC kept, loses that mark and uploads too.
- **Transcripts downloaded from the previous account** (audio-less copies of
  its Mac History) also upload, keeping the Mac as their origin, so that
  account's Mac transcripts appear in the new account. Switching back resets
  again and carries the other account's copies the same way. Records are
  matched by ID, so nothing is duplicated; the newer copy wins.
- **API keys**: saved values stay in Credential Manager. The new account's
  keys import as new, a deletion there removes no key saved before the switch,
  and keys saved by hand are no longer told apart from imported ones. The
  stored key-sync key belongs to the previous account: against the new one it
  fails the passphrase check, so import turns off and asks for that account's
  passphrase, or sync reports that the account has no synced keys.

## Limits

| Capability | Status |
|---|---|
| Change notifications | Not available to web clients for these subscriptions; Windows polls every five minutes and after each saved transcript. |
| Expired cursor | No documented error code identifies an expired `syncToken`; it surfaces as a sync error. |
| Loopback callback | Unverified until the API token is created. If CloudKit Console refuses `http://127.0.0.1:47823/cloudkit-sign-in`, a custom URI scheme is needed instead: through the MSIX manifest on Windows, an `x-scheme-handler` in the desktop file on Linux. |
| Token size | Credential Manager holds up to 2,560 bytes per credential, and Linux reads up to 8 KiB from the keyring. A longer web auth token would fail to save or read and ask for sign-in again. |
| Keys typed by hand | The "saved by hand" mark is saved before the key. If the sync state cannot be saved, the key is not saved and the error is shown. If Credential Manager then refuses the key, or the app stops between the two, the key saved before stays and counts as typed: a deletion on the Mac no longer removes it, though a newer key from the Mac still replaces it. |
| Compare Models, iPhone History, settings, Handoff | Not wired on Windows or Linux. |
