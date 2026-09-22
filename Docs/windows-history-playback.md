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
active render endpoint, a disabled device, a device change, and an engine
that stops requesting audio are explicit errors; nothing falls back silently.

## Controls and ownership

`WindowsAudioPlaybackController` (Swift, `SpeakWindowsPlatform`) owns at most
one audible run. Play pins and starts a job synchronously and never blocks
the actor; pause and resume are native commands acknowledged through a
100 ms sampler that reads the cheap native snapshot and presents only
changes; Stop cancels audibly at once, resets the display to zero and moves
the codec join to a background release task, so starting a recording is not
blocked by decoder teardown. Runs carry a generation identity: a completion
for a replaced run never clears a newer one, one release task exists per run,
and `close` awaits every release. The app controller stops playback before
recording or importing, when another record is selected, when a search hides
the selected record and on shutdown, and it only ever plays the URL resolved
by `DesktopRecordingStore.audioURL(for:)`.

The native window keeps the controls record-bound: a playback report applies
only while its record is still the selected row, selecting another row resets
the display until the host reports again, Stop is enabled only while a
playback is active, and Play/Pause is enabled for a selected idle record or
while a playback is active so it can always be paused. Playback reports never
touch the status or transcript text. Controls use explicit identifiers 160 to
162 and events 18 and 19, outside the existing control enumeration.

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
pinned source. The window smoke test covers the record-bound controls,
recording lockout, stale reports and minimum-size bounds. Swift tests cover
the bridge (refused inputs, codec errors with or without an endpoint,
pre-start cancellation) and the controller's ownership rules against an
injected engine. Hardware playback tests probe the endpoint explicitly and
skip only the audible checks when Windows reports no endpoint; a probe
failure or a playback failure with an endpoint present is a test failure.

Windows runtime execution of these checks, physical speaker, Bluetooth and
USB output, device disconnection during playback and audible quality remain
acceptance gates until they run on Windows hardware.
