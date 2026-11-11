/* Private to LinuxCapture.c and its self-test: the bounded single-producer,
 * single-consumer PCM frame ring and the writer thread that delivers its
 * frames, so foreign audio and failure callbacks never run on the PulseAudio
 * thread or under its main-loop lock. Mirrors Windows PCMFrameRing and
 * BufferedAudioWriter (WindowsAudioCaptureInternal.hpp). Never exported. */
#ifndef JSTI_LINUX_PCM_WRITER_H
#define JSTI_LINUX_PCM_WRITER_H
#include "include/LinuxAudioCapture.h"
#include <glib.h>
#include <stdatomic.h>
#include <stdbool.h>

/* Retained audio, as on Windows: 128 x 100 ms or 640 x 20 ms frames. */
#define JSTI_PCM_BUFFERED_MS 12800u

#define JSTI_PCM_OVERFLOW_MESSAGE \
    "The recording writer could not keep up. Recording stopped to avoid silently losing audio."

#pragma GCC visibility push(hidden)

/* One producer and one consumer. A borrowed slot stays owned by the consumer
 * until it pops it. Push never allocates, locks or blocks; all storage is
 * allocated once by init. */
typedef struct JSTIPCMRing {
    int16_t *samples;
    size_t *counts;
    size_t slot_samples;
    size_t slot_count;
    _Atomic size_t written;
    _Atomic size_t consumed;
} JSTIPCMRing;

gboolean jsti_pcm_ring_init(JSTIPCMRing *ring, size_t slot_samples, size_t slot_count);
void jsti_pcm_ring_clear(JSTIPCMRing *ring);
/* Copies `count` (1...slot_samples) samples, or silence when `samples` is
 * NULL. FALSE when full or the count is invalid; nothing is overwritten. */
gboolean jsti_pcm_ring_push(JSTIPCMRing *ring, const int16_t *samples, size_t count);
/* The oldest unconsumed frame, or NULL when empty. Consumer only. */
const int16_t *jsti_pcm_ring_front(JSTIPCMRing *ring, size_t *count);
void jsti_pcm_ring_pop(JSTIPCMRing *ring);

/* Delivers accepted frames in order, then at most one failure, on its own
 * thread. Overflow is a failure, never silent loss: once any failure is
 * recorded, append refuses further audio. */
typedef struct JSTIPCMWriter JSTIPCMWriter;

/* NULL when the ring or thread cannot be created. */
JSTIPCMWriter *jsti_pcm_writer_new(
    size_t frame_samples, uint32_t frame_ms, jsti_capture_audio_fn audio, jsti_capture_error_fn failure,
    void *context);
/* Producer only. Never blocks on a callback. */
gboolean jsti_pcm_writer_append(JSTIPCMWriter *writer, const int16_t *samples, size_t count);
/* Records the first failure; it is delivered after the frames accepted before it. */
void jsti_pcm_writer_report(JSTIPCMWriter *writer, const char *message);
/* TRUE on the writer's own thread, where finish must not be called. */
gboolean jsti_pcm_writer_is_current(const JSTIPCMWriter *writer);
/* Closes, delivers every accepted frame and any failure, and joins. No
 * callback runs after it returns. Call after the producer has stopped. */
void jsti_pcm_writer_finish(JSTIPCMWriter *writer);
/* Finishes if needed, then frees. */
void jsti_pcm_writer_free(JSTIPCMWriter *writer);

#pragma GCC visibility pop

#endif
