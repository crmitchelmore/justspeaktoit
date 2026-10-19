# Desktop Voice Output sources and audio export

Windows and Linux remain developer previews, not macOS-parity releases.

## Imported default voice (source-only successor)

An explicit Mac `defaultTTSVoice` projects into the existing sole native Voice
selection, not a second persisted preference. Supported scalar IDs use the
canonical shared voice migrations and default model policy. An absent key leaves
the existing selection alone, including the legacy no-selection default; startup
and import never discover an account, read a key or send a synthesis request.

The portable desktop-only `desktopTTSModelID` companion preserves the explicit
model that a voice scalar cannot describe. Existing quality, format, region and
other Voice controls retain their own canonical transfer semantics. Reimporting
the same voice scalar does not erase a native advanced model. A different explicit
model with no incoming quality does not inherit an old model-selecting quality
that would undo that model choice. Unknown voice/model strings remain verbatim in
the native model and portable export, including across restarts.

Imported selection provenance requires strict resolution: unknown or Apple-only
voices, unimplemented OpenRouter routes and dynamic account voices without the
required inventory show the existing actionable **Unavailable stored voice**
picker row and refuse Read, Generate, fresh Export and the selected-key form
before credential/provider access. They never become Deepgram's legacy fallback,
another provider's default or a different account voice. An explicit native
catalogue/account choice replaces that intent only after persistence succeeds.
Previously captured jobs and completed audio retain their own immutable source,
voice and bytes; selecting an unavailable future voice does not reinterpret them.

Raw root/nested startup preferences are claimed only by hosts with the Voice
configuration bridge; nested canonical values take precedence. Generic hosts
without that bridge preserve but do not apply them. Failed imports/writes keep
the previous selection, settings revision and credential epoch. Successful
selection changes rotate the existing fences, including an import/restore ABA
during held native format discovery.

This successor is source-authored only. Its portable/host regressions have not
been parsed, compiled or run; native UI, provider and runtime acceptance remain
open. It neither changes the independently frozen audio-format/publication
repairs nor claims full desktop parity.

## Favorite voices

Both native pickers retain **Voice** (all available voices) and add a separate
**Favorites** quick picker plus **Add to favorites / Remove from favorites**.
Windows previews either picker choice and saves the voice only with **Apply**;
favorite edits save immediately without changing the selected provider/voice.
Linux applies an explicitly chosen row in settings order. Favorite actions and
picker callbacks carry a copied stable ID, not the position in a filtered list.
Unavailable selections cannot be favorited or silently replaced.

The sole persisted Voice model owns `ttsFavoriteVoices`, using the Mac's ordered
string-array representation and provider-prefixed IDs. Deepgram uses its canonical
`providerVoiceID` here, not the unprefixed synthesis ID. Transfer retains unknown,
retired, case-sensitive and duplicate entries verbatim; the visible projection
deduplicates only available entries in saved order. Unsupported providers are not
enabled by importing favorites. Account voices need their existing in-memory
listing evidence; restarting does not fetch a list or a key automatically.
Partial/unrelated imports retain favorites, an explicit empty array clears them,
and legacy configuration mirrors move into the Voice model at startup. A live
Voice list wins over a conflicting mirror. Failed writes leave the saved model
unchanged and report an error. Favorite-only changes do not rotate credential
selection epochs or reset provider-key forms.

Targeted synthetic tests cover transfer, restart, stale IDs, identity routing and
write failures. The native self-tests cover Favorites order, selection and
add/remove/empty-state controls without provider or audio operations. Header
compilation and synthetic widget/component checks are not installed/packaged
application, native Swift-host, hardware or full-parity acceptance.

## Synthesis and sources

Voice Output uses shared Deepgram, Azure neural/MAI, xAI, Cartesia, Mistral, Soniox,
OpenAI, Groq, Gemini, Speechmatics and ElevenLabs completed-speech contracts,
canonical catalogue projections and native playback. `DesktopSpeechVoice` exposes only
routes the host executes, not every provider in the macOS catalogue. The seven
built-in Azure neural catalogue entries now have one `AzureNeuralVoiceCatalog` definition
shared with macOS; native hosts do not copy voice entries.
The current MAI-Voice-2.1 and Flash speakers come directly from the existing
`AzureMAIVoiceCatalog`, including their locale/model identifiers. MAI uses the
same regional Azure request builder, saved `key:region` credential and native
WAV decoding/playback, not a second provider client or credential store.

### Captured file formats (source-only successor)

`SpeakCore.VoiceAudioFormat` owns the growing MP3 / AAC (M4A) / WAV identifiers,
labels, extensions and defaults; Mac's `AudioFormat` is a narrow alias. Mac keeps
its MP3 default. Absent native desktop preferences remain legacy WAV without
writing a new value. The sole Voice settings model owns `ttsOutputFormat`;
restart and configuration transfer preserve unknown/imported values verbatim.
Unknown values are unavailable, not silently migrated or converted to WAV.
The advanced editor projects that same stored value instead of displaying an
unrelated WAV default. Direct saves and successful configuration Apply/import
advance one controller-owned Voice revision, so changed-then-restored settings
cannot admit a stale codec-discovery result.

The native **File format** picker checks installed encoder/container/decoder
capability at the current captured mono rate before saving. Generate and fresh
**Export text...** repeat that check before dictionary, credential or provider
access; imported preferences are not execution evidence. Generate captures the
format with the immutable source, voice, quality and generation options. Fresh
export captures the chosen extension; it does not mutate the saved preference.
**Read aloud** remains the established provider/native PCM path, independent of
the file preference, and does not introduce an encode/decode step into live audio.

WAV retains the existing canonical PCM16 bytes without conversion. Compressed
generation synthesizes once through the existing provider WAV contract, then
encodes and fully decodes the actual resulting container **in process**.
The retained result owns both exact encoded export/archive bytes and the
native-decoded mono WAV used for playback. Retained Play/Export does not reread
the dictionary, settings, key, provider or conversion codec. Its extension must match that
retained format; renaming it to another container is refused. Original source,
History identity, model/options and usage ownership are not rewritten.

Windows dynamically loads the optional Media Foundation modules already used
by the native decoder. Installed synchronous encoder media types and an
instantiable decoder are queried, and the bounded in-memory container writer
is configured at the exact source rate before admission. Linux reuses the
existing GStreamer app dependency: MP3 needs `lamemp3enc`, `mpegaudioparse` and a
compatible decoder; M4A needs an installed `fdkaacenc`, `voaacenc` or `avenc_aac`,
`aacparse`, `mp4mux`, `qtdemux` and a compatible AAC decoder. Shared appsrc,
appsink, typefind, decodebin and audioconvert elements must also be installed.
AAC is muxed into real fragmented MP4, not ADTS renamed `.m4a`.
Capability checks inspect/create the installed route and its caps; only later
native round-trip fixtures can qualify actual container/device behavior.
No plugins, packages, remote calls, subprocesses, IPC or disk polling are added.

**Open rate/platform gaps:** catalogue membership is not executable support.
The Microsoft AAC encoder documents only 44.1/48 kHz, so native 16/24 kHz sources
normally cannot use that M4A route. MP3 likewise requires an enumerated exact-rate
mono type. Missing Linux plugins or unsupported exact-rate caps refuse with a
reason before key/provider work. No resampler or quality override forces success;
these routes remain explicit parity gaps. The inspected Mac Azure path itself
maps M4A preference to MP3 output; this desktop successor instead requires a real
AAC/M4A container or refuses. It does not change incumbent Mac provider behavior.

Encoded and decoded bytes have separate 64 MiB-derived bounds. Each native pass
checks cancellation and a 120-second budget between synchronous codec calls;
an individual system call is not forcibly interruptible. Its worker remains
owned and awaited through native teardown and bounded Host shutdown reporting.
Format-save settings callbacks enqueue admission only: one cancellable,
active-operation-counted discovery task occupies its slot until teardown, so
the settings queue can drain before close. Stop/close and later settings fence
a suspended result; another discovery cannot pile up behind a stalled worker.
Generation and fresh compressed export also share one conversion admission
until their native worker returns. Stop does not release that slot early;
replacement compressed jobs refuse before another codec/key/provider call.
Export stages a complete sibling then performs one native atomic replacement;
failure/cancellation before that commit preserves an existing destination and
cleans staging. The protected app data root remains refused.

This incremental implementation and all new portable, Host, native-container
and native-control regression sources are **NOT_RUN / NOT_QUALIFIED**. No parser,
compiler, linter, test, provider, native UI/device or installed-app execution is
admitted. Source packaging/authentication is not runtime or full-parity evidence.

### Pronunciation replacements for captured text sources

Ordinary (non-SSML) History, typed/pasted, explicit clipboard and imported-file
**Read**, **Generate** and fresh **Export** use one Host preparation path and the
existing canonical `PronunciationRenderer` / `PronunciationEntry` text-replacement
rules. Entry order, regex capture templates, case handling and Unicode matching
are not reimplemented by the host. The History Read entrypoint no longer renders
before entering that path: even a non-idempotent replacement runs once.

Preparation runs inside the existing tracked operation, before any provider or
credential await. It captures the dictionary entries and load-error state
together on `VocabularyActor`; stop, close and newer playback tickets fence
suspended loading and late work. A later dictionary or voice edit cannot retag
the already prepared request. Dictionary load/reload errors are explicit, never
an empty/default-dictionary fallback or an overwrite of corrupt storage.
Empty/blank-audio input, empty rendered speech, oversized expansion and embedded
nulls refuse synthesis before credential access.

Only the per-operation provider input is replaced. The original source text,
source kind, History owner/transcripts and retained generated-result provenance
remain unchanged; usage observes the actual rendered request with the original
source/model ownership. Retained **Play** and **Export** reuse their captured
audio bytes without rereading the dictionary, a key or a provider.

With **Use SSML** enabled, plain-text sources on the executable **Azure neural**
route now use the same portable pronunciation-to-SSML renderer as the Mac
manager. Non-regex entries emit IPA phoneme tags; regex entries retain ordered
replacement-template semantics rather than inferring phonemes. Generated nodes
are protected from later entries. Text, word bodies, IPA and alphabet attributes
are XML-escaped once; `$` and backslashes inside phoneme literals are not regex
templates. These deliberately correct the old Mac builder's unsafe ampersand/
literal escaping and later-entry tag/attribute rewriting. Regex-produced markup
is spoken as escaped text, not executed as SSML.

Explicit user-authored SSML documents, fragments, inline tags and entity-only
XML text remain byte-for-byte unchanged at both the native Desktop preparation
and supported Mac manager entrypoints, using the same intent detector.
Desktop bypasses dictionary access; the direct shared renderer remains a
plain-text-to-SSML API. Unsupported Mac providers keep ordinary replacements.
Named references (including unknown names), decimal
`&#38;` and hexadecimal `&#x26;` references signal authored intent; raw ampersands
and ordinary comparisons remain plain text and are escaped once.
Intent detection does not parse/validate XML or expand entities: unknown
references and malformed authored markup remain subject to the existing provider
validation. Complete `<speak>`
documents retain the existing normal-speed/pitch requirement. The final Azure
body, including its existing wrapper, must fit **65,536 UTF-8 bytes** before any
key access; markup is never segmented. The request and preflight share one pure
body builder, independent of credentials, endpoint or requested audio quality.

SSML support alone does not imply IPA support: **Azure MAI does not infer
phonemes**, and no other desktop route gains this capability. Mac Apple-system
IPA is not Windows SAPI/eSpeak support; that native parity gap remains. No
phonetic conversion engine, new provider, control or audio format is added.
All new shared/Mac/Host regression sources are **NOT_RUN**: this incremental
successor is source-only, uncompiled and unqualified. Metadata reconstruction is
not provider, native-device, installed-application or full-parity acceptance.

### Recovered OpenAI, Groq, Gemini and Speechmatics routes

The four-provider source composition reuses the existing shared catalogues,
request builders and previously delivered desktop engines, rather than copying
macOS protocol constants or replacing the current Mistral/Soniox/account paths.
This composition is **source-only and uncompiled/unexecuted**. Earlier component
receipts do not qualify this combined source, native picker, audio hardware,
provider access or installed application.

| Route | Executable source projection | Credential | Desktop audio and controls |
|---|---|---|---|
| OpenAI | TTS-1, TTS-1 HD and mini; 29 compatible model/voice tuples | Separate `openai.tts.apiKey`, never the transcription key | 24 kHz mono PCM16 WAV; full canonical speed 0.25-4; no pitch/SSML |
| Groq | 12 canonical English/Saudi Arabic Orpheus personas paired with their actual model | Shared `groq.apiKey` | 24 kHz mono PCM16 WAV; normal controls only |
| Gemini | Every `GeminiTTSCatalog.models` / voice tuple; currently 30 voices with Gemini 3.1 Flash TTS | Shared `google.apiKey` | 24 kHz mono PCM16 WAV, or validated raw L16 wrapped without resampling; normal controls only |
| Speechmatics | Four canonical English voices | Shared `speechmatics.apiKey` | Actual 16 kHz mono PCM16 WAV; normal controls only |

The native Voice list projects the same canonical executable tuples. OpenAI and Gemini
rows include the model in their labels and stable picker identity; selecting a
row saves both model and voice. Favorites retain the Mac-compatible voice-only
identifier. Favoriting an OpenAI or Gemini voice exposes each compatible model row with a
distinct native favorite rank; it does not collapse compatible model tuples into one or
write model-qualified strings into the saved favorites array.

Unsupported speed/pitch/SSML and unknown or incompatible model/voice tuples
fail before credential access. Stored choices, unknown favorites and unrelated
Soniox region/language preferences are not reset when choosing another route.
One captured selection and one credential cover the bounded request sequence.
OpenAI segments at 4,096 Unicode scalars without splitting a grapheme; Groq uses
the shared 200-grapheme chunker and refuses more than 60 requests before key
access. Gemini uses the shared 8,000-grapheme guidance and canonical single retry
for retryable server/no-audio faults. Whitespace-only Groq/Gemini chunks refuse
the operation before key access, rather than failing after earlier requests.
Speechmatics uses the existing Unicode-scalar segmenter.

Captured Gemini language uses the existing `GeminiTTSRequest` contract: a
catalogued regional choice such as `en_GB` becomes `en-GB`; Automatic and base
codes retain the canonical detection behavior. Unknown language preferences
remain stored but refuse execution before key access.

The Gemini configuration successor remains **source-only, uncompiled and
unexecuted**. Its model projection and strict resolver enumerate the actual
canonical models, and the captured model reaches request construction and
per-model usage estimates. The current canonical Mac catalogue/runtime defines
**only Gemini 3.1 Flash TTS Preview**; its comments explicitly exclude the older
2.5 previews. Those are not new desktop routes or a remaining catalogue-parity
gap. Provider aliases and absent model IDs retain the existing default; unknown
model IDs remain unavailable rather than falling back.

Both native preference editors use one canonical `ttsLanguage` text field, with
an active-provider label for Gemini or Soniox. Other executable providers
explicitly label the stored value as unused, and an unavailable voice is labelled
as such. Picker and account-voice updates change only the label; they do not
reload unsaved entry values. Linux applies label updates through the existing
posted GTK queue, without a MainActor hop. Windows updates its next-dialog
snapshot and posts a label-only refresh for an open editor. There is no new page,
duplicated language catalogue, credential read or service request for presenting
these controls.

The text editor preserves canonical regional strings and unknown imported
values exactly, including through restart/transfer. Request construction alone
converts Gemini's regional tag; Soniox retains its existing base-language and
Automatic content/device fallback. Switching providers does not change the
saved language, Soniox region or favorites. This is not a new language-detection
engine or a claim that every provider consumes this preference.

Each new completed-audio route requires real, complete, nonsilent PCM/WAV
metadata, aligned samples and the expected rate. Streaming length placeholders,
compressed payloads, mixed rates and truncated headers are not repaired or
relabeled. Speechmatics generation and Read staging retain 16 kHz; no new native
decoder or resampler is introduced. A later segment error/cancellation returns
no partial audio. Existing owned-task admission, Stop/close, History attribution,
archival, native playback and atomic user-chosen export remain the shared paths.
Replay and retained-result export still use the captured bytes without a key.

Groq, Speechmatics and TTS-1/HD use their canonical character-rate estimates,
not invoices. Gemini records only input tokens actually reported for each
attempt, including a no-audio retry, and estimates the audio component from
validated PCM duration. Missing tokens leave input/total cost unknown.
OpenAI mini binary WAV reports neither text/audio token counts nor billing:
its charges stay unestimated. Optional usage fields preserve older ledger
decoding; non-Gemini routes do not acquire invented token measurements.

### ElevenLabs completed speech (source-only successor)

The shared catalogue now owns the Mac's four models, eight offline presets,
case-sensitive voice IDs, three legacy voice aliases and existing model
migrations. The Mac adapter projects those same voices/traits and uses the same
request builders; its provider-default output and existing routing stay intact.
Windows/GTK expose all 32 actual model/preset tuples through the existing native
Voice and Favorites pickers. Rows are model-qualified; saved favorites stay
voice-only. Unknown preferences remain stored and unavailable, never coerced into
a supported voice. Explicit selection records the matching model/quality.

Fast/Balanced/Best Quality select Flash v2.5 / Multilingual v2 / Eleven v4,
respectively, as on the Mac. Explicit Eleven v3 is a fixed-model route rather
than an invented fourth quality; unrelated saves, later stored quality values
and restarts retain it. All ElevenLabs routes use normal speed/pitch, no SSML
and fixed 24 kHz audio. Unsupported controls fail before key access. This slice
does not expose provider tuning parameters as new settings.

The canonical credential is **`elevenlabs.apiKey`**, shared with this provider's
transcription as on the Mac, not a new TTS key or another provider's key. One
captured source/voice/model/quality and one validated key cover each job.
Request plans, fallback plans, text limits and 64 KiB JSON bounds are validated
before credentials; local admission permits at most 60 segments. Speech model
limits are the canonical 5,000 / 10,000 / 40,000 characters, with conservative
Unicode-scalar segmentation that never splits a grapheme.

Eleven v4 uses **Text to Dialogue**, with one actual text/voice input, not a v4
single-speaker speech request. The Mac's reliable 2,000-grapheme boundary is
checked against the whole source before segmentation: longer input chooses
Eleven v3 speech. Dialogue HTTP 400/403/404/422 alone permit the same v3 fallback.
Both attempts retain their actual model in local usage. Authentication, rate
limits, server/transport errors, malformed audio and cancellation never trigger
an unrelated retry/model switch.

Desktop explicitly requests documented **`output_format=wav_24000`** on both
endpoints. It requires complete, nonempty, nonsilent mono PCM16 WAV at exactly
24 kHz, including byte rate/alignment and declared lengths. Raw `pcm_24000`,
MP3, wrong-rate/stereo/depth/truncated responses are errors, not relabelled WAV.
Responses and aggregate PCM retain the existing bounded transport/export limits.
A later failure or cancellation publishes no partial result. Existing owned
Read, Generate, native playback, archival and user-chosen atomic WAV export are
reused; replay/export retain captured validated bytes and never fetch a key.

Usage retains observed Unicode scalars and validated duration separately from
the Mac's preserved approximate USD0.30/1,000 submitted-grapheme estimate.
Preflight estimates use the same segmentation plan; fallback attempts are
separate observations. These are not current plan/model quotations, invoices,
provider token counts or proof of billing. No newer price is invented.

Official contracts: [speech conversion](https://elevenlabs.io/docs/api-reference/text-to-speech/convert),
[dialogue conversion](https://elevenlabs.io/docs/api-reference/text-to-dialogue/convert)
and [model definitions](https://elevenlabs.io/docs/models). WAV/PCM are distinct;
44.1 kHz account-tier requirements do not establish 24 kHz access for any actual
account. Catalogue presets are not account entitlement evidence.

This successor and its regression sources are **uncompiled and unexecuted**.
ElevenLabs account/custom-voice discovery, models outside the current Mac
catalogue, additional output rates/codecs, progressive playback and actual
account/native/device acceptance remain gaps. The separate high-rate
generated-audio admission repair must accompany 48 kHz quality composition;
it is deliberately not folded into this R4-based provider successor.

### Quality, models and actual delivery controls (source-only successor)

`VoiceSynthesisQuality` now owns the Mac's existing `standard`, `high` and
`highest` identifiers, labels and defaults. Mac adapters retain their behavior
through this shared definition; it is not a new list of provider quality modes.
The native configuration form adds one canonical `ttsQuality` choice, persisted
in the sole Voice settings model and captured in each admitted job.

| Route | What quality actually changes | Actual speed range |
|---|---|---|
| OpenAI | Fast selects mini, Balanced TTS-1, Best Quality TTS-1 HD; audio remains 24 kHz | 0.25-4 |
| Cartesia / Soniox | Requested and strictly validated WAV rate: 16 / 24 / 48 kHz | Canonical Cartesia 0.6-1.5 / Soniox 0.7-1.3 |
| Deepgram | 24 kHz; Best Quality requests and validates 48 kHz | Normal speed only |
| Azure neural | 24 kHz; Best Quality requests and validates 48 kHz | 0.5-2 |
| Azure MAI | The same 24 / 48 kHz WAV selection; no numeric prosody added | Normal speed only |
| ElevenLabs | Fast Flash v2.5 / Balanced Multilingual v2 / Best v4 dialogue with explicit v3 fallback; explicit v3 stays fixed | Normal speed only; fixed 24 kHz |
| Gemini / Groq / Speechmatics / Mistral / xAI | Fixed existing format/rate; no quality request parameter invented | xAI 0.7-1.5; the others normal speed only |

Quality labels describe the selected provider's mechanism, not a latency
guarantee. Fixed-format providers normally disable the unused quality control
while retaining its value. An unknown stored choice enables the field for
explicit repair, not as a claim that the provider gained quality controls.
Provider changes update titles/availability without overwriting unsaved values.
Unknown qualities remain explicit unsupported rows; execution refuses them
before key access. Partial imports, restarts and old numeric-control callbacks
preserve quality rather than clearing it.

Old settings and callbacks with no quality retain the explicitly selected model
and previous PCM defaults. The editor derives the initial OpenAI quality from
that model, including legacy model aliases, so saving unrelated preferences does
not turn mini into TTS-1. An explicit quality overrides the retained raw OpenAI
model through the canonical compatibility map. The picker, captured request
and usage record use that effective model/voice tuple; the credential remains
in the dedicated canonical TTS slot.
Choosing a model-qualified picker row explicitly records its matching quality.
Ballad/Verse cannot silently become a different voice to satisfy TTS-1/HD.
Favorites remain voice-scoped; regional/account evidence remains unchanged.

Read, Generate and text export carry the captured rate end-to-end: request,
strict WAV decoding, exact header and native playback staging must agree.
Wrong-rate PCM is rejected, never relabelled or resampled. Deepgram's existing
24 kHz segmented Read remains unchanged; its new 48 kHz choice uses the existing
bounded complete-audio/native-player path. Retained playback/export still uses
the original validated bytes without consulting later settings or credentials.

The current Mac settings and executable client contracts do **not** define a
separate provider style/instructions preference or request field. Their actual
delivery controls are speed, pitch, editable source text and SSML. Native
controls keep the same per-route gating and now show scrollable, selectable
quality/delivery guidance using the Mac helper's shared SSML examples. Only
SSML-capable Azure routes show those examples; tag support still depends on the
provider. Complete documents retain their own prosody and fragments use the
supported sliders. No Gemini prompt/style field is inferred from a comment.
The native SSML Helper interaction is described below.

This successor, its focused regression sources and native fixture extensions
are **uncompiled and unexecuted**. Earlier receipts do not qualify it.

**Remaining scope gaps:** MP3/M4A use the source-only, exact-rate native format
routes above; unavailable codecs/rates and runtime qualification remain open.
Other canonical provider models remain
unavailable unless their desktop engine explicitly implements them (for example,
the current Cartesia default-model projection). Gemini models excluded from the
canonical catalogue are not advertised. Separate style/instruction controls are
not implemented on either inspected path; additional format controls and
progressive playback remain gaps. ElevenLabs account/custom-voice discovery,
OpenRouter and system speech remain outside this slice. No new provider probe,
native runtime, device, packaged-app or full-product parity acceptance is
claimed by this source composition.

### Native SSML Helper (source-only successor)

The existing Windows and GTK source editors add **SSML Helper** beside the text
snapshot. It is available only for an executable SSML-capable route with saved
**Use SSML** enabled, and only for editable **Typed text / Text file** drafts
without a pending import. History and explicit clipboard snapshots remain
read-only; the helper does not silently switch sources or modify History.

Like the actual Mac sheet, the helper shows the canonical common-tag examples.
**Copy example** copies exactly the selected example, including Unicode IPA,
without inserting it, replacing a selection or reading clipboard contents.
**Close / Escape** leaves the draft and selection unchanged. **Wrap with
`<speak>`** wraps the entire current draft and closes the helper. It reads the
draft at apply time, not a stale snapshot captured when opening the helper.
The exact Mac literal-marker rule is retained: a literal `<speak>` anywhere
leaves the text unchanged; attribute-bearing, uppercase or self-closing variants
are not treated as that marker. The helper neither escapes text/entities nor
validates XML, and does not invent selected-words-only wrapping.

The native editors retain the original selected span after inserting the
opening tag, using UTF-16 offsets on Windows and Unicode-scalar offsets on GTK.
A changed draft is one undoable edit; an already-wrapped draft is not rewritten.
The helper uses native modal controls, labelled selectable examples, keyboard
navigation, a primary/default Wrap action and focus restoration to the source
editor. Availability updates disable Wrap without reloading draft text or
unsaved controls. Apply rechecks capability and import state; a rejected or
oversized edit leaves the draft and selection intact with an explicit notice.

Editing alone never generates speech, accesses credentials, saves preferences
or changes an already captured job or retained result. The existing Read,
Generate and Export actions capture the edited draft only when explicitly
invoked. Action 119 and its legacy numeric-control payload remain unchanged.
There is no new page, provider, codec or progressive playback path.

Focused shared/host regression sources and both native source self-test
extensions cover these semantics. Native fixtures inject a synthetic wrapper
and in-memory example-copy sink, not a real clipboard/provider/key operation.
All new sources and fixtures remain **uncompiled and unexecuted** under HOLD;
source authentication is not native keyboard, DPI, accessibility, packaged-app
or provider acceptance. The format/model/progressive gaps above remain open.

**Cartesia Sonic 3.6** executes the five existing `CartesiaTTSCatalog` presets,
not the entire account library or older stored Sonic models. Read, Generate and
text export reuse `CartesiaTTSAPI` request construction, API version and the
shared `cartesia.apiKey` used for Ink transcription. Audio is actual mono PCM16
WAV at the captured 16/24/48 kHz quality rate (24 kHz when absent); no compressed
or progressive transport is advertised.
The existing native Voice controls execute the canonical 0.6-1.5 speed range.
Pitch and SSML are disabled but preserved; incompatible controls refuse synthesis
before key access instead of letting the shared request builder clamp them.
Unknown voices and older models remain stored/unavailable, never substitute a
default preset or another provider.

The shared Automatic language resolver uses content detection when the platform
has it, otherwise the device language. There is no new explicit language setting
in this slice. Long desktop input uses the existing 4,500-character
`TTSTextChunker` target, not an asserted Cartesia service limit. One immutable
credential and language selection cover every chunk. Every response is bounded,
validated and joined before publication; a later failure never returns partial
audio. Existing native playback, retained replay/export and publication helpers
are unchanged. Actual requests and validated PCM feed local usage with the
canonical USD0.0392/thousand-character **Startup-plan estimate**, not a billed
charge or a guarantee of the user's plan. Cartesia account discovery, explicit
language and physical/service acceptance remain gaps. Non-WAV files use the
unqualified exact-rate native conversion route described above, not a different
Cartesia response format.

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

**Purpose-specific Voice key entry (local candidate)** adds a native Provider key
action on the Windows Voice page and legacy Voice chooser, and a native password
row on Linux's existing Voice page. Neither changes General/transcription key
entry, the page count, settings keys or the provider catalogue. The dedicated
callback carries the Voice purpose, exact canonical slot, request UUID and
selection epoch; it never reinterprets a transcription model index.

`VoiceOutputCredentialSlot` validates the executable voice against the shared
purpose resolver and the engine's actual credential identifier. Deepgram uses its
canonical provider identifier, including Flux's unprefixed model/voice names.
OpenAI always uses `openai.tts.apiKey`, never `openai.apiKey`. Azure validation
reuses `AzureSpeechConfiguration`, including its existing bare-key/eastus default.
Synthesis of account voices still requires matching current account evidence.

Saved, missing, unavailable and busy states are distinct. Keys are masked and
never prefilled; blank replacement refuses instead of deleting. Removal is a
separate confirmed action. Shared-key effects and existing key-sync preferences
are disclosed. Replace and remove use the existing secure vault/hand-marked
`saveKeyByHand` path, not plaintext settings, History, usage or audio exports.

Save admission returns immediately; the host owns and counts the cancellable
operation through shutdown's existing grace period. Default synchronous vault
reads/writes run outside the host actor: cancellation cannot release ownership
or allow a racing replacement/removal while a native write is unfinished.
Native view reads coalesce to one in-flight lookup and the latest requested view;
close remains responsive even if the vault ignores cancellation. Owned text imports
and account discovery also block replacement/removal until they actually settle,
including after cancellation. Cached xAI account evidence is checked only for an
actual xAI selection; unrelated providers read only their own credential.
Selection epochs fence
away-and-back changes, and native request/epoch checks reject stale responses
without clearing newer input. Closing/cancelling cannot promise rollback of a
vault operation that already wrote; errors are sanitized and unconfirmed or
late confirmed writes are reported honestly. No History ownership, speech handle,
publication helper, capture lifecycle or synthesis request is changed.

Windows reserves Voice button185, credential controls1030-1037 and `WM_APP+29`.
The shared C credential header introduces no global Voice events110-119.
Linux posts UI work through the existing GTK queue, without a MainActor hop.
UUID identities accept GLib/Swift case differences; credential identifiers remain exact.
Synthetic backend/native fixtures do not access a real vault or provider.
Local source checks are not full-app Windows/Linux or Apple runtime acceptance;
the earlier unresolved native adapter failure remains unresolved.

**Modern account provider forms (component-qualified candidate)** replace the
xAI-only launch caption with **Account voices**. Initial open uses the explicit
`118/account-open-modern` carrier, source `-1`, empty text and a canonical
36-character session UUID; legacy account-open payloads remain distinct.
Provider choices come exclusively from `VoiceAccountProvider.all` through the
host projection. The native chooser proposes a different fresh epoch, then
keeps provider/key/Refresh/list/Pick disabled until an exact
session/epoch/provider acknowledgement and matching inventory have arrived.
An empty Mistral account list is explicit: key entry and Refresh become
available after acknowledgement, but Pick remains disabled. Opening, the
initial handshake and closing do not look up a cached key, list voices or
synthesize; Refresh and key actions remain explicit.

Provider key entry has independent native state and never touches the selected
voice key form. Each read/write result must match the form's session, epoch,
provider and outstanding request; writes echo only the host-issued slot.
Entry starts masked and empty, native temporary copies are wiped, and Remove
requires confirmation. A write outcome remains visible after the follow-up
state read, including failure; closing is not rollback or permission to retry.
Browsing providers leaves the selected voice tuple and its credential workers
unchanged.

Each window run owns a registration handle. Ending that exact handle closes
native admission, advances its generation and waits for synchronous Swift
borrowed-string copying/FIFO admission before releasing the strong holder
lease. Double or delayed end cannot unregister a replacement, including
same-holder reuse. Only begin registers; late presentation cannot revive it.
Posted results hold no callback/holder snapshot and reject stale generations
before form access. GTK unregister does not post widget changes or wait for a
stopped loop. The original selected-key callback and four exports are unchanged.

Synthetic component qualification is not production app acceptance: a hidden
Windows widget/registry fixture and an exact Linux Swift helper with the real
GLib registry, Core parser and desktop FIFO can exercise these boundaries
without real keys or user text. The helper uses a synthetic holder/controller
and executes no GTK widgets. GTK widget execution additionally requires a
compatible Adwaita runtime; header syntax alone is not runtime evidence.
Production Swift/C app shutdown, ARM, Apple and real-vault/provider journeys
remain separate gates. This component-qualified candidate is not selected for
production; holding persistence alone does not authorize composition or activation.

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
player, regardless of the Generate auto-play preference. **Export text...**
asks for a local destination before synthesis and does not play the audio.
Both use the selected executable voice and its saved provider credential and
send text to that provider. Azure uses the existing Azure Speech credential
(`key:region`), saved through the normal provider
settings, not a second Voice credential store. Text export requests speech again.

**Generate** captures the text, voice, synthesis controls and both generation preferences, produces
one complete validated audio result in the captured format and retains it independently of later editor or
preference changes. **Auto-play generated audio** defaults on; with it off,
generation completes without speaking and **Play result** is still available.
**Export result** copies the exact retained container to a user-chosen location. Replay and
result export never send a new synthesis request or require a fresh credential.
Starting another voice job supersedes active work; Stop preserves an already
completed result. Only one counted generated-audio operation is admitted, even
if a cancelled provider or filesystem is still closing.

**Save audio to recordings** defaults off. When enabled for Generate, the store
actor archives an independent flat `UUID.<captured extension>` in the actual managed History
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
The sole voice model persists optional `ttsSpeed`, `ttsPitch`, `ttsUseSSML` and `ttsQuality`;
absent values mean speed 1, pitch 0 and plain text. Shared `VoiceSynthesisOptions`
admits finite speed 0.25-4 and whole-number pitch -12 to 12 semitones, then
validates speed against the captured provider's canonical, usually narrower range.
Azure neural voices execute speed, pitch and SSML through the existing shared
Azure request builder. Deepgram supports only normal controls: unsupported
controls are disabled but their stored values remain visible and unchanged.
Read/Generate/text export explicitly refuse incompatible choices before reading
a credential, rather than silently ignoring them or changing provider.
**Normal controls** explicitly resets numeric speed/pitch and SSML, not quality;
an absent quality in its legacy callback preserves the saved choice. Selecting
another voice preserves these controls; an explicit OpenAI model tuple records
its matching quality. Unknown provider choices appear as unavailable, not Deepgram.
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
existing segmented playback at 24 kHz and uses that same bounded generic player
at 48 kHz. No independent playback engine or IPC is added.

Long text uses the canonical segmenter. Export validates each provider response,
joins decoded mono PCM16 at the captured actual rate (16 kHz for Speechmatics;
quality-selectable 16/24/48 kHz where supported; otherwise the existing 24 kHz),
and writes exactly one RIFF/WAVE header, with
a 64 MiB PCM limit, before any selected native container conversion.
A failed segment or codec pass produces no partial destination. The native
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

All displayed costs are **estimates, not measured/billed charges**.
No provider billing receipts are available. Gemini input tokens are recorded
only when reported; its audio component uses measured validated PCM duration,
not an inferred audio-token count. Other routes do not invent token counts.
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

## Mistral shared backend boundary (not native UI acceptance)

The bounded Mistral candidate reuses macOS's actual `MistralTTSCatalog`,
`MistralTTSRequest`, `MistralTTSAPI` and `TTSTextChunker`: the pinned default
Voxtral model, 1,800-grapheme guidance and a non-streaming JSON/base64 speech
response. This is guidance, not an invented service hard limit. Joined chunks
preserve the trimmed input, including internal whitespace and Unicode grapheme
clusters. The rolling alias is not exposed as an executable desktop choice.

Mistral has no offline preset list. Only a completely received, validated account
inventory can supply an executable voice, and the immutable selection retains
its provider, discovery session/epoch, metadata and captured-key evidence.
Provider-context mismatches, unavailable or forged voices and unsupported
speed/pitch/SSML are refused before credential or speech HTTP admission.
Synthesis captures one key for every chunk and refuses an inventory belonging
to another key. Replacing a native selection must still cancel and fence the
owning operation before accepting any late result; this shared backend does not
select, persist or publish a native tuple.

Account listing uses canonical page size/offsets with at most ten pages,
512 accepted voices and 512 KiB per page. A duplicate UUID (including another
case spelling), malformed entry, response overflow or later-page failure
rejects the entire new listing, never a partial success. Errors distinguish
missing keys, cancellation, service status, invalid listings and transport.
Explicit-provider credential messages have their own typed discovery context;
parsing is not host authorization to read or write a vault slot.

The desktop candidate requests WAV, bounds each JSON response and cumulative
PCM, and validates the decoded file against the existing native mono PCM16,
24 kHz contract. An actual other-rate/format, silent, truncated or malformed WAV
is refused; no guessed sample-rate request field, relabelling, raw float32
interpretation or implicit resampling is used. Completed chunks contribute
actual submitted Unicode-scalar observations and validated PCM duration.
Canonical character-rate estimates use submitted graphemes after segmentation,
matching macOS; they are estimates, not charges, tokens or provider receipts.
Typed/clipboard requests retain nil History attribution.

The account-provider projection, parser and synthesis backend are shared-only
work until separately reviewed source qualification and native integration.
No Mistral provider selector, key/list/pick UI, new setting or native ABI is
enabled by this candidate. Native Mistral playback/accessibility, real account
responses and Apple acceptance remain unverified; fake HTTP evidence is not a
provider service probe or complete Voice parity.

### Explicit-provider host boundary (not exposed by native UI)

The explicitly tagged `account-open-modern` event on carrier118 requires
source-1, empty text and a canonical36-byte session UUID. Its host path creates
a fresh provider epoch and presents canonical presets or an empty listing
without reading a cached account key. Legacy `account-open` retains its original
opaque/braced-token behavior; modern mode is never inferred from token spelling.
Both paths share owned dialog reset/cancellation. The modern startup seam and
thin Swift dispatchers do not themselves expose native controls or a C ABI.

The host candidate adds a separate account-dialog session and acknowledged
provider epoch. Modern Refresh/Pick require that epoch, not a legacy dialog
token; Close retains the session identity. Provider transitions synchronously
clear offered choices and issued slots before awaiting anything. A completed
listing must match its provider, captured key and context, and Pick rechecks
the key before atomically saving the complete model/voice tuple. Listing and
credential operations alone do not change that tuple. Browsing another provider
does not erase evidence for the current saved voice; a new dialog cannot Pick
an old dialog's evidence simply because its key still matches.

Explicit-provider key entry obtains its slot from the canonical purpose
resolver, without requiring an already picked Mistral voice. The host must
issue that slot for the current context before admitting replacement/removal.
Selected-voice entry and explicit-provider entry share the same coalesced,
owned vault worker; their epochs are not interchangeable. Blocking vault I/O
is detached, and reads, writes, listing and synthesis remain counted until
actual settlement after cancellation. Late confirmed writes remain truthful
and invalidate the affected account evidence even if their dialog changed.
Provider switch, dialog close and reopen cancel only credential workers owned
by the displaced explicit-provider context, before clearing that context.
Selected-voice reads/writes survive browsing with their unchanged selection
epoch. The coalesced read's worker destination is retained separately from its
latest requested destination, so a closing provider cannot clear a queued
selected-voice request. Writes retain their owned destination through actual
settlement; full controller shutdown still cancels every credential worker.

Provider/session changes cancel and fence active account-only synthesis,
without cancelling unrelated built-in Voice output, retained replay/export or
text import. Actual synthesis owns its credential lookup; unsupported controls
fail before lookup/HTTP, and cancellation does not permit a racing key write
while a native lookup is still settling. Generic account evidence is passed
through Read, Generate, text export and estimates. Completed audio retains the
existing native WAV/publication path, actual History UUID-or-nil attribution
and usage opt-out; no token counts or billing receipts are inferred.

These are internal host seams and synthetic tests only. The existing selected
credential C ABI and native controls are unchanged. Mistral provider/key/list/pick
controls, full native app/vault/playback/accessibility and Apple/runtime service
acceptance remain a separately reviewed native integration, not accomplished
by this host checkpoint.

## Soniox completed-audio candidate (source only)

The portable desktop engine reuses `SonioxTTSCatalog`'s v2 model, built-in voice
identities, legacy v1 migrations and canonical regional endpoints. The shared
`SonioxTTSAPI` request builders serve both the unchanged Apple HTTP API and the
desktop bounded transport; there is no copied regional protocol or preset list.
Although the canonical model name contains "Real-time", this desktop route
requests complete mono 16-bit PCM WAV at the captured 16/24/48 kHz quality rate
(24 kHz when absent), not progressive delivery.
`SonioxTTSRealtime` remains unavailable on Windows/Linux.

The existing native Voice picker exposes canonical built-ins. Account providers
also project Soniox into the existing provider/key/Refresh/Pick form. A regional
listing is bound to its key, session/provider epoch and captured processing region;
only v2-ready clones are executable. Deleted, unready or unrefreshed clones retain
their stored identifiers and favorites but are unavailable until explicitly
refreshed and picked. Unlike the Mac fallback presentation, desktop never silently
replaces a missing clone with Maya. Mixed model/provider selections are refused.

Native preferences add **Soniox processing region** (US/EU/JP) and **Soniox voice
language** (automatic or a canonical locale) through existing native configuration
controls. These values live in the sole `DesktopVoiceOutputSettings` model, not
duplicate configuration mirrors. Partial imports preserve absent preferences and
favorites; unknown regional strings remain exportable but cannot activate a
request. Recognized legacy region aliases are canonicalized only in the editor
projection until an explicit save. Dictation profiles do not override Voice's
independent language or region. Speed is 0.7-1.3; pitch and SSML remain unsupported
and fail before credential lookup instead of being ignored or clamped.

Each Read/Generate/source Export captures selection, region and language before
owned asynchronous credential I/O. Region changes retire old provider forms and
listings, invalidate clone evidence, and cancel only a current Soniox synthesis
ticket; retained replay/export and unrelated-provider output keep their ownership.
The existing account worker, usage and operation accounting remains balanced until
actual settlement. Existing generated WAV archival, retained audio export and
History UUID-or-nil attribution are reused; source text and credentials do not
enter the usage ledger.

Synthesis splits at grapheme boundaries under the canonical 5,000-character
request limit, reads one key, and uses a single 120-second HTTP budget with 64 MiB
response and aggregate audio bounds. Every response must be a complete valid WAV;
streaming length sentinels, malformed/truncated chunks, duplicate format/data
chunks, wrong-rate/channel/sample formats and silent audio are refused. No
partial multi-segment result is published. Discovery has a 20-second total budget,
512 KiB per page and a bounded total voice/page count. Redirects are refused by
the existing transport; neither discovery nor synthesis falls back to another
regional host. Public errors classify failures without reflecting response text,
keys or provider-controlled error fields.

New synthetic source regressions cover canonical selection/migration and regional
wire builders, ready/deleted/unready clones, complete/segmented/bounded audio,
cancellation, stale context/key/region fences, sole-model restart/transfer/favorites,
profile independence, generated archival/export and usage. These tests have not
been executed for this candidate. Builds, strict lint, portable/Apple tests,
Windows/GTK native interaction and callback/holder qualification, installed
packages, actual accounts and physical playback remain pending. No real provider
call or native/audio activation is part of this source-only delivery.

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
System and wider providers, qualification of the new exact-rate non-WAV export
routes and broader Voice workspace parity remain gaps. Advanced configuration transfer is a
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
