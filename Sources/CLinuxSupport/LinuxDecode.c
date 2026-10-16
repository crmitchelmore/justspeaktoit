#include "LinuxSupportInternal.h"

#include <gst/app/gstappsink.h>
#include <gst/gst.h>

/*
 * Import conversion for providers that accept only canonical 16 kHz PCM16
 * WAV: filesrc ! decodebin ! audioconvert ! audioresample ! appsink, pulled
 * synchronously. Formats are whatever the installed GStreamer plugins decode
 * (the GNOME runtime ships the common ones); the original file is untouched.
 */

static int32_t audio_decode(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context,
    const volatile int32_t *cancelled, gint64 deadline, char *error, size_t capacity) {
    static gsize initialised = 0;
    if (g_once_init_enter(&initialised)) {
        gst_init(NULL, NULL);
        g_once_init_leave(&initialised, 1);
    }
    gchar *location = g_strescape(path, NULL);
    gchar *description = g_strdup_printf(
        "filesrc location=\"%s\" ! decodebin ! audioconvert ! audioresample ! "
        "audio/x-raw,format=S16LE,channels=1,rate=%u,layout=interleaved ! appsink name=sink sync=false%s",
        location, sample_rate, deadline != 0 ? " max-buffers=4" : "");
    g_free(location);
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(description, &failure);
    g_free(description);
    if (pipeline == NULL || failure != NULL) {
        jsti_set_error(error, capacity, "Audio decoding is unavailable: %s",
                       failure != NULL ? failure->message : "GStreamer could not build a pipeline");
        g_clear_error(&failure);
        if (pipeline != NULL) gst_object_unref(pipeline);
        return -1;
    }
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    int32_t result = 0;
    uint64_t decoded_samples = 0;
    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        jsti_set_error(error, capacity, "This audio file could not be opened for decoding.");
        result = -1;
    }
    while (result == 0) {
        if (cancelled != NULL && g_atomic_int_get(cancelled) != 0) {
            result = 1;
            break;
        }
        if (deadline != 0 && g_get_monotonic_time() >= deadline) {
            jsti_set_error(error, capacity, "Recording sound decoding exceeded its preparation deadline.");
            result = -1;
            break;
        }
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 200 * GST_MSECOND);
        if (sample == NULL) {
            if (gst_app_sink_is_eos(GST_APP_SINK(sink))) break;
            GstBus *bus = gst_element_get_bus(pipeline);
            GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
            gst_object_unref(bus);
            if (message != NULL) {
                GError *decode = NULL;
                gst_message_parse_error(message, &decode, NULL);
                jsti_set_error(error, capacity, "This audio file could not be decoded: %s",
                               decode != NULL ? decode->message : "unknown error");
                g_clear_error(&decode);
                gst_message_unref(message);
                result = -1;
            }
            continue;
        }
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        GstMapInfo map;
        if (buffer != NULL && gst_buffer_map(buffer, &map, GST_MAP_READ)) {
            if (map.size % sizeof(int16_t) != 0) {
                jsti_set_error(error, capacity, "Decoded audio is not PCM16 sample aligned.");
                result = -1;
            } else if (deadline != 0 && map.size / 2 > (uint64_t)sample_rate * 10 - decoded_samples) {
                jsti_set_error(error, capacity, "Recording sound exceeds ten seconds of decoded audio.");
                result = -1;
            } else if (map.size >= 2) {
                chunk((const int16_t *)map.data, map.size / 2, context);
                decoded_samples += map.size / 2;
            }
            gst_buffer_unmap(buffer, &map);
        }
        gst_sample_unref(sample);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    return result;
}

int32_t jsti_audio_decode(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context,
    const volatile int32_t *cancelled, char *error, size_t capacity) {
    return audio_decode(path, sample_rate, chunk, context, cancelled, 0, error, capacity);
}

int32_t jsti_audio_decode_bounded(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context,
    const volatile int32_t *cancelled, char *error, size_t capacity) {
    return audio_decode(path, sample_rate, chunk, context, cancelled,
                        g_get_monotonic_time() + 5 * G_USEC_PER_SEC, error, capacity);
}
