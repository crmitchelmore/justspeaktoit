#include "LinuxSupportInternal.h"
#include "include/VoiceAudioCodec.h"
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>

#define VOICE_PCM_LIMIT (64u * 1024u * 1024u)
#define VOICE_CONTAINER_LIMIT (VOICE_PCM_LIMIT + 4096u)

static void initialise_voice_codecs(void) {
    static gsize ready;
    if (g_once_init_enter(&ready)) { gst_init(NULL, NULL); g_once_init_leave(&ready, 1); }
}
static gboolean compressed_format(const char *format) {
    return format != NULL && (strcmp(format, "mp3") == 0 || strcmp(format, "m4a") == 0);
}
static const char *encoder_for(const char *format) {
    if (strcmp(format, "mp3") == 0) return "lamemp3enc";
    /* Only existing plugins are considered. No install, subprocess or remote codec fallback. */
    const char *candidates[] = {"fdkaacenc", "voaacenc", "avenc_aac"};
    for (guint i = 0; i < G_N_ELEMENTS(candidates); ++i) {
        GstElementFactory *factory = gst_element_factory_find(candidates[i]);
        if (factory != NULL) { gst_object_unref(factory); return candidates[i]; }
    }
    return NULL;
}
static gboolean decoder_available(const char *format) {
    GstCaps *caps = gst_caps_from_string(strcmp(format, "mp3") == 0
        ? "audio/mpeg,mpegversion=(int)1,layer=(int)3"
        : "audio/mpeg,mpegversion=(int)4,stream-format=(string)raw");
    GList *all = gst_element_factory_list_get_elements(
        GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO, GST_RANK_MARGINAL);
    GList *matches = gst_element_factory_list_filter(all, caps, GST_PAD_SINK, FALSE);
    gboolean available = FALSE;
    for (GList *item = matches; item != NULL && !available; item = item->next) {
        GstElement *decoder = gst_element_factory_create(GST_ELEMENT_FACTORY(item->data), NULL);
        if (decoder != NULL) { available = TRUE; gst_object_unref(decoder); }
    }
    gst_plugin_feature_list_free(matches); gst_plugin_feature_list_free(all); gst_caps_unref(caps);
    return available;
}
static gchar *encoder_pipeline(const char *format, guint rate) {
    const char *encoder = encoder_for(format);
    if (encoder == NULL) return NULL;
    if (strcmp(format, "mp3") == 0) return g_strdup_printf(
        "appsrc name=input format=time ! audioconvert ! lamemp3enc name=encoder target=bitrate bitrate=128 cbr=true ! "
        "mpegaudioparse ! "
        "audio/mpeg,mpegversion=1,layer=3,rate=%u,channels=1 ! appsink name=output sync=false max-buffers=4", rate);
    return g_strdup_printf(
        "appsrc name=input format=time ! audioconvert ! %s name=encoder ! "
        "audio/mpeg,mpegversion=4,rate=%u,channels=1 ! aacparse ! "
        "mp4mux fragment-duration=1000 streamable=true ! appsink name=output sync=false max-buffers=4",
        encoder, rate);
}
static gboolean require_factory(const char *name, char *error, size_t capacity) {
    GstElement *element = gst_element_factory_make(name, NULL);
    gboolean available = element != NULL &&
        gst_element_set_state(element, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE;
    if (element != NULL) { gst_element_set_state(element, GST_STATE_NULL); gst_object_unref(element); }
    if (!available) jsti_set_error(error, capacity, "Installed GStreamer route needs %s. Choose WAV.", name);
    return available;
}
int32_t jsti_voice_codec_available(const char *format, uint32_t rate, char *error, size_t capacity) {
    initialise_voice_codecs();
    if (!compressed_format(format) || (rate != 16000 && rate != 24000 && rate != 48000)) {
        jsti_set_error(error, capacity, "Choose a known voice format and a supported source sample rate."); return -1;
    }
    if (!decoder_available(format)) {
        jsti_set_error(error, capacity, "No installed GStreamer decoder supports %s. Choose WAV.", format); return -1;
    }
    const char *required[] = {"appsrc", "appsink", "audioconvert", "decodebin", "typefind",
        strcmp(format, "mp3") == 0 ? "mpegaudioparse" : "qtdemux"};
    for (guint index = 0; index < G_N_ELEMENTS(required); ++index)
        if (!require_factory(required[index], error, capacity)) return -1;
    gchar *description = encoder_pipeline(format, rate);
    if (description == NULL) {
        jsti_set_error(error, capacity, "No installed GStreamer AAC encoder is available. Choose WAV."); return -1;
    }
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(description, &failure);
    g_free(description);
    gboolean valid = pipeline != NULL && failure == NULL;
    if (valid) {
        GstElement *encoder = gst_bin_get_by_name(GST_BIN(pipeline), "encoder");
        GstPad *sink = encoder != NULL ? gst_element_get_static_pad(encoder, "sink") : NULL;
        GstCaps *wanted = gst_caps_new_simple("audio/x-raw", "rate", G_TYPE_INT, (gint)rate,
            "channels", G_TYPE_INT, 1, NULL);
        GstCaps *accepted = sink != NULL ? gst_pad_query_caps(sink, wanted) : NULL;
        valid = accepted != NULL && !gst_caps_is_empty(accepted);
        if (accepted != NULL) gst_caps_unref(accepted);
        gst_caps_unref(wanted);
        if (sink != NULL) gst_object_unref(sink);
        if (encoder != NULL) gst_object_unref(encoder);
    }
    if (valid) valid = gst_element_set_state(pipeline, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE;
    if (!valid) jsti_set_error(error, capacity, "Installed %s encoder/container route is unavailable: %s",
        format, failure != NULL ? failure->message : "codec cannot preserve this mono source rate or enter READY");
    if (pipeline != NULL) { gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(pipeline); }
    g_clear_error(&failure);
    return valid ? 0 : -1;
}
typedef struct {
    const uint8_t *bytes;
    gsize count, offset;
    guint rate;
    gboolean raw, ended, failed;
} Input;
static void need_input(GstAppSrc *source, guint requested, gpointer data) {
    (void)requested;
    Input *input = data;
    if (input->ended) return;
    if (input->offset == input->count) {
        input->ended = TRUE; gst_app_src_end_of_stream(source); return;
    }
    gsize count = MIN((gsize)8192, input->count - input->offset);
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, count, NULL);
    if (buffer == NULL) { input->failed = input->ended = TRUE; gst_app_src_end_of_stream(source); return; }
    gst_buffer_fill(buffer, 0, input->bytes + input->offset, count);
    if (input->raw) {
        GST_BUFFER_PTS(buffer) = gst_util_uint64_scale(input->offset / 2, GST_SECOND, input->rate);
        GST_BUFFER_DURATION(buffer) = gst_util_uint64_scale(count / 2, GST_SECOND, input->rate);
    }
    input->offset += count;
    if (gst_app_src_push_buffer(source, buffer) != GST_FLOW_OK) input->failed = input->ended = TRUE;
}
typedef struct {
    const JSTIVoiceCodecRequest *request;
    Input input;
    GByteArray *encoded;
    gboolean decoding;
    gsize received;
} Conversion;
static int32_t run_pipeline(Conversion *job, const char *description, char *error, size_t capacity) {
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(description, &failure);
    if (pipeline == NULL || failure != NULL) {
        jsti_set_error(error, capacity, "Voice codec pipeline is unavailable: %s",
            failure != NULL ? failure->message : "pipeline construction failed");
        g_clear_error(&failure); if (pipeline != NULL) gst_object_unref(pipeline); return -1;
    }
    GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "input");
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    GstBus *bus = gst_element_get_bus(pipeline);
    if (job->input.raw) {
        GstCaps *caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE",
            "layout", G_TYPE_STRING, "interleaved", "channels", G_TYPE_INT, 1,
            "rate", G_TYPE_INT, (gint)job->request->sample_rate, NULL);
        gst_app_src_set_caps(GST_APP_SRC(source), caps); gst_caps_unref(caps);
    }
    g_signal_connect(source, "need-data", G_CALLBACK(need_input), &job->input);
    int32_t status = gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE ? -1 : 0;
    gint64 deadline = g_get_monotonic_time() + 120 * G_USEC_PER_SEC;
    if (status != 0) jsti_set_error(error, capacity, "The native voice codec could not start.");
    while (status == 0) {
        if (job->request->cancelled(job->request->context)) { status = 1; break; }
        if (g_get_monotonic_time() >= deadline) {
            jsti_set_error(error, capacity, "Native voice conversion exceeded its 120-second budget."); status = -1; break;
        }
        GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
        if (message != NULL) {
            GError *details = NULL; gst_message_parse_error(message, &details, NULL);
            jsti_set_error(error, capacity, "Native voice conversion failed: %s",
                details != NULL ? details->message : "unknown GStreamer error");
            g_clear_error(&details); gst_message_unref(message); status = -1; break;
        }
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 100 * GST_MSECOND);
        if (sample == NULL) {
            if (gst_app_sink_is_eos(GST_APP_SINK(sink))) break;
            continue;
        }
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        GstMapInfo map;
        if (buffer == NULL || !gst_buffer_map(buffer, &map, GST_MAP_READ)) {
            jsti_set_error(error, capacity, "The voice codec returned unreadable audio."); status = -1;
        } else {
            gsize limit = job->decoding ? VOICE_PCM_LIMIT : VOICE_CONTAINER_LIMIT;
            if (map.size > limit - job->received || (job->decoding && map.size % 2 != 0)) {
                jsti_set_error(error, capacity, "Native voice conversion exceeded its audio bound."); status = -1;
            } else {
                job->received += map.size;
                if (job->decoding) {
                    if (job->request->output(1, map.data, map.size, job->request->context) != 0) {
                        jsti_set_error(error, capacity, "The decoded voice result was refused or exceeded its byte bound.");
                        status = -1;
                    }
                } else g_byte_array_append(job->encoded, map.data, (guint)map.size);
            }
            gst_buffer_unmap(buffer, &map);
        }
        gst_sample_unref(sample);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(source); gst_object_unref(sink); gst_object_unref(bus); gst_object_unref(pipeline);
    if (status == 0 && (job->input.failed || job->received == 0 || job->input.offset != job->input.count)) {
        jsti_set_error(error, capacity, "The native voice codec did not consume and return complete audio."); return -1;
    }
    return status;
}
int32_t jsti_voice_codec_encode(const JSTIVoiceCodecRequest *request, char *error, size_t capacity) {
    if (request == NULL || request->pcm == NULL || request->pcm_bytes == 0 ||
        request->pcm_bytes > VOICE_PCM_LIMIT || request->pcm_bytes % 2 != 0 ||
        request->output == NULL || request->cancelled == NULL) {
        jsti_set_error(error, capacity, "Invalid native voice conversion input."); return -1;
    }
    if (request->cancelled(request->context)) return 1;
    if (jsti_voice_codec_available(request->format, request->sample_rate, error, capacity) != 0) return -1;
    Conversion job = { .request = request, .input = {
        .bytes = request->pcm, .count = request->pcm_bytes, .rate = request->sample_rate, .raw = TRUE },
        .encoded = g_byte_array_new() };
    gchar *description = encoder_pipeline(request->format, request->sample_rate);
    int32_t status = run_pipeline(&job, description, error, capacity);
    g_free(description);
    if (status == 0) {
        job.input = (Input){ .bytes = job.encoded->data, .count = job.encoded->len };
        job.decoding = TRUE; job.received = 0;
        description = g_strdup_printf(
            "appsrc name=input format=bytes ! decodebin ! audioconvert ! "
            "audio/x-raw,format=S16LE,channels=1,rate=%u,layout=interleaved ! "
            "appsink name=output sync=false max-buffers=4", request->sample_rate);
        status = run_pipeline(&job, description, error, capacity); g_free(description);
        if (status == 0 && request->output(0, job.encoded->data, job.encoded->len, request->context) != 0) {
            jsti_set_error(error, capacity, "The encoded voice result exceeded its retained byte bound."); status = -1;
        }
    }
    g_byte_array_unref(job.encoded);
    return status;
}
