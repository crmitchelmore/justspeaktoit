# Desktop Voice Output sources and WAV export

Windows and Linux remain developer previews, not macOS-parity releases.
Voice Output uses shared Deepgram, Azure neural, Azure MAI and xAI REST speech contracts,
canonical catalogue projections and native playback. `DesktopSpeechVoice` exposes only
routes the host executes, not every provider in the macOS catalogue. The seven
built-in Azure neural catalogue entries now have one `AzureNeuralVoiceCatalog` definition
shared with macOS; native hosts do not copy voice entries.
The current MAI-Voice-2.1 and Flash speakers come directly from the existing
`AzureMAIVoiceCatalog`, including their locale/model identifiers. MAI uses the
same regional Azure request builder, saved `key:region` credential and native
WAV decoding/playback, not a second provider client or credential store.

xAI's documented Eve and Ara presets come from `XAITTSCatalog`. Read, Generate
and text export use the shared `/v1/tts` request contract with automatic language,
mono PCM16 WAV at 24 kHz and the existing `xai.apiKey` credential. There is no
invented API model field or realtime WebSocket fallback.
The native controls receive the canonical xAI speed limits (0.7-1.5) atomically
with the selected voice. Speed is executed; pitch and SSML are unsupported and
disabled, while stored choices remain visible. Out-of-route speed or unsupported
controls refuse synthesis before credential access; selecting xAI does not clamp
or discard preferences. Normal controls remains an explicit reset.
Long text uses the existing 15,000-character xAI chunker, validates every response,
and joins bounded PCM before publication. Failed, cancelled, empty or incompatible
audio never publishes a partial result. Local usage records observe the actual
requests and validated duration; canonical USD15/million-character pricing is an
estimate, not a billed receipt. Retained replay/export does not synthesize again.
**xAI account voices** opens a native chooser with documented presets labelled
separately from account-listed voices. **Refresh** explicitly requests the shared
`GET /v1/tts/voices` contract using the saved xAI key; it sends no source text and
does not synthesize audio. Listing has a 20-second budget, a 64 KiB response limit
and a maximum of 512 voices. Malformed, duplicate and oversized lists fail
explicitly. A failed refresh may retain a previous same-key listing, but never
labels that fallback as a successful new listing.
**Choose voice** saves the stable prefixed account identifier in the sole voice
model, preserving all other controls/preferences. Read, Generate, text export,
controls and estimates use the same immutable account evidence. Account synthesis
checks the actual request credential against that evidence before transport or
usage. Listing evidence is memory-only and discarded on key changes or restart:
a stored account choice remains unavailable until explicitly refreshed, not
silently replaced with a preset. Closing/replacing the chooser cancels discovery
and rejects late results; shutdown counts and bounds cancelled work. Replay and
result export remain independent of inventory or credentials. No listing key is
presented, persisted in settings/usage or retained with generated audio.
Opaque stored identifier case is preserved; the shared xAI request builder retains
its documented case-insensitive API normalization. Explicit language selection,
progressive xAI delivery and wider output formats remain gaps.

## Journey

Choose **Voice Output > Text and export**. The native editor defaults to a
snapshot of the selected History transcript and its displayed original/processed
version. If none is selected, choose one in History and reopen the editor, or
choose **Type or paste text**. **Clipboard snapshot > Load clipboard** explicitly
captures text; the app never polls or substitutes clipboard content for another
source. Loading failures clear the previous clipboard snapshot.

**Import text file > Choose file** uses the native local-file chooser and reads
UTF-8 into an editable snapshot. A UTF-8 BOM is accepted. The shared limit is
100,000 Unicode scalars (at most 400,003 UTF-8 bytes including the BOM); invalid
UTF-8, nulls, empty input, directories and oversized files fail explicitly.
The chooser and file read do not send anything to a provider. A later change to
the original file cannot change the captured text. Failed import keeps existing
editor text and reports the error; it does not claim the new file was loaded.
Stop, editing, changing source and closing discard an in-flight result. Reads
run off the UI/actor, remain counted until their worker ends, and obey bounded
shutdown. A stalled filesystem cannot admit an unbounded set of further reads.

**Read aloud** explicitly speaks the snapshot through the existing native
player, regardless of the Generate auto-play preference. **Export text WAV**
asks for a local destination before synthesis and does not play the audio.
Both use the selected executable voice and its saved provider credential and
send text to that provider. Azure uses the existing Azure Speech credential
(`key:region`), saved through the normal provider
settings, not a second Voice credential store. Text export requests speech again.

**Generate** captures the text, voice, synthesis controls and both generation preferences, produces
one complete validated WAV and retains it independently of later editor or
preference changes. **Auto-play generated audio** defaults on; with it off,
generation completes without speaking and **Play result** is still available.
**Export result** copies the retained WAV to a user-chosen location. Replay and
result export never send a new synthesis request or require a fresh credential.
Starting another voice job supersedes active work; Stop preserves an already
completed result. Only one counted generated-audio operation is admitted, even
if a cancelled provider or filesystem is still closing.

**Save audio to recordings** defaults off. When enabled for Generate, the store
actor archives an independent flat `UUID.wav` in the actual managed History
audio directory. It does not create a transcript, change metadata or promote
the audio into History on restart. Publication is atomic and exclusive, with
temporary sibling staging removed before returning. Existing destinations
are never replaced. Save failure is explicit and does not discard a usable
generated result. Cache/playback staging stays separate; a saved copy is
user-owned output and is not removed when the cache changes or the app closes.
The imported macOS `recordingsDirectory` never controls native filesystem writes.
Publication uses reusable `DesktopFilePublication`: Windows commits with a
native exclusive sibling rename through the standard C runtime, not Foundation
links or a host SDK in the shared domain; other hosts link
exclusively and remove staging only after publication succeeds. Post-commit
cleanup failures explicitly keep and name the published copy.
The shared desktop voice model persists optional `ttsAutoPlay` and
`ttsSaveToDirectory` keys and resolves absent values through
`SpeechGenerationDefaults`; changing voice preserves these choices. This PR
does not add a second generic configuration authority.
Empty/whitespace-only text, nulls and more than 100,000 Unicode scalars are refused
before provider work.

**Voice controls** opens native synthesis settings without adding a window page.
The sole voice model persists optional `ttsSpeed`, `ttsPitch` and `ttsUseSSML`;
absent values mean speed 1, pitch 0 and plain text. Shared `VoiceSynthesisOptions`
validates finite speed 0.5-2 and whole-number pitch -12 to 12 semitones.
Azure neural voices execute speed, pitch and SSML through the existing shared
Azure request builder. Deepgram supports only normal controls: unsupported
controls are disabled but their stored values remain visible and unchanged.
Read/Generate/text export explicitly refuse incompatible choices before reading
a credential, rather than silently ignoring them or changing provider.
**Normal controls** is an explicit reset; selecting another voice preserves
all controls. Unknown provider choices appear as unavailable, not Deepgram.
MAI supports normal speed/pitch only: the native fields are disabled while
retaining stored non-default values, and execution refuses those values before
reading credentials. Choose **Normal controls** explicitly to reset them.
SSML is submitted unsplit without an automatic neural prosody wrapper; the
service still decides which MAI-specific tags it supports. The curated models
are executable routes, not a guarantee that every Azure resource grants access.
MAI's canonical model suffix is persisted unchanged; older Azure route-only
imports remain readable without rewriting their stored identifiers. Unlisted
voices and unknown MAI models remain unavailable rather than falling back.
Save waits for persistence acknowledgement before closing, reports write
failures without changing previous settings, and ignores acknowledgements for
closed/replaced requests. Close remains available while saving; closing the
editor does not undo an already-admitted settings write.

Plain text uses the canonical segmenter; SSML is never split across XML tags.
SSML input and complete request bodies are limited to 64 KiB. A full `<speak>`
document defines its own prosody, so non-normal sliders are refused rather than
silently bypassed; use normal sliders or an SSML fragment. Azure Read prepares
one bounded validated WAV before native playback; Deepgram Read retains its
existing segmented playback. No independent playback engine or IPC is added.

Long text uses the canonical segmenter. Export validates each provider response,
joins decoded mono PCM16 at 24 kHz, and writes exactly one RIFF/WAVE header, with
a 64 MiB PCM limit. A failed segment produces no partial destination. The native
save chooser confirms replacement; only after synthesis succeeds does an atomic
write replace the chosen file. Destinations inside the app's data folder are
refused, protecting History and settings. Filesystem write failures are reported.

**Stop** cancels synthesis, speech or export. Starting another playback or voice
job, recording, importing, switching History selection, or closing supersedes
the old job. A cancelled/stale job cannot publish audio or overwrite the current
job's status. Closing counts admitted jobs in the existing bounded shutdown
budget. Native clipboard/save callbacks become inert when their editor closes.
The final atomic write is the commit boundary; Stop cannot undo a file already
committed. Export never changes transcripts, recordings or provider settings.

History speech/export retains its actual `voiceOutputRecordID`; typed,
clipboard and text-file jobs have no History owner. The playback engine may
use an ephemeral UUID to serialize non-record speech, but that UUID is not record authority.
Deletion integration must use the actual voice owner rather than the currently
selected History row. Settings keep their existing catalogue identifiers and
migrations. These source choices are editor-local, not new stored preferences.

## Local synthesis estimates and usage

**Usage and input estimate** captures the current editor text and selected
executable voice without sending a synthesis request. Reopen it after changing
text or voice for a fresh estimate. Rates come from `VoiceSynthesisPricing`:
the existing shared Deepgram Aura rate, Azure neural USD 16/million characters,
and the canonical MAI model rates (USD 22/million for MAI-Voice-2.1;
USD 15/million for Flash). Flux remains explicitly unpriced; unknown models
never borrow an unrelated route's rate.

Actual usage is observed at the owned Core HTTP boundary for Read, Generate
and text export, after credential/request validation. Entries distinguish
transport attempts, failures/cancellation and completed **validated PCM**.
Input counts are the Unicode scalars supplied to each request after segmentation
and, for Deepgram, pronunciation/trim processing. Audio seconds come from
validated PCM, not playback time. Partial successful segments remain accounted
for even if a later segment, playback, archival or export fails.
Replay and retained-result export do not create synthesis entries.

All displayed costs are **input-based estimates, not measured/billed charges**.
No provider billing receipts or token counts are available on these routes.
The completed-audio subtotal excludes unpriced entries and names that exclusion.
SSML markup, provider character rules, discounts and regional pricing can
change actual charges. A transport attempt does not prove server receipt, and
a failed/cancelled request can still incur a provider charge.

The bounded local ledger is `VoiceUsage/requests.json`, in a private directory,
retaining the latest 1,000 request observations rather than claiming lifetime
or billing-account totals. It contains no text, audio, key or provider body.
Each entry snapshots its route/rate, operation/source and genuine History UUID,
or nil for every other source; cache/speech/request UUIDs are not History
authority. It does not mutate History or imported History costs.
Malformed/oversized ledgers are preserved and explicitly reported, not replaced
with an empty success. Failed writes report memory-only usage.

**Keep local synthesis usage** is an executable native preference, stored as
optional `ttsTrackUsage` in the sole `DesktopVoiceOutputSettings`; canonical
metadata/defaults live in `VoiceUsagePolicy`. The default is on, matching Mac's
local TTS ledger. The opt-out is a deliberate desktop privacy extension, not
a previously missing Mac option: the traced Mac manager has no equivalent
Voice-specific tracking switch. Off preserves earlier usage, creates no new ledger entries,
and invalidates completions from opted-out work even after re-enabling.
It is not telemetry consent or a new analytics service. Preference persistence
is acknowledged from actual host state; closed/replaced dialog tokens cannot
revive a window. The additive key still needs the separately owned advanced
configuration bridge upon composition, not a second settings authority here.
Once composed with the parent-owned canonical preference-key enum/catalogue,
the key must derive from that enum with Boolean/default/category metadata and
lossless transfer/bridge tests, rather than maintaining a second key literal.

Mac `TextToSpeechManager` currently appends successful `TTSResult`s and persists
`ttsUsageHistory`; its character-rate `cost` is also an estimate. Native
accounting deliberately additionally exposes failed/cancelled transport attempts
without describing those attempts as billed usage.

## Actual macOS features and remaining gaps

`Sources/SpeakApp/VoiceOutputView.swift` currently offers manual text, clipboard,
History and text-file import; it copies `TextToSpeechManager.lastResult.audioURL`
through `NSSavePanel` for export. It does not offer an external-selection source
in that workspace. Windows/Linux now implement all four text sources and
user-chosen lossless WAV export, including editable UTF-8 text-file snapshots.
Native generation additionally supports auto-play, managed audio archival and
replay/export of a completed result. Azure neural speed/pitch/SSML are executable
here; macOS's Deepgram path currently ignores those same controls, and native
hosts deliberately refuse them for Deepgram instead. Current canonical MAI
models now execute Read, Generate and text export through that same bounded
Azure engine, with retained replay/export independent of later settings.
The documented xAI Eve/Ara presets now execute the REST/WAV journey with
canonical speed and true request accounting, not account discovery or progressive delivery.
System and wider providers, selectable export format/quality and broader
Voice workspace parity remain gaps. Advanced configuration transfer is a
separately coordinated settings integration; this PR does not create another
configuration authority.

External selected text is unavailable, and is not advertised as a source row.
Windows insertion targeting can capture an external field for *writing*, but
this journey has no captured-target lifecycle that proves the intended external
selection for *reading*. Clicking the app and inspecting its focused control
would read the wrong target. X11 targeting likewise does not prove a text
selection; Wayland does not expose reliable arbitrary external selections.
Explicit copy followed by Clipboard snapshot is a distinct user action, never
an automatic fallback. No stored unsupported source preference is rewritten.

## Evidence and acceptance

Portable synthetic tests cover immutable ownership, empty/oversized sources,
multi-segment exact WAV shape, credential cancellation, provider failure, Stop,
newer generations, protected destinations and close. The native window
self-tests cover the History-default editor, editable typed text, empty
clipboard state, imported text, failed imports that preserve text, discarded
results after editing and the four-source projection without reading the real
clipboard or sending text to a provider. The normal screenshot tours include
the extended Voice Output page; dialog captures are synthetic. Synthesis tests
use synthetic Azure responses to verify exact prosody, SSML boundaries,
credential admission, transport/status/cancellation failures and refusal of
partial audio. Host tests preserve immutable settings snapshots, failed-write
state, unsupported stored choices and actual History ownership through Azure
Read cancellation. Native controls fixtures check capability gating, numeric
round trips, explicit reset and stale/failure/success save acknowledgements.

Windows Swift type-checks and MinGW/GTK syntax checks are supplementary only:
they do not prove native linking/execution. Final-head Windows and Linux CI
self-tests and screenshots, Apple/API/lint checks, and physical playback,
clipboard/portal/save-dialog accessibility remain separate evidence. No real
user Clipboard or History content is used in validation. No installed app
upgrade, new account/plugin, main merge or Stable publication is part of this
change, and this slice does not close the desktop parity epic.
