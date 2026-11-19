#include "LinuxSupportInternal.h"
#include "LinuxPulse.h"

/* A one-shot list of microphones (sources that are not monitors of a sink),
 * each marked when it is the server's default. */

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
    if (jsti_pulse_open(&pulse, "JustSpeakToIt devices", error, capacity) != 0) return -1;
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
    jsti_pulse_close(&pulse);
    g_free(query.default_source);
    return 0;
}
