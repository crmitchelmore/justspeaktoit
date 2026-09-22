# Windows interoperability with the existing CloudKit sync

This is the first sync slice for Windows: a portable sync domain and an
injectable CloudKit Web Services transport that read and write the **existing**
Apple CloudKit records. It is validated at source and fixture level only. No
request in this change has reached iCloud, no Windows UI or sign-in exists yet,
and nothing here is a device-to-device receipt. The Apple apps keep their
native CloudKit framework path; nothing here runs in their capture or
transcription path.

## What is authoritative

The shipped Apple data defines the format. `Sources/SpeakSync/SyncSchema.swift`
now holds that definition once, and the native `CKRecord` mappers and the web
transport both use it.

| Item | Existing format |
|---|---|
| Containers | Stable: macOS `iCloud.com.justspeaktoit`, iOS `iCloud.com.justspeaktoit.ios` (Alpha has separate ones), from `ReleaseTrains.json`. History syncs within a platform family, never across it. |
| Zone | `TranscriptionHistoryZone` in the private database, owned by the signed-in user. |
| History | Record type `TranscriptionHistory`, record name = entry UUID, exactly nine fields: `entryID` String, `createdAt` Date, `rawTranscription` String?, `postProcessedText` String?, `model` String, `duration` Double, `wordCount` Int64, `originPlatform` String, `updatedAt` Date. Deletions are real CloudKit tombstones. No Asset fields: audio never leaves the device. |
| Compare Models | Type `ModelComparisonRound`, name `comparison-<UUID>`, flat `roundID`, `createdAt`, `updatedAt`, `originPlatform`, `schemaVersion`, and a JSON `payload`. A deletion is a dated revision with the same fields (its `originPlatform` is `macos`); a round from a newer schema is never consumed. Only the Mac App Store build writes rounds. |
| API keys | Type `EncryptedSecret`, name `secret-<unpadded base64url identifier>`, `ciphertext`/`nonce`/`tag` Bytes, `updatedAt` Date, `isDeleted` Int64 1/0; one `EncryptedSecretMetadata` record `api-key-sync-metadata` with the salt and verifier. |
| Conflicts | History: an existing record at least as new as the local entry wins. Comparison: newer wins; at a tie a deletion wins. Saves are conditional on the fetched record (`CONFLICT`/`EXISTS` stay pending and retry). |
| Cursors | Each client keeps its own per-feed cursor and advances it only after the local store commits. |

## Primary protocol evidence

All from Apple's [CloudKit Web Services Reference](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/index.html)
unless stated:

- Requests go to `https://api.apple-cloudkit.com/database/1/<container>/<development|production>/<database>/…`
  ([Composing Web Service Requests](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html)).
- Private data needs `ckAPIToken` plus a user `ckWebAuthToken`. Without one the
  service answers `421 AUTHENTICATION_REQUIRED` with a `redirectURL`; after an
  Apple ID sign-in the token is passed to the API token's sign-in callback as
  `?ckWebAuthToken=…`. `+`, `/` and `=` must be percent-encoded. "Each token is
  intended for a single round trip": every response carries a new token and
  the old one stops working. Tokens last 30 minutes, or two weeks with "Keep me
  signed in". Server-to-server keys reach only the public database, so they
  cannot be used for this data.
- The reference does not name where the new token arrives. Apple's own CloudKit
  JS (`cdn.apple-cloudkit.com/ck/2/cloudkit.js`) reads the
  `X-Apple-CloudKit-Web-Auth-Token` response header, falling back to
  `X-Apple-CloudKit-Session`; the client does the same.
- [`changes/zone`](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/FetchingRecordZoneChanges(changeszone).html)
  (custom zones only; `syncToken`, `moreComing`, `resultsLimit`) replaces the
  deprecated `records/changes`. `records/lookup` reports a missing record per
  record. [`records/modify`](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html)
  has `create`, `update` (changes only the given fields, needs
  `recordChangeTag`), `replace` (nulls every omitted field), their `force`
  variants and `forceDelete`; `atomic` defaults to `true` and applies to custom
  zones. `zones/modify` creates zones. `users/caller` returns the
  container-scoped `userRecordName` a native client reads from `userRecordID()`.
- Field values are `{value, type}`; Date/Time is milliseconds since 1970 and
  Bytes are base64. Limits: 200 operations per request, 200 records per
  response, 1 MB per record. Documented error codes include `CONFLICT`,
  `EXISTS`, `NOT_FOUND`, `THROTTLED`, `TRY_AGAIN_LATER`, `ZONE_NOT_FOUND`,
  `QUOTA_EXCEEDED`; a per-record `retryAfter` marks a retryable operation.
- Current API-token setup: CloudKit Console → container → Settings → Tokens &
  Keys → New API Token, with an optional "URL Redirect" sign-in callback and
  allowed origins ([Obtaining an API Token for an iCloud Container](https://developer.apple.com/documentation/cloudkit/obtaining-an-api-token-for-an-icloud-container)).

## Source layout

`SpeakSync` now builds in the portable graph except the files named in
`appleSyncSources` in `Package.swift`: the native CloudKit transports, the
`@MainActor` `ObservableObject` engines, `CKRecord` mapping, push routing and
the CryptoKit conformer.

- **Shared reconciliation.** `HistorySyncCoordinator` and
  `ComparisonSyncCoordinator` are the loops the Apple engines always ran: fetch
  every page, coalesce to one final event per record, commit, then advance the
  cursor; upload, acknowledge only what CloudKit confirmed, and stop on a
  stalled acknowledgement. They run on the caller's actor (`#isolation`), so
  `HistorySyncEngine` and `ComparisonSyncEngine` keep executing on the main
  actor, publish the same status assignments in the same order, and a Windows
  host can drive them from its own actor without a UI run loop.
- **Shared schema and codecs.** `SyncRecordCodecs.swift` encodes and decodes
  every record type. The native adapter reads through `record[key] as? T`; the
  web record applies the same number bridging.
- **Web transport.** `CloudKitWebServicesClient` (an actor) attaches tokens and
  retries `THROTTLED`, `TRY_AGAIN_LATER`, 502–504 and transient network faults
  with bounded backoff, honouring `retryAfter` up to a cap. It never retries
  authentication failures. `CloudKitWebHistorySyncTransport` and
  `CloudKitWebComparisonSyncTransport` implement the shared transport
  protocols. `URLSessionCloudKitWebServicesTransport` reuses SpeakCore's
  bounded, redirect-free exchange; a host may inject another
  `CloudKitWebServicesHTTPTransport`.
- **Ordering and sessions.** One FIFO gate admits one request or session change
  at a time. The first read of the stored token, each rotation, sign-in,
  sign-out and rejected session happen under it, so a late read cannot restore
  a cleared session or overwrite a rotated token. Each operation carries the
  `CloudKitWebSession` it began in; every attempt re-checks it under the gate,
  and a History or Compare Models upload uses one session for its lookup and
  its writes. After a sign-out, a new sign-in or a rejected token, old
  operations fail with `sessionChanged` instead of reaching the new account.
  Backoff waits happen outside the gate; token rotation within a session is
  unaffected.
- **Identity and consent.** `CloudKitWebSyncAccount.validate` compares the
  `users/caller` identity with the account the cursors belong to and clears
  them before rebinding another user. The host must then forget its local
  acknowledgements. `CloudKitWebSyncConsent` is empty by default, and a web
  transport or zone creation cannot be built without the feature's consent.
- **API-key envelope.** `EncryptedSecretEnvelope` holds the existing parameters
  (PBKDF2-HMAC-SHA256 over `salt + "justspeaktoit.api-key-sync.v1"`, 210,000
  iterations, AES-256-GCM, 12-byte nonce, 16-byte tag, fixed verifier) over the
  `SyncEnvelopeCryptography` seam. Apple keeps `EncryptedSecretCrypto`
  unchanged.

## Writes match a native save

- A new record is a `create` with only the fields that have values; `EXISTS`
  leaves the entry pending, as a native save of a new record would.
- An existing record is an `update` against its fetched `recordChangeTag`, with
  `atomic: false` so each record succeeds or fails alone. Every assigned field
  is sent. A cleared optional field is sent as an explicit null only where the
  server holds a value. Fields this client does not write are left alone, so a
  newer app's fields are never overwritten (`replace` would null them).
- Deletion is `forceDelete` by name, like `deleteRecord(withID:)`; `NOT_FOUND`
  is success.

## Capabilities and documented blockers

`CloudKitWebServicesCapability` reports these as typed values:

| Capability | Status |
|---|---|
| Private database access | Needs external configuration: API token and interactive sign-in |
| Change feed, lookup, conditional writes, deletion, zone creation, caller identity | Supported by documented endpoints |
| Change notifications | Unsupported. Pushes go through APNs; `tokens/create` returns a long-poll `webcourierURL` without a documented message format or delivery guarantee for these subscriptions. Windows polls instead (the Mac already retries every 30 seconds). |
| Native cursor interchange | Unsupported. An archived `CKServerChangeToken` is not a web `syncToken`; each client replays from the start once. |
| Expired cursor recovery | Unsupported. No documented error code identifies an expired `syncToken`, so it surfaces as a failure. |
| Asset transfer | Not needed today. No record type has an Asset field. |
| API-key cryptography | Needs a platform provider. Windows needs a CNG (BCrypt) adapter, not written yet, which must pass the known-answer vectors in `EncryptedSecretEnvelopeTests.swift`. |

## Compatibility constraints

- Date/Time is stored to the millisecond; the client rounds to the nearest
  millisecond. A Windows store should keep millisecond dates to avoid a
  redundant re-upload of its own entries.
- The Windows client must pick one container family. Joining the Mac family
  interoperates with Mac App Store History and Compare Models rounds. The
  iPhone family needs its own container, API token and sign-in. Consolidation
  would be a migration and is out of scope.
- Direct (Developer ID) Mac builds have no CloudKit sync, so only Mac App Store
  data exists in the Mac container.
- Web tokens are per client and rotate. A crash between a response and saving
  its token, or a cancelled request whose response never arrived, can force a
  new sign-in. That is safe, but it is visible to the user.
- Retrying a write after an ambiguous failure can meet `EXISTS` or `CONFLICT`;
  the entry stays pending and the next pass acknowledges it from the lookup.

## External acceptance gates

1. A developer API token per container (CloudKit Console, production
   environment) with a sign-in callback a native Windows app can receive.
   Whether a loopback or custom URL is accepted is unverified. No token or
   callback has been provisioned here.
2. Windows sign-in UI, the consent toggle, polling cadence, and host
   persistence: web auth token in Credential Manager, cursors, the bound
   account and acknowledgements under `%LOCALAPPDATA%`.
3. A live check against a synthetic Apple ID of every item this slice had to
   infer: the rotated-token header, the `users/caller` shape (documented as a
   `users` array; a bare identity is also read), explicit-null clearing in
   `update`, `EXISTS` for a create race, `recordType` on deleted records (the
   record-name rule covers its absence), and expired-`syncToken` behaviour.
4. Mac ↔ Windows round trips for History create/edit/delete and Compare Models
   rounds, including offline edits and account switches.
5. A Windows CNG provider for the envelope, then a portable key-sync engine.
   `CloudKitKeySync`'s lifecycle is still Apple-only.
6. The full Apple suite and the native Windows/Linux CI for this revision.

## Verification in this change

- Portable tests (`SPEAK_PORTABLE_CORE=1`, macOS, release) cover the codecs
  over the wire format, feed paging and classification, adaptive result limits,
  per-record upload outcomes, partial failures, conflict rules, tombstones,
  cursor durability, follow-up passes, retry and backoff, cancellation,
  identity changes, consent, and the web-auth ordering schedules. Two review
  schedules were reproduced before the fix: a held initial token read restored
  a signed-out session or overwrote a rotated token, and a retry held in
  backoff replayed the old payload under a new sign-in.
- The Apple-only parity tests (`NativeRecordParityTests.swift`) and the
  existing Apple SpeakSync tests exercise the refactored engines. They have not
  run in this change; the full Apple build is a separate, coordinated gate.
