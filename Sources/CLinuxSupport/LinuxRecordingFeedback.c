#include "LinuxSupportInternal.h"

#include <glib/gstdio.h>
#include <math.h>
#include <pulse/pulseaudio.h>
#include <sys/stat.h>

enum { FEEDBACK_RATE = 48000, FEEDBACK_MAX_SAMPLES = 480000 };

typedef struct {
    GArray *samples;
    gboolean oversized;
} FeedbackPCM;

struct jsti_recording_feedback {
    volatile gint cancelled;
    FeedbackPCM cues[2];
    pa_threaded_mainloop *loop;
    gboolean loop_started;
    pa_context *connection;
    pa_stream *stream;
    pa_operation *flush;
    pa_operation *drain;
    gint current;
    gint pending;
    size_t cursor;
    float gain;
    gint64 requested_at;
    gint64 first_write_at;
    gboolean closing;
    char failure[512];
    jsti_recording_feedback_failure_fn report;
    void *context;
};

static void feedback_collect(const int16_t *samples, size_t count, void *context) {
    FeedbackPCM *pcm = context;
    if (pcm->oversized) return;
    if (count > FEEDBACK_MAX_SAMPLES - pcm->samples->len) {
        pcm->oversized = TRUE;
        return;
    }
    g_array_append_vals(pcm->samples, samples, (guint)count);
}

static int32_t feedback_decode(
    const char *path, FeedbackPCM *pcm, const volatile gint *cancelled, char *error, size_t capacity) {
    GStatBuf info;
    if (path == NULL || g_lstat(path, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || info.st_size > 1048576) {
        jsti_set_error(error, capacity, "Recording sound must be a regular asset smaller than 1 MiB.");
        return -1;
    }
    int32_t result = jsti_audio_decode_bounded(
        path, FEEDBACK_RATE, feedback_collect, pcm, cancelled, error, capacity);
    if (result != 0) return result;
    if (pcm->oversized || pcm->samples->len == 0) {
        jsti_set_error(error, capacity, "Recording sound must contain between one sample and ten seconds of PCM.");
        return -1;
    }
    return 0;
}

static void feedback_cancel_operation(pa_operation **operation) {
    if (*operation == NULL) return;
    pa_operation_cancel(*operation);
    pa_operation_unref(*operation);
    *operation = NULL;
}

static void feedback_fail(jsti_recording_feedback *feedback, const char *message) {
    if (feedback->closing || feedback->failure[0] != '\0') return;
    g_strlcpy(feedback->failure, message, sizeof(feedback->failure));
    feedback->current = -1;
    if (feedback->report != NULL) feedback->report(feedback->failure, feedback->context);
}

static void feedback_context_state(pa_context *connection, void *context) {
    jsti_recording_feedback *feedback = context;
    pa_context_state_t state = pa_context_get_state(connection);
    if (!PA_CONTEXT_IS_GOOD(state)) feedback_fail(feedback, "Recording sound server connection failed.");
}

static void feedback_stream_state(pa_stream *stream, void *context) {
    jsti_recording_feedback *feedback = context;
    if (!PA_STREAM_IS_GOOD(pa_stream_get_state(stream))) {
        feedback_fail(feedback, "Recording sound output stream failed.");
    }
}

static void feedback_drained(pa_stream *stream, int success, void *context) {
    jsti_recording_feedback *feedback = context;
    if (!success) {
        feedback_fail(feedback, "Recording sound drain failed.");
        return;
    }
    pa_operation *cork = pa_stream_cork(stream, 1, NULL, NULL);
    if (cork != NULL) pa_operation_unref(cork);
    else feedback_fail(feedback, "Recording sound could not return to standby.");
}

static void feedback_write(pa_stream *stream, size_t requested, void *context) {
    jsti_recording_feedback *feedback = context;
    if (feedback->current < 0 || feedback->closing || feedback->failure[0] != '\0') return;
    FeedbackPCM *pcm = &feedback->cues[feedback->current];
    size_t remaining = pcm->samples->len - feedback->cursor;
    size_t count = MIN(requested / sizeof(int16_t), remaining);
    if (count == 0) return;
    void *destination = NULL;
    size_t bytes = count * sizeof(int16_t);
    if (pa_stream_begin_write(stream, &destination, &bytes) != 0 || destination == NULL) {
        feedback_fail(feedback, "Recording sound output buffer is unavailable.");
        return;
    }
    count = MIN(bytes / sizeof(int16_t), count);
    int16_t *output = destination;
    const int16_t *input = &g_array_index(pcm->samples, int16_t, feedback->cursor);
    for (size_t index = 0; index < count; index++) output[index] = (int16_t)lrintf(input[index] * feedback->gain);
    if (pa_stream_write(stream, destination, count * sizeof(int16_t), NULL, 0, PA_SEEK_RELATIVE) != 0) {
        pa_stream_cancel_write(stream);
        feedback_fail(feedback, "Recording sound samples could not be queued.");
        return;
    }
    feedback->cursor += count;
    if (count > 0 && feedback->first_write_at == 0) feedback->first_write_at = g_get_monotonic_time();
    if (feedback->cursor == pcm->samples->len) {
        feedback->current = -1;
        feedback_cancel_operation(&feedback->drain);
        feedback->drain = pa_stream_drain(stream, feedback_drained, feedback);
        if (feedback->drain == NULL) feedback_fail(feedback, "Recording sound drain could not be scheduled.");
    }
}

static void feedback_flushed(pa_stream *stream, int success, void *context) {
    jsti_recording_feedback *feedback = context;
    if (!success) {
        feedback_fail(feedback, "Recording sound queue could not be reset.");
        return;
    }
    if (feedback->pending < 0 || feedback->closing) return;
    feedback->current = feedback->pending;
    feedback->pending = -1;
    size_t writable = pa_stream_writable_size(stream);
    if (writable == (size_t)-1) {
        feedback_fail(feedback, "Recording sound output is unavailable.");
        return;
    }
    feedback_write(stream, writable, feedback);
    if (feedback->failure[0] != '\0') return;
    pa_operation *cork = pa_stream_cork(stream, 0, NULL, NULL);
    if (cork != NULL) pa_operation_unref(cork);
    else feedback_fail(feedback, "Recording sound could not start.");
}

jsti_recording_feedback *jsti_recording_feedback_create(
    jsti_recording_feedback_failure_fn failure, void *context) {
    jsti_recording_feedback *feedback = g_new0(jsti_recording_feedback, 1);
    feedback->current = -1;
    feedback->pending = -1;
    feedback->report = failure;
    feedback->context = context;
    for (int index = 0; index < 2; index++) {
        feedback->cues[index].samples = g_array_new(FALSE, FALSE, sizeof(int16_t));
    }
    return feedback;
}

void jsti_recording_feedback_cancel_preparation(jsti_recording_feedback *feedback) {
    if (feedback != NULL) g_atomic_int_set(&feedback->cancelled, 1);
}

static int32_t feedback_wait_ready(jsti_recording_feedback *feedback, gboolean output, char *error, size_t capacity) {
    gint64 deadline = g_get_monotonic_time() + 3 * G_USEC_PER_SEC;
    while (g_get_monotonic_time() < deadline) {
        if (g_atomic_int_get(&feedback->cancelled)) return 1;
        pa_threaded_mainloop_lock(feedback->loop);
        gboolean ready = output ? pa_stream_get_state(feedback->stream) == PA_STREAM_READY :
                                  pa_context_get_state(feedback->connection) == PA_CONTEXT_READY;
        gboolean failed = feedback->failure[0] != '\0';
        if (failed) jsti_set_error(error, capacity, "%s", feedback->failure);
        pa_threaded_mainloop_unlock(feedback->loop);
        if (failed) return -1;
        if (ready) return 0;
        g_usleep(5000);
    }
    jsti_set_error(error, capacity, "Recording sound server readiness exceeded three seconds.");
    return -1;
}

int32_t jsti_recording_feedback_prepare(
    jsti_recording_feedback *feedback, const char *start, const char *stop, char *error, size_t capacity) {
    if (feedback == NULL || feedback->loop != NULL) {
        jsti_set_error(error, capacity, "Invalid recording sound preparation.");
        return -1;
    }
    if (g_atomic_int_get(&feedback->cancelled)) return 1;
    const char *paths[] = {start, stop};
    for (int index = 0; index < 2; index++) {
        int32_t result = feedback_decode(paths[index], &feedback->cues[index], &feedback->cancelled, error, capacity);
        if (result != 0) return result;
    }
    if (g_atomic_int_get(&feedback->cancelled)) return 1;
    feedback->loop = pa_threaded_mainloop_new();
    if (feedback->loop == NULL || pa_threaded_mainloop_start(feedback->loop) != 0) {
        jsti_set_error(error, capacity, "Recording sound worker could not start.");
        return -1;
    }
    feedback->loop_started = TRUE;
    pa_threaded_mainloop_lock(feedback->loop);
    feedback->connection = pa_context_new(pa_threaded_mainloop_get_api(feedback->loop), "JustSpeakToIt recording feedback");
    if (feedback->connection != NULL) pa_context_set_state_callback(
        feedback->connection, feedback_context_state, feedback);
    int result = feedback->connection == NULL ? -1 : pa_context_connect(feedback->connection, NULL, PA_CONTEXT_NOFLAGS, NULL);
    pa_threaded_mainloop_unlock(feedback->loop);
    if (result != 0) {
        jsti_set_error(error, capacity, "Recording sound server connection could not be started.");
        return -1;
    }
    result = feedback_wait_ready(feedback, FALSE, error, capacity);
    if (result != 0) return result;
    pa_threaded_mainloop_lock(feedback->loop);
    pa_sample_spec format = {PA_SAMPLE_S16LE, FEEDBACK_RATE, 1};
    feedback->stream = pa_stream_new(feedback->connection, "Recording feedback", &format, NULL);
    if (feedback->stream != NULL) {
        pa_stream_set_state_callback(feedback->stream, feedback_stream_state, feedback);
        pa_stream_set_write_callback(feedback->stream, feedback_write, feedback);
        pa_buffer_attr buffer = {
            .maxlength = FEEDBACK_RATE * 2 / 5, .tlength = FEEDBACK_RATE * 2 / 20,
            .prebuf = 0, .minreq = FEEDBACK_RATE * 2 / 100, .fragsize = (uint32_t)-1
        };
        result = pa_stream_connect_playback(
            feedback->stream, NULL, &buffer, PA_STREAM_START_CORKED | PA_STREAM_ADJUST_LATENCY, NULL, NULL);
    } else result = -1;
    pa_threaded_mainloop_unlock(feedback->loop);
    if (result != 0) {
        jsti_set_error(error, capacity, "Recording sound output could not be opened.");
        return -1;
    }
    return feedback_wait_ready(feedback, TRUE, error, capacity);
}

int32_t jsti_recording_feedback_play(
    jsti_recording_feedback *feedback, int32_t sound, float gain, char *error, size_t capacity) {
    if (feedback == NULL || feedback->stream == NULL || sound < 0 || sound > 1 || !isfinite(gain) || gain < 0 || gain > 1) {
        jsti_set_error(error, capacity, "Invalid recording sound request.");
        return -1;
    }
    pa_threaded_mainloop_lock(feedback->loop);
    if (feedback->closing || feedback->failure[0] != '\0') {
        jsti_set_error(error, capacity, "%s", feedback->failure[0] != '\0' ? feedback->failure : "Recording sound is closing.");
        pa_threaded_mainloop_unlock(feedback->loop);
        return -1;
    }
    feedback_cancel_operation(&feedback->flush);
    feedback_cancel_operation(&feedback->drain);
    feedback->current = -1;
    feedback->pending = sound;
    feedback->cursor = 0;
    feedback->gain = gain;
    feedback->requested_at = g_get_monotonic_time();
    feedback->first_write_at = 0;
    feedback->flush = pa_stream_flush(feedback->stream, feedback_flushed, feedback);
    if (feedback->flush == NULL) feedback_fail(feedback, "Recording sound reset could not be scheduled.");
    int result = feedback->failure[0] == '\0' ? 0 : -1;
    if (result != 0) jsti_set_error(error, capacity, "%s", feedback->failure);
    pa_threaded_mainloop_unlock(feedback->loop);
    return result;
}

void jsti_recording_feedback_stop(jsti_recording_feedback *feedback) {
    if (feedback == NULL || feedback->loop == NULL || feedback->stream == NULL) return;
    pa_threaded_mainloop_lock(feedback->loop);
    feedback->current = -1;
    feedback->pending = -1;
    feedback_cancel_operation(&feedback->flush);
    feedback_cancel_operation(&feedback->drain);
    pa_operation *cork = pa_stream_cork(feedback->stream, 1, NULL, NULL);
    pa_operation *flush = pa_stream_flush(feedback->stream, NULL, NULL);
    if (cork != NULL) pa_operation_unref(cork);
    if (flush != NULL) pa_operation_unref(flush);
    if ((cork == NULL || flush == NULL) && !feedback->closing) feedback_fail(feedback, "Recording sound stop failed.");
    pa_threaded_mainloop_unlock(feedback->loop);
}

void jsti_recording_feedback_destroy(jsti_recording_feedback *feedback) {
    if (feedback == NULL) return;
    if (feedback->loop != NULL && feedback->loop_started) {
        pa_threaded_mainloop_lock(feedback->loop);
        feedback->closing = TRUE;
        feedback->current = -1;
        feedback_cancel_operation(&feedback->flush);
        feedback_cancel_operation(&feedback->drain);
        if (feedback->stream != NULL) {
            pa_stream_set_state_callback(feedback->stream, NULL, NULL);
            pa_stream_set_write_callback(feedback->stream, NULL, NULL);
            pa_stream_disconnect(feedback->stream);
            pa_stream_unref(feedback->stream);
        }
        if (feedback->connection != NULL) {
            pa_context_set_state_callback(feedback->connection, NULL, NULL);
            pa_context_disconnect(feedback->connection);
            pa_context_unref(feedback->connection);
        }
        pa_threaded_mainloop_unlock(feedback->loop);
        pa_threaded_mainloop_stop(feedback->loop);
    }
    if (feedback->loop != NULL) pa_threaded_mainloop_free(feedback->loop);
    for (int index = 0; index < 2; index++) g_array_unref(feedback->cues[index].samples);
    g_free(feedback);
}

int32_t jsti_recording_feedback_check_asset(const char *path, char *error, size_t capacity) {
    FeedbackPCM pcm = {.samples = g_array_new(FALSE, FALSE, sizeof(int16_t))};
    int32_t result = feedback_decode(path, &pcm, NULL, error, capacity);
    g_array_unref(pcm.samples);
    return result;
}

double jsti_recording_feedback_queued_latency(jsti_recording_feedback *feedback) {
    if (feedback == NULL || feedback->stream == NULL) return -1;
    pa_threaded_mainloop_lock(feedback->loop);
    double elapsed = feedback->failure[0] != '\0' ? -1 : feedback->first_write_at == 0 ? 0 :
        MAX((double)(feedback->first_write_at - feedback->requested_at) / G_USEC_PER_SEC, 0.000001);
    pa_threaded_mainloop_unlock(feedback->loop);
    return elapsed;
}
