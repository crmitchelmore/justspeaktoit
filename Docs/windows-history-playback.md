# Windows History playback

The History pane plays the selected recording inside the app. Play/Pause,
Stop and an elapsed/remaining display follow the Apple History controls:
Play starts from the beginning, Pause freezes the audio and the time, Resume
continues from the same point, Stop returns to zero, and a finished playback
returns to idle. Selecting a row never starts playback. The existing Open
audio action still launches the registered external application; native Play
is additive. Seeking is not part of this slice.

## Native engine

`WindowsPlayback.cpp` owns one pinned handle per playback. Creation opens the
recording read-only with write and delete sharing denied, refuses
directories, non-disk files and a leaf reparse point, and accepts one byte to
1 GiB (two hours of 24 kHz PCM16 history is about 346 MB). That handle is the
only stream Windows decodes from; the path is never reopened and the file is
never modified. Media Foundation is loaded from System32 on demand, so a
Windows N installation without the Media Feature Pack still launches and
reports a descriptive playback error.

The decode worker asks the installed codecs for the default multimedia
endpoint's shared-mode mix format and rate, so Media Foundation performs the
one conversion. If the decoder cannot reach that format it decodes float at
the source rate and the Windows audio engine converts. There is no forced
transcription-rate conversion, custom resampler, external player, web view or
transcription step. Each decoded sample is bounded to four seconds of output
(1 MiB to 64 MiB) before Windows coalesces it, and decoded PCM crosses a fixed
two-second single-producer/single-consumer ring into the render thread.

The render thread waits on the WASAPI event and copies whole source frames
from the ring into the engine buffer. It never synthesises silence: an
underrun leaves the engine to render its own silence for that period, the
final packet at end of stream is the exact remaining frame count, and the
reported position is exactly the source frames the engine has consumed
(submitted minus queued). Pause calls `IAudioClient::Stop`, which freezes the
queued audio and the position; resume calls `Start` again from the same
frames without re-decoding. A paused engine is never held to the
no-render-event deadline, and a paused producer stays bounded by the ring.
Failures on the render thread are fixed-size records formatted by the worker
after the join, so the real-time path allocates nothing and cannot throw.

Every playback delivers exactly one terminal completion after a successful
start (finished, cancelled or failed, with the heard duration). The
completion runs outside native locks and never after a successful destroy.
Destroy refuses to join from its own completion callback and keeps the job
owned by the caller on any failure. A missing codec, an empty decode, no
active render endpoint, a disabled or invalidated device, and an engine
that stops requesting audio are explicit errors; nothing falls back silently.

## Controls and ownership

`WindowsAudioPlaybackController` (Swift, `SpeakWindowsPlatform`) admits at most
two jobs in total, including pending file opens, active playback, background
releases and failed releases. Each job has a serial worker. File open, start,
commands and joins stay off the host actor; a completion arriving inside
`start` is handled only after `start` returns. At capacity, a new request is
rejected with a retry message while the current playback stays unchanged.

`playToCompletion` admits another source, such as a Read aloud segment, as an
ordinary run for its History record and resumes its caller once the output is
quiet and the native job released, with the rendered seconds or the failure;
Stop, a replacement, recording, close or cancelling the caller end it with
`CancellationError`. Such a run presents no terminal status of its own.

Read aloud begins a speech for the selected record at its click
(`beginSpeech`). The current playback stops at once, and until the speech
ends the record's display stays active, preparing or paused, while a segment
is synthesised and between segments, so Pause and Stop stay available however
long synthesis takes. Segments play through `playToCompletion(_:path:)`; one
that arrives while the speech is paused starts paused and is never heard
before Play. Stop, another row, a hidden or deleted row, recording, import, a
History playback, another Read aloud and closing end the speech, and a
segment of an ended speech is refused before its file is opened, so nothing
queued behind a Stop can play.

Pause and resume are commands acknowledged through a 100 ms sampler that
presents only changes. A pause requested before a job starts is applied
before its native start, so the engine never renders it. Stop requests
cancellation and resets the display only after output acknowledges silence. Only the user's Stop reports "Playback
stopped."; stopping to make way for another row, a hidden or deleted row,
recording or import leaves the status line to that work, while a finished or
failed playback always reports. Replacement playback and microphone capture
wait for that acknowledgement, with a three-second deadline that reports an
error instead of pretending output stopped. Decoder flush and resource release
can continue in the background. Cancelling a suspended file open forbids its
future start, allowing silence to be acknowledged without waiting for that open.

Display delivery retains only one pending update beside the callback in flight,
so a slow presenter coalesces progress instead of accumulating a queue.
All display callbacks are ordered on one delivery queue and carry increasing
revisions, including replacements for the same History row. Status callbacks
carry the same revision through the host actor, which rejects stale delivery.
`close` prevents new admission, waits for admitted opens, starts, release attempts
and display callbacks, and reports any failed release while retaining its job.
Calling `close` again retries those bounded failures. The one-shot playback
helper separately bounds itself to two operations and retains failed releases
for retry on its next invocation.

The app stops playback before recording or importing, when another record is
selected, when a search hides the selected record and on shutdown. It only
plays the URL resolved by `DesktopRecordingStore.audioURL(for:)`.

The native window keeps the controls record-bound: a playback report applies
only while its record is still the selected row, selecting another row resets
the display until the host reports again (row changes that coalesce back to
the playing or speaking record present its state again), and a History refresh that
re-selects the same record (after Retry, for example) keeps that record's last
report because the sampler never re-sends an unchanged paused state. Stop is
enabled only while a playback or Read aloud speech is active, and Play/Pause
is enabled for a selected idle record or while either is active so it can
always be paused. Playback reports never
touch the status or transcript text. Controls use explicit identifiers 160 to
162 and events 18 and 19, outside the existing control enumeration.

## Event order and request ownership

The window hands row selection, version, Play/Pause, Stop and Read aloud to
the host through one ordered History lane: `DesktopHistoryEvent` events
performed one at a time by a `DesktopEventDispatcher` (both `SpeakDesktop`).
A click on a newly selected row therefore reaches the host after that
selection instead of being refused for the previous row, and Stop can never
be overtaken by the Play or Read aloud clicked before it. The lane stays
bounded and never waits for audio: row and version changes coalesce to the
latest, a new row drops clicks still aimed at the row it replaces, Stop drops
the clicks before it, and at most eight Play/Pause or Read aloud clicks wait
while the host catches up; further clicks are ignored until it does.

History Play and Read aloud share one request owner,
`DesktopPlaybackRequests`. Play takes a ticket before it resolves the audio
file and starts only if the ticket is still current afterwards. Stop, another
row, a hidden or deleted row, recording, import and closing end every
request, so a start suspended across any of them never plays even though its
row may still be selected. A Read aloud ended by any of them reports nothing
when its task finally unwinds, so it cannot overwrite the status of whatever
ended it. The user's Stop, clickable while a segment is synthesised, cancels
that synthesis and every segment still to come, and itself reports that
reading stopped. `playToCompletion` claims its run under the controller
lock, so a segment whose task was cancelled just before admission replaces
nothing and opens no file. Each Read aloud still creates its own
shared-engine request, so a cancelled one may finish unwinding while the next
is synthesised; only the controller decides what is audible, and it refuses
every segment of an ended speech.

## Verification

`jsti_audio_playback_self_test` runs without a speaker on short low-amplitude
synthetic WAV files in a unique temporary directory. It checks the fixed
queue, input pinning and limits, exact and converted Media Foundation decode,
the decoded-sample bound, the reported duration, prompt cancellation of a
stalled read, and the production render loop against a synthetic engine:
exact output bytes with no trailing silence, source position across
pause/resume, cancel while paused, pause and cancel during the final drain
(1,000 heard frames of 2,400 queued report 1,000), pause requested before
start, the event timeout, a device failure at start, immediate completion,
refused second start, callback self-destroy refusal and release of the
pinned source. A 100 ms source in a 500 ms synthetic buffer must submit and
consume exactly 2,400 frames, with no padded tail and only the explicitly
modelled 0 or 25 ms device latency. A gated Media Foundation read verifies
that render failure wakes the decoder and preserves its original error;
failed Stop must keep output unacknowledged until endpoint release.
The window smoke test covers the record-bound controls,
recording lockout, stale reports and minimum-size bounds. Swift tests cover
the bridge (refused inputs, codec errors with or without an endpoint,
pre-start cancellation) and the controller's ownership rules against an
injected engine, including suspended open/close, completion before start returns,
cancellation before output acknowledgement, bounded rapid replacement, delayed
same-record presentation, reentrant callbacks and retained release failures,
an awaited caller cancelled before admission, and stops that make way for
other work reporting nothing while the user's Stop does. Speech tests keep
the record active before and between segments, replace playback at the click,
end speech on Stop, another row, capture, other playback or a newer speech
and refuse its queued segments, start a segment of paused speech paused
before any sound, apply a pause requested during a slow open before start,
keep speech shown while reporting a failed segment release, and present a
re-selected speaking or paused row again. Portable `SpeakDesktop`
tests drive the History lane and request owner under reversed and held
schedules: Stop after a pending or running Play, Play after Stop, clicks on a
newly selected row, supersession by a new row or Stop, bounded bursts, Stop
during a suspended start and a Read aloud ended by other work.
Hardware playback tests probe the endpoint explicitly and
skip only the audible checks when Windows reports no endpoint; a probe
failure or a playback failure with an endpoint present is a test failure.

Windows runtime execution of these checks, physical speaker, Bluetooth and
USB output, device disconnection during playback and audible quality remain
acceptance gates until they run on Windows hardware.
