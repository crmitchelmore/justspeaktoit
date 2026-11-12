#include "LinuxSupportInternal.h"
#include "LinuxPCMWriter.h"
#include "LinuxPulse.h"

#include <math.h>
#include <string.h>

/*
 * Microphone capture through libpulse's threaded main loop (LinuxPulse.h).
 * Audio arrives on the pulse thread and is re-framed to exact frame_ms chunks
 * into a bounded ring (LinuxPCMWriter.c). A writer thread hands each frame, and
 * any failure, to Swift, which appends it to the WAV and any live session, so
 * no callback runs on the pulse thread or under its main-loop lock. Source
 * volume is never changed. Playback, device listing and the device monitor
 * live in LinuxPlayback.c, LinuxAudioDevices.c and LinuxAudioDeviceMonitor.c.
 */

struct jsti_capture {
    JSTIPulse pulse;
    pa_stream *stream;
    char *device;
    uint32_t rate;
    uint32_t frame_ms;
    size_t frame_samples;
    int16_t *frame;
    size_t filled;
    /* Created by start, finished and freed by stop; guarded by the loop lock. */
    JSTIPCMWriter *writer;
    jsti_capture_audio_fn audio;
    jsti_capture_error_fn failure;
    void *context;
    gboolean running;
    gboolean failed;
};

/* Pulse thread, loop lock held. The writer thread reports it. */
static void capture_fail(jsti_capture *capture, const char *message) {
    if (capture->failed || !capture->running) return;
    capture->failed = TRUE;
    jsti_pcm_writer_report(capture->writer, message);
}

static void capture_emit(jsti_capture *capture, const uint8_t *bytes, size_t length) {
    const int16_t *samples = (const int16_t *)bytes;
    size_t count = length / sizeof(int16_t);
    while (count > 0 && capture->running) {
        size_t take = MIN(count, capture->frame_samples - capture->filled);
        if (samples != NULL) {
            memcpy(capture->frame + capture->filled, samples, take * sizeof(int16_t));
            samples += take;
        } else {
            /* A hole in the stream is silence, keeping the timeline intact. */
            memset(capture->frame + capture->filled, 0, take * sizeof(int16_t));
        }
        capture->filled += take;
        count -= take;
        if (capture->filled == capture->frame_samples) {
            jsti_capture_publish_level(capture->frame, capture->filled);
            /* A full ring is reported by the writer; audio is never dropped silently. */
            if (!jsti_pcm_writer_append(capture->writer, capture->frame, capture->filled)) capture->failed = TRUE;
            capture->filled = 0;
        }
    }
}

static gint latest_level; /* thousandths */

void jsti_capture_publish_level(const int16_t *samples, size_t count) {
    if (samples == NULL || count == 0) return;
    double sum = 0;
    for (size_t index = 0; index < count; ++index) sum += (double)samples[index] * samples[index];
    const double rms = sqrt(sum / (double)count) / 32768.0;
    const double decibels = rms > 0 ? 20.0 * log10(rms) : -100.0;
    g_atomic_int_set(&latest_level, (gint)(CLAMP((decibels + 50.0) / 50.0, 0.0, 1.0) * 1000.0));
}

double jsti_capture_level(void) { return g_atomic_int_get(&latest_level) / 1000.0; }

static void stream_read(pa_stream *stream, size_t available, void *userdata) {
    (void)available;
    jsti_capture *capture = userdata;
    const void *data = NULL;
    size_t length = 0;
    while (pa_stream_readable_size(stream) > 0) {
        if (pa_stream_peek(stream, &data, &length) < 0) {
            capture_fail(capture, "Reading from the microphone failed.");
            return;
        }
        if (length == 0) break;
        capture_emit(capture, data, length);
        pa_stream_drop(stream);
    }
}

static void stream_state(pa_stream *stream, void *userdata) {
    jsti_capture *capture = userdata;
    pa_stream_state_t state = pa_stream_get_state(stream);
    if (state == PA_STREAM_FAILED) {
        capture_fail(capture, "The microphone stopped delivering audio. It may have been disconnected.");
    }
    pa_threaded_mainloop_signal(capture->pulse.loop, 0);
}

static void stream_moved_or_suspended(pa_stream *stream, void *userdata) {
    (void)stream;
    (void)userdata;
    /* A moved or suspended source keeps recording; PipeWire resumes it. */
}

jsti_capture *jsti_capture_create(
    const char *device, uint32_t sample_rate, uint32_t frame_ms, jsti_capture_audio_fn audio,
    jsti_capture_error_fn failure, void *context, char *error, size_t capacity) {
    if (sample_rate != 16000 && sample_rate != 24000) {
        jsti_set_error(error, capacity, "This transcription model requires an unsupported recording rate.");
        return NULL;
    }
    if (frame_ms != 20 && frame_ms != 100) {
        jsti_set_error(error, capacity, "This transcription model requires an unsupported audio frame duration.");
        return NULL;
    }
    jsti_capture *capture = g_new0(jsti_capture, 1);
    capture->device = (device != NULL && device[0] != '\0') ? g_strdup(device) : NULL;
    capture->rate = sample_rate;
    capture->frame_ms = frame_ms;
    capture->frame_samples = sample_rate * frame_ms / 1000;
    capture->frame = g_new0(int16_t, capture->frame_samples);
    capture->audio = audio;
    capture->failure = failure;
    capture->context = context;
    if (jsti_pulse_open(&capture->pulse, "JustSpeakToIt recording", error, capacity) != 0) {
        g_free(capture->frame);
        g_free(capture->device);
        g_free(capture);
        return NULL;
    }
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    return capture;
}

/* Finishes a writer that start created when the stream did not open. */
static int32_t capture_start_failed(JSTIPCMWriter *writer) {
    jsti_pcm_writer_free(writer);
    return -1;
}

int32_t jsti_capture_start(jsti_capture *capture, char *error, size_t capacity) {
    pa_threaded_mainloop_lock(capture->pulse.loop);
    if (capture->writer != NULL) {
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "The microphone is already started. Stop it before restarting.");
        return -1;
    }
    capture->writer = jsti_pcm_writer_new(
        capture->frame_samples, capture->frame_ms, capture->audio, capture->failure, capture->context);
    if (capture->writer == NULL) {
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Could not start the recording writer.");
        return -1;
    }
    capture->failed = FALSE;
    capture->filled = 0;
    pa_sample_spec spec = { .format = PA_SAMPLE_S16LE, .rate = capture->rate, .channels = 1 };
    capture->stream = pa_stream_new(capture->pulse.context, "Dictation", &spec, NULL);
    if (capture->stream == NULL) {
        JSTIPCMWriter *writer = capture->writer;
        capture->writer = NULL;
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Could not create the recording stream.");
        return capture_start_failed(writer);
    }
    pa_stream_set_read_callback(capture->stream, stream_read, capture);
    pa_stream_set_state_callback(capture->stream, stream_state, capture);
    pa_stream_set_moved_callback(capture->stream, stream_moved_or_suspended, capture);
    pa_stream_set_suspended_callback(capture->stream, stream_moved_or_suspended, capture);
    uint32_t frame_bytes = (uint32_t)(capture->frame_samples * sizeof(int16_t));
    pa_buffer_attr attributes = {
        .maxlength = (uint32_t)-1, .tlength = (uint32_t)-1, .prebuf = (uint32_t)-1,
        .minreq = (uint32_t)-1, .fragsize = frame_bytes
    };
    capture->running = TRUE;
    if (pa_stream_connect_record(capture->stream, capture->device, &attributes, PA_STREAM_ADJUST_LATENCY) < 0) {
        capture->running = FALSE;
        int code = pa_context_errno(capture->pulse.context);
        JSTIPCMWriter *writer = capture->writer;
        capture->writer = NULL;
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Could not open the microphone: %s", pa_strerror(code));
        return capture_start_failed(writer);
    }
    for (;;) {
        pa_stream_state_t state = pa_stream_get_state(capture->stream);
        if (state == PA_STREAM_READY) break;
        if (!PA_STREAM_IS_GOOD(state)) {
            capture->running = FALSE;
            int code = pa_context_errno(capture->pulse.context);
            JSTIPCMWriter *writer = capture->writer;
            capture->writer = NULL;
            pa_threaded_mainloop_unlock(capture->pulse.loop);
            jsti_set_error(
                error, capacity, "Could not open the microphone%s%s: %s", capture->device ? " " : "",
                capture->device ? capture->device : "", pa_strerror(code));
            return capture_start_failed(writer);
        }
        pa_threaded_mainloop_wait(capture->pulse.loop);
    }
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    return 0;
}

int32_t jsti_capture_stop(jsti_capture *capture, char *error, size_t capacity) {
    pa_threaded_mainloop_lock(capture->pulse.loop);
    if (jsti_pcm_writer_is_current(capture->writer)) {
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Microphone stop must run outside its audio callback.");
        return -1;
    }
    if (capture->stream != NULL) {
        /* Queue what the server already captured, then the partial frame. */
        if (capture->running) stream_read(capture->stream, 0, capture);
        if (capture->running && capture->filled > 0) {
            if (!jsti_pcm_writer_append(capture->writer, capture->frame, capture->filled)) capture->failed = TRUE;
            capture->filled = 0;
        }
        capture->running = FALSE;
        pa_stream_set_read_callback(capture->stream, NULL, NULL);
        pa_stream_set_state_callback(capture->stream, NULL, NULL);
        pa_stream_set_moved_callback(capture->stream, NULL, NULL);
        pa_stream_set_suspended_callback(capture->stream, NULL, NULL);
        pa_stream_disconnect(capture->stream);
        pa_stream_unref(capture->stream);
        capture->stream = NULL;
    }
    capture->running = FALSE;
    JSTIPCMWriter *writer = capture->writer;
    capture->writer = NULL;
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    /* Outside the loop lock: deliver every queued frame and any failure, then join. */
    jsti_pcm_writer_free(writer);
    return 0;
}

void jsti_capture_destroy(jsti_capture *capture) {
    if (capture == NULL) return;
    /* Refuse a self-join/use-after-free from inside a capture callback. */
    if (jsti_pcm_writer_is_current(capture->writer)) return;
    jsti_capture_stop(capture, NULL, 0);
    jsti_pulse_close(&capture->pulse);
    g_free(capture->frame);
    g_free(capture->device);
    g_free(capture);
}
