#ifndef JSTI_LINUX_AUDIO_PLAYBACK_H
#define JSTI_LINUX_AUDIO_PLAYBACK_H
/* GStreamer decoding and playback. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "LinuxAudioCapture.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Decodes any audio GStreamer's installed plugins understand to mono PCM16
 * at `sample_rate`, delivered in chunks on the calling thread. Stops early
 * (returning 1) once `*cancelled` becomes nonzero. */
int32_t jsti_audio_decode(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context, const volatile int32_t *cancelled,
    char *error, size_t error_capacity);

/* ---------------------------------------------------------------- playback */

int32_t jsti_audio_decode_bounded(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context,
    const volatile int32_t *cancelled, char *error, size_t error_capacity);

typedef struct jsti_recording_feedback jsti_recording_feedback;
typedef void (*jsti_recording_feedback_failure_fn)(const char *message, void *context);
jsti_recording_feedback *jsti_recording_feedback_create(
    jsti_recording_feedback_failure_fn failure, void *context);
/* Preparation runs on a worker; cancellation may be requested concurrently. */
int32_t jsti_recording_feedback_prepare(
    jsti_recording_feedback *feedback, const char *start, const char *stop, char *error, size_t capacity);
void jsti_recording_feedback_cancel_preparation(jsti_recording_feedback *feedback);
int32_t jsti_recording_feedback_play(
    jsti_recording_feedback *feedback, int32_t sound, float gain, char *error, size_t capacity);
void jsti_recording_feedback_stop(jsti_recording_feedback *feedback);
/* Call only after preparation returns. No callback runs after destroy returns. */
void jsti_recording_feedback_destroy(jsti_recording_feedback *feedback);
/* Device-free check: decodes and bounds the asset using the production decoder. */
int32_t jsti_recording_feedback_check_asset(const char *path, char *error, size_t capacity);
/* Self-test measurement: seconds from play to first queued native samples, 0 while pending, -1 on failure. */
double jsti_recording_feedback_queued_latency(jsti_recording_feedback *feedback);

/* Plays mono PCM16 through the sound server. The samples are copied. */
typedef struct jsti_player jsti_player;
enum { JSTI_PLAYER_PLAYING = 0, JSTI_PLAYER_PAUSED = 1, JSTI_PLAYER_FINISHED = 2, JSTI_PLAYER_FAILED = 3 };
jsti_player *jsti_player_create(
    const int16_t *samples, size_t count, uint32_t sample_rate, char *error, size_t error_capacity);
int32_t jsti_player_set_paused(jsti_player *player, int32_t paused);
/* Seconds heard so far, and one of JSTI_PLAYER_*. */
double jsti_player_position(jsti_player *player);
int32_t jsti_player_state(jsti_player *player);
/* Stops output and releases the stream; safe from any thread. */
void jsti_player_destroy(jsti_player *player);

/* Record-bound playback controls; state 0 stopped, 1 playing, 2 paused. The
 * window ignores reports for a record that is no longer selected. */
int32_t jsti_window_set_playback(const char *record_id, int32_t state, const char *text);

#ifdef __cplusplus
}
#endif
#endif
