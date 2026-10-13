# Desktop Voice Output sources and WAV export

Windows and Linux remain developer previews, not macOS-parity releases.
Voice Output uses the existing shared Deepgram speech contracts, canonical
`DeepgramSpeechCatalog` voice projection and native playback. It does not add
providers merely because they appear in the macOS voice catalogue.

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
Both use the saved Deepgram key and voice and send text to Deepgram. Text export
requests speech again.

**Generate** captures the text, voice and both generation preferences, produces
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
The shared desktop voice model persists optional `ttsAutoPlay` and
`ttsSaveToDirectory` keys and resolves absent values through
`SpeechGenerationDefaults`; changing voice preserves these choices. This PR
does not add a second generic configuration authority.
Empty/whitespace-only text, nulls and more than 100,000 Unicode scalars are refused
before provider work. Only the engine's default speed is supported.

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
macOS's wider providers, pitch/SSML controls and configurable speed are not
claimed here. Native generation supports the actual engine's default speed,
auto-play, managed audio archival and replay/export of a completed result.

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
the extended Voice Output page; dialog captures are synthetic.

Windows Swift type-checks and MinGW/GTK syntax checks are supplementary only:
they do not prove native linking/execution. Final-head Windows and Linux CI
self-tests and screenshots, Apple/API/lint checks, and physical playback,
clipboard/portal/save-dialog accessibility remain separate evidence. No real
user Clipboard or History content is used in validation. No installed app
upgrade, new account/plugin, main merge or Stable publication is part of this
change, and this slice does not close the desktop parity epic.
