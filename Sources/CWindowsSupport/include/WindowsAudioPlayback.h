#ifndef JSTI_WINDOWS_AUDIO_PLAYBACK_H
#define JSTI_WINDOWS_AUDIO_PLAYBACK_H
/* Audio conversion and History playback. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTIAudioConversion JSTIAudioConversion;
/* One completion on the dedicated conversion worker after start succeeds.
 * status: 0 success, 1 cancelled, -1 failure. Duration/sample_count describe the
 * actual canonical16kHz mono PCM16 output only on success. Error is borrowed
 * until callback returns. Retain context until destroy succeeds; never destroy
 * from this callback. The input is never changed. */
typedef void (*JSTIAudioConversionCallback)(int status, double duration_seconds,
                                           uint64_t sample_count, const char *error, void *context);
/* Absolute local regular-file input; maximum25,000,000 input/output bytes.
 * Output must not exist, and its parent must already have been prepared by
 * jsti_private_directory_prepare. Conversion uses installed Media Foundation
 * decoders; support for compressed formats depends on the Windows installation.
 * Partial outputs are removed by their owned handle on failure/cancellation. */
JSTIAudioConversion *jsti_audio_conversion_create(const char *input_path, const char *output_path,
                                                  JSTIAudioConversionCallback callback, void *context,
                                                  char *error, size_t error_capacity);
int jsti_audio_conversion_start(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Thread safe request. Pending sample reads are flushed on the worker;
 * cancellation is checked between setup stages and output writes. */
void jsti_audio_conversion_cancel(JSTIAudioConversion *conversion);
/* Serialize against caller operations. Cancels and joins; zero frees the job.
 * On failure retain the job/context and retry outside its callback thread. */
int jsti_audio_conversion_destroy(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Synthetic WAV decode/resample, bounds/collision/refusal/cancellation checks.
 * No microphone, credentials, provider requests, or user recordings. */
int jsti_audio_conversion_self_test(char *error, size_t error_capacity);

typedef struct JSTIAudioPlayback JSTIAudioPlayback;
/* Exactly one completion on the dedicated playback worker after start
 * succeeds. status: 0 finished (every decoded frame was consumed by the audio
 * engine), 1 cancelled, -1 failed. played_seconds is the source audio the
 * engine actually consumed when playback ended, on every status; it is 0 when
 * nothing was measured. error is borrowed until the callback returns and is
 * empty on success. Retain context until destroy succeeds; never destroy from
 * this callback. Never invoked under a native lock, never after destroy. */
typedef void (*JSTIAudioPlaybackCallback)(int status, double played_seconds, const char *error, void *context);
/* Absolute local regular-file input of 1 byte to 1 GiB (two hours of 24 kHz
 * PCM16 history is about 346 MB). Creation opens the file read-only with
 * write/delete sharing denied and refuses directories, non-disk files and a
 * leaf reparse point; that pinned handle is the only stream Windows decodes
 * from, so the source is never reopened by name or modified. Decoding uses the
 * installed in-process Media Foundation codecs and converts straight to the
 * default multimedia render endpoint's shared-mode mix format and rate; if the
 * decoder cannot produce that format it decodes float at the source rate and
 * the Windows audio engine converts. There is no forced transcription-rate
 * conversion, custom resampler, external player or transcription step; the
 * endpoint conversion may resample a high-rate source. Decoded audio is queued
 * through a fixed two-second ring (at most 64 MiB, typically under 1 MiB) into
 * an event-driven shared-mode WASAPI stream; each decoded sample is bounded to
 * four seconds of output (1 MiB to 64 MiB) before it is coalesced; file and
 * codec work never run on the render thread, which submits only real source
 * frames (never synthesised silence) so the reported position is the source
 * audio actually consumed. A missing Media Foundation (Windows N), a missing
 * codec, an empty decode, no active render endpoint, an invalidated device or an
 * engine that stops requesting audio all fail with a descriptive error; there
 * is no silent fallback, and a render failure wakes a decoder stalled on a
 * slow codec at once so the failure is reported promptly. Creation itself
 * does not touch any device. */
JSTIAudioPlayback *jsti_audio_playback_create(const char *input_path, JSTIAudioPlaybackCallback callback,
                                              void *context, char *error, size_t error_capacity);
/* Starts once. A cancelled or already started job is refused synchronously
 * without any callback. Zero guarantees exactly one later completion, which
 * may arrive before this call returns; serialize destroy after it returns. */
int jsti_audio_playback_start(JSTIAudioPlayback *playback, char *error, size_t error_capacity);
/* Thread safe, nonblocking commands handled by the render thread. Pause stops
 * the engine and freezes both the queued audio and the reported position;
 * resume starts it again from the same frames without re-decoding. A pause
 * requested before rendering begins holds the first frame; a long pause never
 * trips the no-render-event failure deadline and keeps the decoder bounded by
 * the fixed queue. Returns 0 requested, 1 ignored because playback already
 * ended, -1 no playback. Commands are idempotent. */
int jsti_audio_playback_pause(JSTIAudioPlayback *playback);
int jsti_audio_playback_resume(JSTIAudioPlayback *playback);
typedef struct JSTIAudioPlaybackSnapshot {
    int state;               /* 0 preparing, 1 playing, 2 paused, 3 ended (see the completion). */
    double position_seconds; /* Source audio actually consumed by the engine so far. */
    double duration_seconds; /* Container duration when the source reports one, otherwise -1. */
    /* Output acknowledgement: 0 the engine was never started, 1 it was started
     * (running or paused, so it may start again), 2 the render thread stopped
     * the stream (or ended without ever starting it) and it can never start
     * again. After cancel, 2 arrives as soon as the render thread has stopped
     * the WASAPI stream, well before the decoder teardown that destroy joins;
     * hosts wait for it before another audible playback or microphone capture
     * and treat a bounded wait that expires as a failure, not as silence.
     * After cancel has returned, 0 is also proof of quiet: each potential Start
     * reserves state 1 before checking cancellation, so a later reservation
     * cannot start an engine after the caller has observed 0. State 1 includes
     * an in-flight Start; never interpret it as quiet. A failed Stop retains 1
     * until the endpoint is released, rather than falsely acknowledging it. */
    int output_state;
} JSTIAudioPlaybackSnapshot;
/* Cheap cached read of atomics; safe from any thread at any rate, never
 * blocks. The position is stable while paused, monotonic while playing and
 * never advanced by queued or silent frames. Returns -1 for a null playback. */
int jsti_audio_playback_snapshot(const JSTIAudioPlayback *playback, JSTIAudioPlaybackSnapshot *snapshot);
/* Thread safe request; stops rendering promptly and unblocks decoding. */
void jsti_audio_playback_cancel(JSTIAudioPlayback *playback);
/* Serialize against caller operations, after start has returned. Cancels and
 * joins both native threads; zero frees the job and the pinned input handle.
 * Refuses to join itself from the completion callback and keeps the job and
 * context owned by the caller on any failure, so retry outside the callback
 * thread. Codec teardown may take a few seconds; hosts stop audibly through
 * cancel first and destroy off their UI/actor threads. */
int jsti_audio_playback_destroy(JSTIAudioPlayback *playback, char *error, size_t error_capacity);
/* Capability probe for callers and tests: 1 when Windows reports an active
 * default multimedia render endpoint, 0 when there is none, -1 when Windows
 * could not answer. Enumeration only; nothing is activated. A 1 does not
 * promise that a later playback succeeds, and playback failures must never be
 * reinterpreted as a missing endpoint. */
int jsti_audio_playback_endpoint_available(char *error, size_t error_capacity);
/* Deterministic checks on short low-amplitude synthetic WAV files in a unique
 * temporary directory, without any endpoint: fixed queue, input pinning and
 * limits, Media Foundation exact/converted decode, decoded-sample bound,
 * duration, cancellation of a stalled read, and the production render loop
 * driven by a synthetic engine: exact output bytes with no trailing silence,
 * source-position accounting through pause/resume/cancel/drain, pause before
 * start, event timeout, start failure, immediate completion, refused second
 * start, callback self-destroy refusal, and release of the pinned source.
 * Needs Media Foundation. Never uses recordings, credentials or a speaker. */
int jsti_audio_playback_self_test(char *error, size_t error_capacity);

/* Deterministic native checks: Unicode, 16/24 kHz frame boundaries, silence,
 * fixed queue capacity, writer drain, capture creation and sample-rate
 * validation, invalid insertion targets. Does not use microphone, clipboard or
 * real credentials. */
int jsti_native_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
