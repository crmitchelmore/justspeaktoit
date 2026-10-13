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

**Read aloud** speaks the snapshot through the existing native player. **Export
WAV** asks for a local destination before synthesis and does not play the audio.
Both use the saved Deepgram key and voice, and send text to Deepgram. Export
requests speech again; it is not an export of cached, previously played audio.
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

History speech/export retains its actual `voiceOutputRecordID`; typed and
clipboard jobs have no History owner. The playback engine may use an ephemeral
UUID to serialize non-record speech, but that UUID is not record authority.
Deletion integration must use the actual voice owner rather than the currently
selected History row. Settings keep their existing catalogue identifiers and
migrations. These source choices are editor-local, not new stored preferences.

## Actual macOS features and remaining gaps

`Sources/SpeakApp/VoiceOutputView.swift` currently offers manual text, clipboard,
History and text-file import; it copies `TextToSpeechManager.lastResult.audioURL`
through `NSSavePanel` for export. It does not offer an external-selection source
in that workspace. Windows/Linux now implement the first three sources and
user-chosen lossless WAV export. Text-file import remains a separate follow-up.
macOS's wider providers, pitch/SSML controls, configurable speed, auto-play,
save-to-recordings and cached-result export are not claimed here.

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
clipboard state and the three-source projection without reading the real
clipboard or sending text to a provider. The normal screenshot tours include
the extended Voice Output page; dialog captures are synthetic.

Windows Swift type-checks and MinGW/GTK syntax checks are supplementary only:
they do not prove native linking/execution. Final-head Windows and Linux CI
self-tests and screenshots, Apple/API/lint checks, and physical playback,
clipboard/portal/save-dialog accessibility remain separate evidence. No real
user Clipboard or History content is used in validation. No installed app
upgrade, new account/plugin, main merge or Stable publication is part of this
change, and this slice does not close the desktop parity epic.
