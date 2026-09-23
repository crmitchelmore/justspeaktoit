#include "LinuxSupportInternal.h"

#include <pulse/pulseaudio.h>
#include <string.h>

/*
 * Microphone capture through libpulse's threaded main loop. On current
 * desktops this reaches PipeWire through pipewire-pulse; in Flatpak it needs
 * --socket=pulseaudio. Audio arrives on the pulse thread, is re-framed to
 * exact frame_ms chunks and handed to Swift, which appends it to the WAV and
 * any live session. Source volume is never changed.
 */

typedef struct JSTIPulse {
    pa_threaded_mainloop *loop;
    pa_context *context;
} JSTIPulse;

static void context_state(pa_context *context, void *userdata) {
    (void)context;
    pa_threaded_mainloop_signal(userdata, 0);
}

static void pulse_close(JSTIPulse *pulse) {
    if (pulse->loop == NULL) return;
    pa_threaded_mainloop_lock(pulse->loop);
    if (pulse->context != NULL) {
        pa_context_set_state_callback(pulse->context, NULL, NULL);
        pa_context_disconnect(pulse->context);
        pa_context_unref(pulse->context);
        pulse->context = NULL;
    }
    pa_threaded_mainloop_unlock(pulse->loop);
    pa_threaded_mainloop_stop(pulse->loop);
    pa_threaded_mainloop_free(pulse->loop);
    pulse->loop = NULL;
}

/* Connects and waits for READY. Leaves the loop locked on success. */
static int32_t pulse_open(JSTIPulse *pulse, const char *name, char *error, size_t capacity) {
    pulse->loop = pa_threaded_mainloop_new();
    if (pulse->loop == NULL) {
        jsti_set_error(error, capacity, "Could not start the audio thread.");
        return -1;
    }
    pa_mainloop_api *api = pa_threaded_mainloop_get_api(pulse->loop);
    pa_proplist *properties = pa_proplist_new();
    pa_proplist_sets(properties, PA_PROP_APPLICATION_NAME, "JustSpeakToIt");
    pa_proplist_sets(properties, PA_PROP_APPLICATION_ID, "com.justspeaktoit.JustSpeakToIt");
    pa_proplist_sets(properties, PA_PROP_APPLICATION_ICON_NAME, "com.justspeaktoit.JustSpeakToIt");
    pulse->context = pa_context_new_with_proplist(api, name, properties);
    pa_proplist_free(properties);
    if (pulse->context == NULL) {
        jsti_set_error(error, capacity, "Could not create an audio context.");
        pulse_close(pulse);
        return -1;
    }
    pa_context_set_state_callback(pulse->context, context_state, pulse->loop);
    pa_threaded_mainloop_lock(pulse->loop);
    if (pa_threaded_mainloop_start(pulse->loop) < 0 ||
        pa_context_connect(pulse->context, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
        pa_threaded_mainloop_unlock(pulse->loop);
        jsti_set_error(
            error, capacity, "The sound server is unavailable (%s). Check that PipeWire or PulseAudio is running.",
            pa_strerror(pa_context_errno(pulse->context)));
        pulse_close(pulse);
        return -1;
    }
    for (;;) {
        pa_context_state_t state = pa_context_get_state(pulse->context);
        if (state == PA_CONTEXT_READY) return 0;
        if (!PA_CONTEXT_IS_GOOD(state)) {
            int code = pa_context_errno(pulse->context);
            pa_threaded_mainloop_unlock(pulse->loop);
            jsti_set_error(
                error, capacity, "The sound server is unavailable (%s). Check that PipeWire or PulseAudio is running.",
                pa_strerror(code));
            pulse_close(pulse);
            return -1;
        }
        pa_threaded_mainloop_wait(pulse->loop);
    }
}

/* --------------------------------------------------------------- capture */

struct jsti_capture {
    JSTIPulse pulse;
    pa_stream *stream;
    char *device;
    uint32_t rate;
    size_t frame_samples;
    int16_t *frame;
    size_t filled;
    jsti_capture_audio_fn audio;
    jsti_capture_error_fn failure;
    void *context;
    gboolean running;
    gboolean failed;
};

/* Pulse thread, loop lock held. */
static void capture_fail(jsti_capture *capture, const char *message) {
    if (capture->failed || !capture->running) return;
    capture->failed = TRUE;
    capture->failure(message, capture->context);
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
            capture->audio(capture->frame, capture->filled, capture->context);
            capture->filled = 0;
        }
    }
}

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
    capture->frame_samples = sample_rate * frame_ms / 1000;
    capture->frame = g_new0(int16_t, capture->frame_samples);
    capture->audio = audio;
    capture->failure = failure;
    capture->context = context;
    if (pulse_open(&capture->pulse, "JustSpeakToIt recording", error, capacity) != 0) {
        g_free(capture->frame);
        g_free(capture->device);
        g_free(capture);
        return NULL;
    }
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    return capture;
}

int32_t jsti_capture_start(jsti_capture *capture, char *error, size_t capacity) {
    pa_threaded_mainloop_lock(capture->pulse.loop);
    pa_sample_spec spec = { .format = PA_SAMPLE_S16LE, .rate = capture->rate, .channels = 1 };
    capture->stream = pa_stream_new(capture->pulse.context, "Dictation", &spec, NULL);
    if (capture->stream == NULL) {
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Could not create the recording stream.");
        return -1;
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
        pa_threaded_mainloop_unlock(capture->pulse.loop);
        jsti_set_error(error, capacity, "Could not open the microphone: %s", pa_strerror(code));
        return -1;
    }
    for (;;) {
        pa_stream_state_t state = pa_stream_get_state(capture->stream);
        if (state == PA_STREAM_READY) break;
        if (!PA_STREAM_IS_GOOD(state)) {
            capture->running = FALSE;
            int code = pa_context_errno(capture->pulse.context);
            pa_threaded_mainloop_unlock(capture->pulse.loop);
            jsti_set_error(
                error, capacity, "Could not open the microphone%s%s: %s", capture->device ? " " : "",
                capture->device ? capture->device : "", pa_strerror(code));
            return -1;
        }
        pa_threaded_mainloop_wait(capture->pulse.loop);
    }
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    return 0;
}

int32_t jsti_capture_stop(jsti_capture *capture, char *error, size_t capacity) {
    (void)error;
    (void)capacity;
    pa_threaded_mainloop_lock(capture->pulse.loop);
    if (capture->stream != NULL) {
        /* Deliver what the server already captured, then the partial frame. */
        if (capture->running) stream_read(capture->stream, 0, capture);
        if (capture->running && capture->filled > 0) {
            capture->audio(capture->frame, capture->filled, capture->context);
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
    pa_threaded_mainloop_unlock(capture->pulse.loop);
    return 0;
}

void jsti_capture_destroy(jsti_capture *capture) {
    if (capture == NULL) return;
    jsti_capture_stop(capture, NULL, 0);
    pulse_close(&capture->pulse);
    g_free(capture->frame);
    g_free(capture->device);
    g_free(capture);
}

/* --------------------------------------------------------------- devices */

typedef struct DeviceQuery {
    JSTIPulse *pulse;
    char *default_source;
    gboolean server_done;
    gboolean list_done;
    jsti_audio_device_fn callback;
    void *context;
} DeviceQuery;

static void server_info(pa_context *context, const pa_server_info *info, void *userdata) {
    (void)context;
    DeviceQuery *query = userdata;
    if (info != NULL && info->default_source_name != NULL) query->default_source = g_strdup(info->default_source_name);
    query->server_done = TRUE;
    pa_threaded_mainloop_signal(query->pulse->loop, 0);
}

static void source_info(pa_context *context, const pa_source_info *info, int end, void *userdata) {
    (void)context;
    DeviceQuery *query = userdata;
    if (end != 0 || info == NULL) {
        query->list_done = TRUE;
        pa_threaded_mainloop_signal(query->pulse->loop, 0);
        return;
    }
    /* Monitors of speakers are not microphones. */
    if (info->monitor_of_sink != PA_INVALID_INDEX) return;
    const char *name = info->description != NULL ? info->description : info->name;
    query->callback(info->name, name, g_strcmp0(info->name, query->default_source) == 0, query->context);
}

int32_t jsti_audio_devices_enumerate(jsti_audio_device_fn callback, void *context, char *error, size_t capacity) {
    JSTIPulse pulse = { 0 };
    if (pulse_open(&pulse, "JustSpeakToIt devices", error, capacity) != 0) return -1;
    DeviceQuery query = { .pulse = &pulse, .callback = callback, .context = context };
    pa_operation *operation = pa_context_get_server_info(pulse.context, server_info, &query);
    while (operation != NULL && !query.server_done &&
           pa_operation_get_state(operation) == PA_OPERATION_RUNNING) {
        pa_threaded_mainloop_wait(pulse.loop);
    }
    if (operation != NULL) pa_operation_unref(operation);
    operation = pa_context_get_source_info_list(pulse.context, source_info, &query);
    while (operation != NULL && !query.list_done &&
           pa_operation_get_state(operation) == PA_OPERATION_RUNNING) {
        pa_threaded_mainloop_wait(pulse.loop);
    }
    if (operation != NULL) pa_operation_unref(operation);
    pa_threaded_mainloop_unlock(pulse.loop);
    pulse_close(&pulse);
    g_free(query.default_source);
    return 0;
}
