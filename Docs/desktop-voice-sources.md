# Desktop Voice Output sources and WAV export

## Local archival bridge boundary

The unpublished native Voice bridge is a read-only source/state projection, not
a migration manifest, category selector or Mac `ttsUsage` mapper. The owned app
root is `DesktopHostController.directory`; its fixed source is
`VoiceUsage/requests.json`, bounded at 2,097,152 bytes and the existing 1,000
retained records. `DesktopVoiceUsageReadAccess` takes an injected reader returning
original `Data?` and a throwing `@Sendable` receipt-revalidation closure. Nil
means a verified missing source, not unreadable or corrupt data. Composition must
bind this closure to the separately verified shared owned-file reader; this
branch has no native reader fallback, copied identity implementation or new
filesystem authority. A digest comes from the existing platform SHA-256 provider.

`voiceUsageSnapshot(access:digests:)` copies actor-owned memory and active usage
capture metadata, reads off the actor, then fences the result against actor
revision, tracking epoch and changes to the captured attempt arrays. One
collection is admitted at a time; cancellation remains explicit, workers remain
counted until they end, and close rejects late results. No HTTP/audio/controller
task is retained by the active-capture registry.

The projection distinguishes missing, accepted, invalid, unreadable, oversized
and changed sources. Invalid/unsupported bounded bytes remain available exactly
as read, with their digest but without typed acceptance. Active captures,
completed unsaved observations and the legacy loaded-record cache are separate
provenance views, not lists to concatenate: their request UUIDs can overlap.
Active attempts are unfinished observations, not completed audio or billed usage.
New completed observations survive failed load/save in a separate bounded
in-memory buffer. Buffer omissions/encoding failures are explicit, not silent
evictions; the bridge cannot reconstruct observations or unknown fields already
lost by earlier code. Tracking opt-out still invalidates in-flight captures.

`DesktopVoiceUsageLedger` accepts the existing typed ledger contract in the
native writer's UTF-8 encoding while retaining original element bytes and order,
including unknown members and number spelling. UTF-16/32 originals remain raw
unsupported evidence; they cannot be spliced into UTF-8 output.
`preparedAppend()` is **pure preparation**, retaining existing elements,
deduplicating matching request UUIDs and preserving the existing latest-1,000
policy. It refuses invalid sources, conflicting UUID values, known buffer
omissions/encoding failures and loaded memory that cannot be reconciled with
either the original source or the prepared result. It neither writes a file
nor supplies write/publication authority.
A point-in-time read receipt and revalidation do not make a later overwrite
atomic or eliminate check/write races. The new raw-preserving append/write
engine remains **unwired** pending a separately qualified owned-write contract.

Default native persistence remains unchanged: successful legacy writes still
use their existing typed JSON encoding and can erase unknown members. The loss
fix does not disable normal writes, alter retention, add provider requests or
change Voice playback. There is no complete native archival-authority claim
until actual reader/write composition is qualified. No source text, credentials,
fabricated tokens/cost/duration, inferred audio link, archive category/kind/scope
or import/apply behavior is introduced by this bridge.

Windows and Linux remain developer previews, not macOS-parity releases.
Voice Output uses shared Deepgram, Azure neural, Azure MAI, xAI, Cartesia, Gemini,
Groq, Speechmatics and OpenAI REST speech contracts,
canonical catalogue projections and native playback. `DesktopSpeechVoice` exposes only
routes the host executes, not every provider in the macOS catalogue. The seven
built-in Azure neural catalogue entries now have one `AzureNeuralVoiceCatalog` definition
shared with macOS; native hosts do not copy voice entries.
The current MAI-Voice-2.1 and Flash speakers come directly from the existing
`AzureMAIVoiceCatalog`, including their locale/model identifiers. MAI uses the
same regional Azure request builder, saved `key:region` credential and native
WAV decoding/playback, not a second provider client or credential store.

**OpenAI (local candidate)** uses one `OpenAITTSCatalog` for Mac and desktop.
Native Voice pages and settings describe the selected provider rather than
incorrectly claiming that every voice sends text to Deepgram. The separate
OpenAI TTS credential is separate from transcription. Its original synthesis
source qualification does not cover the subsequent native key-entry candidate below.
Mac's eleven `openai/<voice>` identifiers, order, names and traits remain intact.
Its default quality is still High (`tts-1`); Standard selects
`gpt-4o-mini-tts`, Highest selects `tts-1-hd`. The documented TTS-1/HD subset
excludes Ballad and Verse. Desktop appends only the 29 executable model/voice
tuples; a voice identifier can occur with different model identifiers, so the
complete tuple, not a voice ID alone, identifies the picker selection.
Unknown/foreign/incompatible tuples refuse execution without default-voice
substitution or rewriting stored preferences.

Mac and desktop share the `OpenAITTSAPI` request builder and separate existing
`openai.tts.apiKey` credential (never the transcription key). Mac retains its
MP3/AAC/WAV request formats. Desktop executes **24 kHz mono PCM16 WAV only**,
using the existing host speed range 0.5-2 (within the API range 0.25-4).
Pitch/SSML are unsupported and disabled; retained incompatible controls refuse
before credential access. No instructions, language, progressive output,
additional API voices, new UI IDs, native ABI or settings keys are introduced.

Each native request is bounded to 4,096 Unicode scalars without splitting
graphemes; indivisible oversized input refuses before credentials. One captured
key serves sequential requests, each response is validated at the actual rate,
and later failure/cancellation never publishes partial audio. Native playback,
independent archive, retained replay and chosen WAV export use existing
publication/ownership helpers unchanged. History attribution stays the actual
History UUID or nil for non-History sources.

Observed usage includes submitted scalars and validated PCM duration, not
provider receipt or billing. TTS-1/HD character estimates use submitted grapheme
counts after segmentation and canonical USD0.015/0.030 per thousand characters.
Mini TTS is priced in text/audio tokens: its binary WAV response reports no
tokens, so token counts and input/audio/total charges remain **unestimated**,
not inferred from characters or duration. Mac's existing legacy cost display is
not refactored or treated as desktop mini pricing authority. No live OpenAI
service or physical-device acceptance is claimed by this local candidate.

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
close remains responsive even if the vault ignores cancellation. Selection epochs fence
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

**Speechmatics (local candidate)** executes the four canonical English voices:
Sarah/Theo (UK) and Megan/Jack (US), appended to the existing native picker.
Read, Generate and text export reuse the same `SpeechmaticsTTSAPI`
URLRequest builder as Mac, the shared `speechmatics.apiKey`, and canonical
segmentation. The provider has no model, speed, pitch or language request
selector. English is named in the voice labels; numeric speed/pitch and SSML
are disabled and incompatible retained values are refused before key access.
Unknown voices and foreign model/voice tuples are unavailable, never silently
replaced by the permissive legacy Mac request resolver.

Only complete non-silent mono PCM16 `wav_16000` responses are admitted.
Each segment must match the route's actual 16 kHz rate; mismatched/mixed-rate
chunks, malformed/truncated audio or later failures publish no partial result.
Joining retains that rate and calculates duration from the actual frame count,
without relabelling or resampling. The generated-result validator now accepts
explicit 16 kHz or 24 kHz expectations; its existing default remains 24 kHz.
Every existing provider keeps its previous 24 kHz validation and output.
Native playback, archival and export receive the validated WAV unchanged;
retained replay/export need no new synthesis request or credential.

Observed input remains Unicode scalars. Speechmatics estimates use only
submitted grapheme counts after segmentation/trim, matching Mac's `String.count`,
and the canonical Pro-plan USD0.011/thousand-character estimate. Audio seconds
are measured from validated PCM, with no invented tokens, charges or receipts.
Key/access, exhausted-credit and rate-limit errors are distinct and do not
echo provider bodies. Stop/close retain the existing cancellation, shutdown and
History-or-nil ownership contracts. No native ABI, controls, events, settings
keys, playback/publication implementation or provider fallback is added.

A local device-free Windows fixture executes the unchanged native MF
decoder/render pipeline at both 16 kHz and 24 kHz, proving exact synthetic
samples, durations and unchanged sources. It does not prove physical playback
or resolve the separate red pause/resume gate. Linux's existing header reader
passes the exact rate through to its existing PulseAudio mono PCM16 stream;
no new Linux native-execution receipt, real-provider, Apple or iOS runtime
acceptance is claimed for this local candidate.

**Groq Orpheus (local candidate)** executes the twelve canonical personas:
six English and six Saudi Arabic voices, each bound to its own model. The
existing native picker appends them without changing earlier voice indices.
Unknown, retired PlayAI, foreign and wrong-model choices remain unavailable;
the permissive Mac request builder cannot silently replace a desktop choice.
Read, Generate and text export share `GroqTTSAPI` request construction and
`groq.apiKey`. Canonical segmentation caps each request at 200 characters and
refuses more than sixty requests before reading a key. One captured credential
covers sequential requests, with no provider retries. Model terms, organisation
access/spend limits, key rejection and quota failures have distinct advice;
provider response bodies are never echoed.

Only complete, bounded, non-silent 24 kHz mono PCM16 WAV responses are admitted
to the existing native playback/export pipeline. Sample-rate/channel/depth
mismatches and later-chunk failures never publish partial audio. Numeric
speed/pitch and SSML are unsupported: native controls are disabled, stored
choices are preserved and execution refuses incompatible settings before
credential access. Existing retained replay/export and History-or-nil ownership
are unchanged; no new controls, events, settings keys or native ABI are added.

Groq estimates use the canonical submitted `String.count` after segmentation,
matching the Mac client, at USD0.022/thousand English or USD0.040/thousand Saudi
Arabic characters. The separate observed input count remains Unicode scalars;
it is not relabelled as a billing count. Requests keep measured validated-PCM
duration and nil token counts, never fabricated charges or receipts. Input
estimates use the same segmentation/counting rule as actual synthesis. This
candidate has no real-provider/physical-speaker receipt or new native/Apple CI
qualification; the frozen published Gemini head's red x64 adapter remains
unresolved, not waived by local tests. System voices, additional providers,
explicit language/progressive delivery and selectable format/quality remain gaps.

**Gemini 3.1 Flash TTS** executes all thirty canonical `GeminiTTSCatalog`
voices through the shared Interactions request and `google.apiKey` used for
Gemini transcription. Unknown voices, foreign model/voice pairs and older
stored previews remain unavailable, without the shared builder's default-voice
fallback. Numeric speed/pitch and SSML are unsupported: native controls are
disabled, stored values remain visible, and non-default settings refuse before
key access. **Normal controls** is the explicit reset.

Read, Generate and text export use canonical 8,000-character chunks, one captured
credential, automatic provider language detection, bounded HTTP responses and
validated 24 kHz mono PCM16 WAV. The shared documented server/no-audio retry is
limited to one extra attempt per chunk; auth, quota, content, malformed audio
and transport failures do not trigger provider retries. Every actual attempt
is observed separately. A later failure never publishes partial audio.
Existing native decoding/playback, retained replay/export, publication and
History-or-nil ownership are unchanged. There is no progressive delivery,
explicit language or selectable format/quality in this journey.

Gemini's reported text-input tokens are optional real response metadata, not
inferred from characters. Audio cost is a canonical **duration-based estimate**
from validated PCM at USD0.0005/second. Reported-token input cost uses
USD0.000001/token; missing tokens leave input and total cost **unknown**, while
the known audio component remains visible. A reported zero is distinct from
missing metadata. No billed amount, invoice or output-token count is invented.
Unlike the Mac client's existing four-characters/token estimate, desktop usage
does not fill missing tokens with a heuristic. Native Usage displays these
components without double-counting its complete-price subtotal. Account/service,
physical playback and final-head target acceptance remain distinct from
synthetic portable/local native validation.

**Cartesia Sonic 3.6** executes the five existing `CartesiaTTSCatalog` presets,
not the entire account library or older stored Sonic models. Read, Generate and
text export reuse `CartesiaTTSAPI` request construction, API version and the
shared `cartesia.apiKey` used for Ink transcription. Audio is actual mono PCM16
WAV at 24 kHz; no compressed or progressive transport is advertised.
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
language, format/quality selection and physical/service acceptance remain gaps.

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
joins decoded mono PCM16 at the route's declared rate (Speechmatics 16 kHz;
existing routes 24 kHz), and writes exactly one RIFF/WAVE header, with
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
Groq and Speechmatics pricing use submitted grapheme counts separately from this scalar
observation, including canonical segmentation and whitespace trimming.

All displayed costs are **published-rate estimates, not measured/billed charges**.
Character-priced routes have no reported token counts. Gemini additionally keeps
only actual reported text-input tokens and separate input/audio estimates;
missing input tokens leave its total unknown, not estimated from characters.
No provider billing receipts are available on these routes.
The completed-audio subtotal excludes unpriced entries and names that exclusion.
SSML markup, provider character rules, discounts and regional pricing can
change actual charges. A transport attempt does not prove server receipt, and
a failed/cancelled request can still incur a provider charge.

The bounded local ledger is `VoiceUsage/requests.json`, in a private directory,
retaining the latest 1,000 request observations rather than claiming lifetime
or billing-account totals. It contains no text, audio, key or provider body.
Optional Gemini token/component fields are absent for character-priced routes;
older ledgers remain readable without manufacturing new measurements.
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
