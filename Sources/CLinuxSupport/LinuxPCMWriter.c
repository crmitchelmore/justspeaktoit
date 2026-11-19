#include "LinuxPCMWriter.h"
#include <string.h>

/* ----------------------------------------------------------------- ring */

gboolean jsti_pcm_ring_init(JSTIPCMRing *ring, size_t slot_samples, size_t slot_count) {
    memset(ring, 0, sizeof *ring);
    if (slot_samples == 0 || slot_count == 0) return FALSE;
    ring->samples = g_try_new0(int16_t, slot_samples * slot_count);
    ring->counts = g_try_new0(size_t, slot_count);
    if (ring->samples == NULL || ring->counts == NULL) {
        jsti_pcm_ring_clear(ring);
        return FALSE;
    }
    ring->slot_samples = slot_samples;
    ring->slot_count = slot_count;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->consumed, 0);
    return TRUE;
}

void jsti_pcm_ring_clear(JSTIPCMRing *ring) {
    g_free(ring->samples);
    g_free(ring->counts);
    ring->samples = NULL;
    ring->counts = NULL;
}

gboolean jsti_pcm_ring_push(JSTIPCMRing *ring, const int16_t *samples, size_t count) {
    if (count == 0 || count > ring->slot_samples) return FALSE;
    const size_t write = atomic_load_explicit(&ring->written, memory_order_relaxed);
    if (write - atomic_load_explicit(&ring->consumed, memory_order_acquire) >= ring->slot_count) return FALSE;
    const size_t slot = write % ring->slot_count;
    int16_t *target = ring->samples + slot * ring->slot_samples;
    if (samples != NULL) memcpy(target, samples, count * sizeof(int16_t));
    else memset(target, 0, count * sizeof(int16_t));
    ring->counts[slot] = count;
    atomic_store_explicit(&ring->written, write + 1, memory_order_release);
    return TRUE;
}

const int16_t *jsti_pcm_ring_front(JSTIPCMRing *ring, size_t *count) {
    const size_t read = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->written, memory_order_acquire)) return NULL;
    const size_t slot = read % ring->slot_count;
    *count = ring->counts[slot];
    return ring->samples + slot * ring->slot_samples;
}

void jsti_pcm_ring_pop(JSTIPCMRing *ring) {
    const size_t read = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    atomic_store_explicit(&ring->consumed, read + 1, memory_order_release);
}

/* --------------------------------------------------------------- writer */

struct JSTIPCMWriter {
    JSTIPCMRing ring;
    GMutex lock;
    GCond wake;
    GThread *thread;
    /* Guarded by lock. */
    gboolean signalled;
    gboolean closed;
    gchar *pending_failure;
    /* Set once by the producer; read without the lock on the append path. */
    atomic_bool failed;
    jsti_capture_audio_fn audio;
    jsti_capture_error_fn failure;
    void *context;
};

static void writer_signal_locked(JSTIPCMWriter *writer) {
    writer->signalled = TRUE;
    g_cond_signal(&writer->wake);
}

static void writer_fail(JSTIPCMWriter *writer, const char *message) {
    g_mutex_lock(&writer->lock);
    if (!atomic_exchange_explicit(&writer->failed, true, memory_order_relaxed)) {
        writer->pending_failure = g_strdup(message);
    }
    writer_signal_locked(writer);
    g_mutex_unlock(&writer->lock);
}

static gpointer writer_run(gpointer data) {
    JSTIPCMWriter *writer = data;
    for (;;) {
        size_t count = 0;
        const int16_t *frame = jsti_pcm_ring_front(&writer->ring, &count);
        if (frame != NULL) {
            writer->audio(frame, count, writer->context);
            jsti_pcm_ring_pop(&writer->ring);
            continue;
        }
        g_mutex_lock(&writer->lock);
        gchar *failure = writer->pending_failure;
        writer->pending_failure = NULL;
        const gboolean closed = writer->closed;
        /* A bounded wait also permits shutdown if a wake-up is ever missed. */
        if (failure == NULL && !closed && !writer->signalled) {
            g_cond_wait_until(&writer->wake, &writer->lock, g_get_monotonic_time() + 100 * G_TIME_SPAN_MILLISECOND);
        }
        writer->signalled = FALSE;
        g_mutex_unlock(&writer->lock);
        if (failure != NULL) {
            writer->failure(failure, writer->context);
            g_free(failure);
            continue;
        }
        /* Re-read the ring after observing close: the producer's final push
         * always precedes close, but can race the empty check above. */
        if (closed && jsti_pcm_ring_front(&writer->ring, &count) == NULL) return NULL;
    }
}

JSTIPCMWriter *jsti_pcm_writer_new(
    size_t frame_samples, uint32_t frame_ms, jsti_capture_audio_fn audio, jsti_capture_error_fn failure,
    void *context) {
    if (frame_ms == 0 || audio == NULL || failure == NULL) return NULL;
    JSTIPCMWriter *writer = g_try_new0(JSTIPCMWriter, 1);
    if (writer == NULL) return NULL;
    if (!jsti_pcm_ring_init(&writer->ring, frame_samples, JSTI_PCM_BUFFERED_MS / frame_ms)) {
        g_free(writer);
        return NULL;
    }
    g_mutex_init(&writer->lock);
    g_cond_init(&writer->wake);
    atomic_init(&writer->failed, false);
    writer->audio = audio;
    writer->failure = failure;
    writer->context = context;
    writer->thread = g_thread_try_new("jsti-capture-writer", writer_run, writer, NULL);
    if (writer->thread == NULL) {
        g_cond_clear(&writer->wake);
        g_mutex_clear(&writer->lock);
        jsti_pcm_ring_clear(&writer->ring);
        g_free(writer);
        return NULL;
    }
    return writer;
}

gboolean jsti_pcm_writer_append(JSTIPCMWriter *writer, const int16_t *samples, size_t count) {
    if (atomic_load_explicit(&writer->failed, memory_order_relaxed)) return FALSE;
    if (!jsti_pcm_ring_push(&writer->ring, samples, count)) {
        writer_fail(writer, JSTI_PCM_OVERFLOW_MESSAGE);
        return FALSE;
    }
    g_mutex_lock(&writer->lock);
    writer_signal_locked(writer);
    g_mutex_unlock(&writer->lock);
    return TRUE;
}

void jsti_pcm_writer_report(JSTIPCMWriter *writer, const char *message) { writer_fail(writer, message); }

gboolean jsti_pcm_writer_is_current(const JSTIPCMWriter *writer) {
    return writer != NULL && writer->thread == g_thread_self();
}

void jsti_pcm_writer_finish(JSTIPCMWriter *writer) {
    g_mutex_lock(&writer->lock);
    writer->closed = TRUE;
    writer_signal_locked(writer);
    g_mutex_unlock(&writer->lock);
    if (writer->thread != NULL) {
        g_thread_join(writer->thread);
        writer->thread = NULL;
    }
}

void jsti_pcm_writer_free(JSTIPCMWriter *writer) {
    if (writer == NULL) return;
    jsti_pcm_writer_finish(writer);
    g_free(writer->pending_failure);
    g_cond_clear(&writer->wake);
    g_mutex_clear(&writer->lock);
    jsti_pcm_ring_clear(&writer->ring);
    g_free(writer);
}
