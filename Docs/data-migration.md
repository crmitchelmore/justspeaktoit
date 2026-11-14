# macOS data export and import

Open **Settings → Data & Migration** for full manual export/import on macOS.
Windows and Linux save, inspect and restore the same ZIP for every category; see
[Windows and Linux](#windows-and-linux).
Native ZIP inspection also validates profile structure and declared coverage
through the shared profile catalogue. Missing profile data is not an empty
collection; prompts and identifiers are never displayed. Profile checks are not
current-store merge counts, import approval or native application of profiles.
In General, **App profiles** on Windows or **Include app profiles** on Linux adds per-app overrides and prompts
to the unencrypted ZIP; it starts off, preserving existing History-only choices.
The source is read through the shared bounded owned-file reader and exact-byte,
file and directory-chain revalidation. Unsupported identity metadata, changed
sources and malformed collections fail the backup rather than becoming empty
replacement authority. Profiles preserved as unreadable on startup must be
recovered before selecting them.

## Export

One unencrypted ZIP contains `manifest.json`, a readable JSON file for each
selected category, and any selected recordings. All categories start selected
except **API keys & credentials**. Select all/none shortcuts are available.

New exports use format version 2; version-1 exports remain readable. Version 2
can declare covered record kinds and keys, so a partial source cannot clear
uncollected kinds or unsupported preferences during replacement. Older
version-1-only apps explicitly reject these exports; update the receiving app.
Native recording-store backups select recording `history` records only, not
the separate per-attempt Voice usage ledger. Standalone saved speech WAVs are
audio-only records without fabricated usage or History ownership.

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
  only the exported IDs/date range and covered kinds/keys are replaced;
  outside entries stay intact.
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
  Repeated recording paths are rejected; installation reserves destination space,
  verifies existing digest-named files, and removes new copies after failed writes.

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

Profile prompts are stored in each `profiles` / `profile` record's `polishPrompt`,
not a global Mac preference. Shared collection projection retains original raw
values, array order, identifier spelling and unknown matcher/routing members;
typed decoding validates existing acceptance rules without replacing payloads.
Native `profiles.json` uses the same format. Backups must read original bytes,
not re-encode the runtime profile list, whose tolerant decoder drops unknown
matcher kinds and newer routing values. This codec does not itself establish
owned-file read authority, multi-store consistency or native import availability.

## Android

**Settings → Export and import** writes and reads the same version-2 ZIP
(`android/app/src/main/java/com/justspeaktoit/android/transfer/`). An export
always holds the shared settings Android has (keep cancelled audio, cleanup on,
language, cleanup model, cloud model). It also holds History, kept WAV
recordings, dictation profiles and corrections (as lexicon rules) when there are
any, and API keys only when **Include API keys** is on. Android's own mode,
History retention, cleanup prompt and active profile go in
`android-settings.json`, which other readers ignore. Connections and model
references are never written.

Importing copies the file into app storage, validates it as the shared readers
do (CRC, SHA-256 digest, safe paths, regular files only, size limits) and shows
a preview of counts for each category before anything changes. Unknown keys,
kinds Android lacks (pronunciations, connections), unsupported values and
non-WAV recordings are skipped with a notice. Apply merges rather than replaces:
recordings and keys are written first, then History in one write, then settings,
and a failure undoes the earlier steps. API keys are imported only when
**Import API keys** is on in the preview. An archive whose History is off
deletes this phone's History once applied, and the preview warns first.

## Verification

`make test` runs the archive, merge, validation, disk round-trip, separate audio/text,
deleted-entry restoration, concurrent-history and real Keychain recovery tests.
`make lint` enforces the repository's existing baseline. The new settings entry is
also exposed as a configurable navigation shortcut, initially unassigned.

The first full local run stopped in an existing performance test without an
assertion failure. That test passed in isolation, and the next full run passed
2,532 tests (11 skipped). The isolated app bundle launched and exposed the sidebar
entry; computer-control transport failed before the interactive panel walkthrough
could finish. That walkthrough remains a review check, not a claimed pass.

Claude ultrareview was independently verified. Regression coverage now includes
selective sync notifications, post-processing reload ordering, capture/import
exclusivity across suspension, and published-settings reload coverage. Conflict
placeholder handling, stale preview state, and combined rollback errors were fixed.

No-op imports preserve local history diagnostics and do not cause sync uploads.
Audio-only changes retain those local diagnostics while exports remain redacted.

Late review hardening keeps filter controls derived from the retained export scope,
stages archives in system-provided replacement storage on the destination volume, preserves
unowned audio in custom folders, retains unreadable profile data, normalises duplicate
history IDs, and re-registers active global shortcuts after import.

Rejected global shortcuts are shown in the import report and Keyboard conflicts,
with instructions to choose another binding. Archive replacement is tested on a
separate mounted volume as well as the default temporary filesystem.

## Windows and Linux

Windows (General › Audio, output and backup) and Linux (General › Data backup)
save the same version-2 ZIP. Every backup holds History text, settings,
shortcuts, connections, vocabulary (pronunciations, lexicon and corrections)
and references to downloaded local models. Saved audio and app profiles are
optional; API keys are added only when the user says yes (Windows asks with a
prompt that defaults to No, Linux has an **Include API keys** switch that
starts off).

**Restore** reads the whole archive first and shows a preview: per-category
counts, conflicts, skipped items and why. Nothing is written until the user
chooses Merge or Replace. Merge keeps this device's value when both sides
differ; Replace takes the backup's. History is only ever merged, and items
already on this device keep their own audio. The restore is all-or-nothing:
vocabulary, settings, API keys, app profiles, History and audio are rolled back
if any step fails, and an invalid archive changes nothing. API keys are read or
written only when the user opts in again on restore; without it the preview
says the backup's keys were left out.

Shared logic lives in `SpeakDesktop` (`DesktopMigrationRestore`,
`DesktopMigrationBackup`) and `SpeakDesktopHost`
(`DesktopHostMigrationConfiguration`); the Win32 and GTK files only add the
prompts and switches.

| Category | Windows and Linux |
| --- | --- |
| Settings & shortcuts, Connections | Portable preferences this device supports. Keys with no desktop equivalent, the active model, appearance, run at login and automation permission are skipped and counted in the preview. |
| History, Recordings | History merges; audio is attached only to History items the restore adds. |
| API keys & credentials | Provider API keys, only with the opt-in on both export and restore. Mac pairing details do not apply and are skipped with a reason. |
| Dictation profiles | Merge or Replace, as before. |
| Vocabulary | Pronunciations, lexicon and corrections. |
| Local models | Not applicable: model files are never downloaded or copied. The preview names models this device can download from Local models and counts those it cannot run. |

