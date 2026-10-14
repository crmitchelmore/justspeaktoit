# Desktop Voice Output sources and WAV export

Windows and Linux remain developer previews, not macOS-parity releases.
Voice Output uses shared Deepgram and Azure neural speech contracts, canonical
catalogue projections and native playback. `DesktopSpeechVoice` exposes only
routes the host executes, not every provider in the macOS catalogue. The seven
built-in Azure neural catalogue entries now have one `AzureNeuralVoiceCatalog` definition
shared with macOS; native hosts do not copy voice entries.

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

## Actual macOS features and remaining gaps

`Sources/SpeakApp/VoiceOutputView.swift` currently offers manual text, clipboard,
History and text-file import; it copies `TextToSpeechManager.lastResult.audioURL`
through `NSSavePanel` for export. It does not offer an external-selection source
in that workspace. Windows/Linux now implement all four text sources and
user-chosen lossless WAV export, including editable UTF-8 text-file snapshots.
Native generation additionally supports auto-play, managed audio archival and
replay/export of a completed result. Azure neural speed/pitch/SSML are executable
here; macOS's Deepgram path currently ignores those same controls, and native
hosts deliberately refuse them for Deepgram instead. MAI/system and wider
providers, selectable export format/quality, provider cost/usage UI and broader
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
