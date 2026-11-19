/* jsti_pcm_writer_self_test: the capture ring and writer that keep audio and
 * failure callbacks off the PulseAudio thread. No sound server is needed. */
#include "include/CLinuxSelfTest.h"
#include "../CLinuxSupport/LinuxSupportInternal.h"
#include "../CLinuxSupport/LinuxPCMWriter.h"
#include <string.h>

#define FRAME_SAMPLES 1600u
#define FRAME_MS 100u
#define SLOTS (JSTI_PCM_BUFFERED_MS / FRAME_MS)

typedef struct {
    GMutex lock;
    GCond changed;
    guint frames;
    gint16 first_sample[SLOTS + 4];
    size_t counts[SLOTS + 4];
    gboolean off_caller_thread;
    GThread *caller;
    guint failures;
    guint frames_before_failure;
    gchar *message;
    gboolean gate_closed; /* While TRUE, the audio callback blocks: a stalled consumer. */
} Observed;

static void observed_audio(const int16_t *samples, size_t count, void *context) {
    Observed *observed = context;
    g_mutex_lock(&observed->lock);
    while (observed->gate_closed) g_cond_wait(&observed->changed, &observed->lock);
    if (observed->frames < G_N_ELEMENTS(observed->counts)) {
        observed->first_sample[observed->frames] = samples[0];
        observed->counts[observed->frames] = count;
    }
    observed->frames++;
    observed->off_caller_thread = observed->off_caller_thread && g_thread_self() != observed->caller;
    g_mutex_unlock(&observed->lock);
}

static void observed_failure(const char *message, void *context) {
    Observed *observed = context;
    g_mutex_lock(&observed->lock);
    if (observed->failures++ == 0) {
        observed->message = g_strdup(message);
        observed->frames_before_failure = observed->frames;
    }
    g_mutex_unlock(&observed->lock);
}

static void observed_init(Observed *observed) {
    memset(observed, 0, sizeof *observed);
    g_mutex_init(&observed->lock);
    g_cond_init(&observed->changed);
    observed->off_caller_thread = TRUE;
    observed->caller = g_thread_self();
}

static void observed_clear(Observed *observed) {
    g_free(observed->message);
    g_cond_clear(&observed->changed);
    g_mutex_clear(&observed->lock);
}

static void frame_of(int16_t *frame, int16_t value) {
    for (size_t index = 0; index < FRAME_SAMPLES; ++index) frame[index] = value;
}

/* FIFO, bounded capacity without overwrite, silence for NULL and invalid counts. */
static const char *ring_contract(void) {
    JSTIPCMRing ring;
    if (!jsti_pcm_ring_init(&ring, 4, 3)) return "the ring could not allocate its fixed storage";
    const int16_t a[4] = { 1, 1, 1, 1 }, b[2] = { 2, 2 }, c[4] = { 3, 3, 3, 3 }, d[4] = { 4, 4, 4, 4 };
    const char *failure = NULL;
    size_t count = 0;
    const int16_t *front = NULL;
    if (jsti_pcm_ring_front(&ring, &count) != NULL) failure = "an empty ring returned a frame";
    else if (jsti_pcm_ring_push(&ring, a, 0) || jsti_pcm_ring_push(&ring, a, 5)) failure = "an invalid count was accepted";
    else if (!jsti_pcm_ring_push(&ring, a, 4) || !jsti_pcm_ring_push(&ring, b, 2) || !jsti_pcm_ring_push(&ring, c, 4))
        failure = "the ring refused frames within its capacity";
    else if (jsti_pcm_ring_push(&ring, d, 4)) failure = "a full ring accepted a frame";
    else if ((front = jsti_pcm_ring_front(&ring, &count)) == NULL || count != 4 || front[0] != 1)
        failure = "the oldest frame was not first";
    else {
        jsti_pcm_ring_pop(&ring);
        if (!jsti_pcm_ring_push(&ring, NULL, 3)) failure = "a popped slot was not reusable";
        else if ((front = jsti_pcm_ring_front(&ring, &count)) == NULL || count != 2 || front[0] != 2)
            failure = "frames were reordered or overwritten";
        else {
            jsti_pcm_ring_pop(&ring);
            jsti_pcm_ring_pop(&ring);
            front = jsti_pcm_ring_front(&ring, &count);
            if (front == NULL || count != 3 || front[0] != 0 || front[2] != 0) failure = "a hole was not silence";
        }
    }
    jsti_pcm_ring_clear(&ring);
    return failure;
}

/* Every accepted frame arrives in order on the writer thread before finish returns. */
static const char *writer_drains(void) {
    Observed observed;
    observed_init(&observed);
    JSTIPCMWriter *writer = jsti_pcm_writer_new(FRAME_SAMPLES, FRAME_MS, observed_audio, observed_failure, &observed);
    const char *failure = writer == NULL ? "the writer could not start" : NULL;
    int16_t frame[FRAME_SAMPLES];
    for (int16_t value = 1; failure == NULL && value <= 10; ++value) {
        frame_of(frame, value);
        if (!jsti_pcm_writer_append(writer, frame, value == 10 ? 7 : FRAME_SAMPLES)) failure = "a frame was refused";
    }
    if (writer != NULL && jsti_pcm_writer_is_current(writer)) failure = "the caller was taken for the writer thread";
    jsti_pcm_writer_free(writer);
    g_mutex_lock(&observed.lock);
    const guint frames = observed.frames;
    g_mutex_unlock(&observed.lock);
    if (failure == NULL && frames != 10) failure = "finish returned before every accepted frame arrived";
    for (guint index = 0; failure == NULL && index < 10; ++index) {
        if (observed.first_sample[index] != (int16_t)(index + 1)) failure = "frames arrived out of order";
        else if (observed.counts[index] != (index == 9 ? 7u : FRAME_SAMPLES)) failure = "a frame changed length";
    }
    if (failure == NULL && !observed.off_caller_thread) failure = "audio was delivered on the producer thread";
    if (failure == NULL && observed.failures != 0) failure = "a clean recording reported a failure";
    observed_clear(&observed);
    return failure;
}

/* A stalled consumer overflows the bounded ring: the producer never blocks,
 * further audio is refused and one overflow failure follows the accepted frames. */
static const char *writer_overflow(void) {
    Observed observed;
    observed_init(&observed);
    observed.gate_closed = TRUE;
    JSTIPCMWriter *writer = jsti_pcm_writer_new(FRAME_SAMPLES, FRAME_MS, observed_audio, observed_failure, &observed);
    if (writer == NULL) {
        observed_clear(&observed);
        return "the writer could not start";
    }
    const char *failure = NULL;
    int16_t frame[FRAME_SAMPLES];
    frame_of(frame, 5);
    guint accepted = 0;
    while (accepted <= SLOTS && jsti_pcm_writer_append(writer, frame, FRAME_SAMPLES)) accepted++;
    if (accepted != SLOTS) failure = "the ring did not hold exactly its bounded capacity";
    else if (jsti_pcm_writer_append(writer, frame, FRAME_SAMPLES)) failure = "audio was accepted after an overflow";
    jsti_pcm_writer_report(writer, "A later failure.");
    g_mutex_lock(&observed.lock);
    observed.gate_closed = FALSE;
    g_cond_broadcast(&observed.changed);
    g_mutex_unlock(&observed.lock);
    jsti_pcm_writer_free(writer);
    if (failure == NULL && observed.frames != SLOTS) failure = "accepted frames were lost after an overflow";
    if (failure == NULL && observed.failures != 1) failure = "the overflow was not reported exactly once";
    if (failure == NULL && g_strcmp0(observed.message, JSTI_PCM_OVERFLOW_MESSAGE) != 0)
        failure = "the first failure was not the overflow";
    if (failure == NULL && observed.frames_before_failure != SLOTS)
        failure = "the failure overtook audio accepted before it";
    observed_clear(&observed);
    return failure;
}

/* A reported failure follows queued audio and is delivered even at close. */
static const char *writer_reports_after_audio(void) {
    Observed observed;
    observed_init(&observed);
    JSTIPCMWriter *writer = jsti_pcm_writer_new(FRAME_SAMPLES, 20, observed_audio, observed_failure, &observed);
    if (writer == NULL) {
        observed_clear(&observed);
        return "the writer could not start";
    }
    int16_t frame[FRAME_SAMPLES];
    frame_of(frame, 9);
    const gboolean queued = jsti_pcm_writer_append(writer, frame, 320) && jsti_pcm_writer_append(writer, frame, 320);
    jsti_pcm_writer_report(writer, "The microphone stopped.");
    jsti_pcm_writer_report(writer, "A second failure.");
    const gboolean refused = !jsti_pcm_writer_append(writer, frame, 320);
    jsti_pcm_writer_free(writer);
    const char *failure = NULL;
    if (!queued) failure = "frames were refused before the failure";
    else if (!refused) failure = "audio was accepted after a failure";
    else if (observed.frames != 2 || observed.frames_before_failure != 2) failure = "the failure overtook queued audio";
    else if (observed.failures != 1 || g_strcmp0(observed.message, "The microphone stopped.") != 0)
        failure = "the first failure was not delivered exactly once";
    observed_clear(&observed);
    return failure;
}

int32_t jsti_pcm_writer_self_test(char *error, size_t capacity) {
    const char *failure = ring_contract();
    if (failure == NULL) failure = writer_drains();
    if (failure == NULL) failure = writer_overflow();
    if (failure == NULL) failure = writer_reports_after_audio();
    if (failure == NULL) {
        if (error != NULL && capacity > 0) error[0] = '\0';
        return 0;
    }
    jsti_set_error(error, capacity, "Capture writer self-test: %s.", failure);
    return -1;
}
