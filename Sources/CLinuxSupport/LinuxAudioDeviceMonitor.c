#include "LinuxSupportInternal.h"
#include "LinuxPulse.h"

#include <unistd.h>

/* The audio device monitor: one long-lived libpulse connection, owned by
 * `monitor` under `monitor_lock`, that reports source and server changes, and
 * answers whether this process is recording from a microphone right now. */

typedef struct Monitor {
    JSTIPulse pulse;
    jsti_audio_devices_changed_fn callback;
    void *context;
} Monitor;

static GMutex monitor_lock;
static Monitor *monitor;

static void subscription_event(pa_context *context, pa_subscription_event_type_t type, uint32_t index, void *data) {
    (void)context; (void)index;
    Monitor *state = data;
    pa_subscription_event_type_t facility = type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
    if (facility == PA_SUBSCRIPTION_EVENT_SOURCE || facility == PA_SUBSCRIPTION_EVENT_SERVER) {
        state->callback(state->context);
    }
}

int32_t jsti_audio_device_monitor_start(
    jsti_audio_devices_changed_fn callback, void *context, char *error, size_t capacity) {
    jsti_audio_device_monitor_stop();
    Monitor *state = g_new0(Monitor, 1);
    state->callback = callback;
    state->context = context;
    if (jsti_pulse_open(&state->pulse, "JustSpeakToIt device monitor", error, capacity) != 0) {
        g_free(state);
        return -1;
    }
    pa_context_set_subscribe_callback(state->pulse.context, subscription_event, state);
    pa_operation *operation = pa_context_subscribe(
        state->pulse.context, PA_SUBSCRIPTION_MASK_SOURCE | PA_SUBSCRIPTION_MASK_SERVER, NULL, NULL);
    if (operation != NULL) pa_operation_unref(operation);
    pa_threaded_mainloop_unlock(state->pulse.loop);
    g_mutex_lock(&monitor_lock);
    monitor = state;
    g_mutex_unlock(&monitor_lock);
    return 0;
}

void jsti_audio_device_monitor_stop(void) {
    g_mutex_lock(&monitor_lock);
    Monitor *state = monitor;
    monitor = NULL;
    g_mutex_unlock(&monitor_lock);
    if (state == NULL) return;
    pa_threaded_mainloop_lock(state->pulse.loop);
    pa_context_set_subscribe_callback(state->pulse.context, NULL, NULL);
    pa_threaded_mainloop_unlock(state->pulse.loop);
    jsti_pulse_close(&state->pulse);
    g_free(state);
}

/* --------------------------------------------- this process's capture */

typedef struct CaptureQuery {
    pa_threaded_mainloop *loop;
    /* Source indexes this process records from; monitors are dropped later. */
    GArray *sources;
    gboolean outputs_done;
    gboolean capturing;
    gboolean sources_done;
    /* The server answered a list with an error (eol < 0): the answer is unknown. */
    gboolean failed;
} CaptureQuery;

/* A server that accepts the query but never answers must not hold monitor_lock,
   and with it shutdown, for longer than this; a probe makes at most two
   queries, and the monitor polls every 2 s. */
#define JSTI_CAPTURE_QUERY_TIMEOUT_USEC ((pa_usec_t)500 * 1000)

/* Inside Flatpak the server sees a different pid, so the app id also counts. */
static gboolean own_stream(const pa_proplist *properties) {
    const char *pid = pa_proplist_gets(properties, PA_PROP_APPLICATION_PROCESS_ID);
    if (pid != NULL && g_ascii_strtoll(pid, NULL, 10) == (gint64)getpid()) return TRUE;
    return g_strcmp0(pa_proplist_gets(properties, PA_PROP_APPLICATION_ID), "com.justspeaktoit.JustSpeakToIt") == 0;
}

static void source_output_info(pa_context *context, const pa_source_output_info *info, int eol, void *userdata) {
    (void)context;
    CaptureQuery *query = userdata;
    if (eol != 0 || info == NULL) {
        if (eol < 0) query->failed = TRUE;
        query->outputs_done = TRUE;
        pa_threaded_mainloop_signal(query->loop, 0);
        return;
    }
    if (!info->corked && own_stream(info->proplist)) g_array_append_val(query->sources, info->source);
}

static void capture_source_info(pa_context *context, const pa_source_info *info, int eol, void *userdata) {
    (void)context;
    CaptureQuery *query = userdata;
    if (eol != 0 || info == NULL) {
        if (eol < 0) query->failed = TRUE;
        query->sources_done = TRUE;
        pa_threaded_mainloop_signal(query->loop, 0);
        return;
    }
    /* A sink's monitor is playback being recorded, not a microphone. */
    if (info->monitor_of_sink != PA_INVALID_INDEX) return;
    for (guint i = 0; i < query->sources->len; i++) {
        if (g_array_index(query->sources, uint32_t, i) == info->index) query->capturing = TRUE;
    }
}

typedef struct QueryDeadline {
    pa_threaded_mainloop *loop;
    gboolean expired;
} QueryDeadline;

static void query_deadline_expired(pa_mainloop_api *api, pa_time_event *event, const struct timeval *tv, void *data) {
    (void)api; (void)event; (void)tv;
    QueryDeadline *deadline = data;
    deadline->expired = TRUE;
    pa_threaded_mainloop_signal(deadline->loop, 0);
}

/* Waits with the loop locked until *done, the operation stops running, or
   `timeout` passes. Returns FALSE on timeout. The timer is freed before
   returning, so its stack state never outlives this call. */
static gboolean wait_bounded(
    pa_threaded_mainloop *loop, pa_operation *operation, const gboolean *done, pa_usec_t timeout) {
    pa_mainloop_api *api = pa_threaded_mainloop_get_api(loop);
    QueryDeadline deadline = { .loop = loop };
    struct timeval when;
    pa_timeval_add(pa_gettimeofday(&when), timeout);
    pa_time_event *timer = api->time_new(api, &when, query_deadline_expired, &deadline);
    if (timer == NULL) return FALSE;
    while (!*done && !deadline.expired &&
           (operation == NULL || pa_operation_get_state(operation) == PA_OPERATION_RUNNING)) {
        pa_threaded_mainloop_wait(loop);
    }
    api->time_free(timer);
    return !deadline.expired || *done;
}

/* Called with the loop locked. On timeout the operation is cancelled while
   still locked, so its callback can never touch the caller's stack query. */
static gboolean await_query(pa_threaded_mainloop *loop, pa_operation *operation, const gboolean *done) {
    if (operation == NULL) return FALSE;
    gboolean answered = wait_bounded(loop, operation, done, JSTI_CAPTURE_QUERY_TIMEOUT_USEC) && *done;
    if (!answered && pa_operation_get_state(operation) == PA_OPERATION_RUNNING) pa_operation_cancel(operation);
    pa_operation_unref(operation);
    return answered;
}

int32_t jsti_audio_process_capturing(void) {
    g_mutex_lock(&monitor_lock);
    Monitor *state = monitor;
    if (state == NULL) {
        g_mutex_unlock(&monitor_lock);
        return -1;
    }
    /* monitor_lock stays held, so a concurrent stop waits for this query. */
    pa_threaded_mainloop_lock(state->pulse.loop);
    CaptureQuery query = { .loop = state->pulse.loop, .sources = g_array_new(FALSE, FALSE, sizeof(uint32_t)) };
    int32_t result = -1;
    if (pa_context_get_state(state->pulse.context) == PA_CONTEXT_READY &&
        await_query(query.loop, pa_context_get_source_output_info_list(
            state->pulse.context, source_output_info, &query), &query.outputs_done) && !query.failed) {
        if (query.sources->len == 0) {
            result = 0;
        } else if (await_query(query.loop, pa_context_get_source_info_list(
            state->pulse.context, capture_source_info, &query), &query.sources_done) && !query.failed) {
            result = query.capturing ? 1 : 0;
        }
    }
    pa_threaded_mainloop_unlock(state->pulse.loop);
    g_mutex_unlock(&monitor_lock);
    g_array_free(query.sources, TRUE);
    return result;
}

/* The deadline and error handling without a sound server: a wait nothing
   answers ends at its deadline, and a list that reports an error is unknown. */
int32_t jsti_audio_capture_query_self_test(void) {
    pa_threaded_mainloop *loop = pa_threaded_mainloop_new();
    if (loop == NULL) return 1;
    if (pa_threaded_mainloop_start(loop) < 0) {
        pa_threaded_mainloop_free(loop);
        return 2;
    }
    int32_t failure = 0;
    pa_threaded_mainloop_lock(loop);
    gboolean never = FALSE;
    gint64 started = g_get_monotonic_time();
    if (wait_bounded(loop, NULL, &never, 50 * 1000)) failure = 3;
    else if (g_get_monotonic_time() - started > 5 * G_USEC_PER_SEC) failure = 4;
    CaptureQuery query = { .loop = loop, .sources = g_array_new(FALSE, FALSE, sizeof(uint32_t)) };
    source_output_info(NULL, NULL, -1, &query);
    if (failure == 0 && (!query.outputs_done || !query.failed)) failure = 5;
    query.failed = FALSE;
    capture_source_info(NULL, NULL, 1, &query);
    if (failure == 0 && (!query.sources_done || query.failed)) failure = 6;
    pa_threaded_mainloop_unlock(loop);
    g_array_free(query.sources, TRUE);
    pa_threaded_mainloop_stop(loop);
    pa_threaded_mainloop_free(loop);
    return failure;
}
