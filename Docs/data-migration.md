# macOS data export and import

Open **Settings → Data & Migration**. This feature is manual and macOS-only.

## Export

One unencrypted ZIP contains `manifest.json`, a readable JSON file for each
selected category, and any selected recordings. All categories start selected
except **API keys & credentials**. Select all/none shortcuts are available.

| Category | Contents |
| --- | --- |
| Settings & shortcuts | Persisted app preferences, shortcut bindings, remembered model selections and onboarding choices |
| History text & speech usage | Raw/processed transcripts and session metadata; saved TTS usage records |
| Recordings | Audio associated with history plus regular saved audio in the recording folder, including saved TTS and files whose history was deleted |
| API keys & credentials | The app credential vault, connection pairing code and paired-device information |
| Dictation profiles | Per-application dictation profiles and their overrides |
| Vocabulary, pronunciation & corrections | Keywords, pronunciation dictionaries, personal lexicon and learned correction candidates |
| Connections | Send-to-Mac and automation configuration; credentials are independently selected |
| Model references | Imported model catalogues, names, download sources and managed destination hints for installed models; never weights, runtime code or installation markers |

History text and recordings have independent **All**, **Date range** and
**Selected entries** controls. Dates include both displayed calendar days.
Selecting history entries filters transcripts; TTS usage can be included with
All or a date range. Audio-only imports appear as recording rows until their
matching text is imported.

Selecting credentials displays an explicit warning that anyone holding the ZIP
can read and use its keys. No password is required. Credential values are hidden
in import conflict previews. Diagnostic network exchanges are excluded from
history because request headers/bodies can contain credentials.

Device identities, sync cursors, caches, telemetry queues, purchase receipts,
installation markers, staged incomplete captures, and executable runtimes are
not migrated. Derived speech insights are rebuilt from history. macOS permission
grants must be obtained on the destination Mac.

## Import preview and conflicts

Choose an export ZIP, then independently select **Skip**, **Merge**, or **Replace**
for each included category. Review the preview before confirming the import.

- Merge skips identical history/audio; differing versions are retained with
  deterministic identities so repeating an import does not create more copies.
- Configuration conflicts show existing/imported values and require an explicit
  choice. Profile and vocabulary records match by their stable identifiers.
- Replace changes the selected category. For a filtered history/audio export,
  only the exported IDs/date range are replaced; outside entries stay intact.
  Superseded audio in managed recording folders is removed after recovery is
  saved and the import succeeds; original files outside those folders are preserved.
- History and recordings reconnect by session identity, regardless of import
  order. Explicit import can restore locally deleted history.
- Unavailable recording folders and microphones require a replacement choice.
  Unavailable model destinations offer this Mac's managed model folder.
- Restored model references offer downloads through the existing model managers.
  External streaming sources open their existing model settings workflow.
- Invalid individual items are skipped and reported. If an affected category is
  damaged, its existing entries are preserved instead of treating an incomplete
  read as authority to clear the category; valid imported items still apply.
- Unknown archive versions are rejected. ZIP entries are bounded, duplicate paths
  rejected, and audio checksums verified before applying data. Imported archive
  paths cannot choose arbitrary filesystem destinations or executable file types.

Changes made while a preview is open cause a refresh/review before import.
Recording starts are blocked during the transaction; history mutations queue
until migration finishes. Preferences and in-memory managers reload afterwards.
Write failures attempt rollback and retain recovery for manual restoration.

## Recovery

Before an import, the app saves the affected categories under Application Support
in `SpeakApp/MigrationRecovery`. Only the latest backup is retained, until deleted
from the feature's recovery controls. Reviewing/restoring recovery does not replace
that backup. Restore also uses the category preview.

The recovery ZIP does not contain plaintext credentials. That category is held
in a separate AES-GCM encrypted file; its random key is stored in a separate,
non-synchronising, device-only Keychain item, outside the exportable key registry.
Losing that Keychain item prevents credential recovery on another Mac. Ordinary
exports remain portable and unencrypted as requested.

## Verification

`make test` runs the archive, merge, validation, disk round-trip, separate audio/text,
deleted-entry restoration, concurrent-history and real Keychain recovery tests.
`make lint` enforces the repository's existing baseline. The new settings entry is
also exposed as a configurable navigation shortcut, initially unassigned.

The first full local run stopped in an existing performance test without an
assertion failure. That test passed in isolation, and the next full run passed
2,520 tests (11 skipped). The isolated app bundle launched and exposed the sidebar
entry; computer-control transport failed before the interactive panel walkthrough
could finish. That walkthrough remains a review check, not a claimed pass.
