/* The portal thread and its requests, availability and the Background portal.
 * GlobalShortcuts and RemoteDesktop live in their own units (LinuxPortalInternal.h). */
#include "LinuxPortalInternal.h"

#include <unistd.h>



static GMutex portal_lock;
static Portal *portal;
static char portal_start_error[512];

static gpointer portal_thread(gpointer data) {
    Portal *state = data;
    g_main_context_push_thread_default(state->context);
    GError *failure = NULL;
    state->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &failure);
    if (state->bus != NULL) {
        const gchar *unique = g_dbus_connection_get_unique_name(state->bus);
        gchar *sender = g_strdup(unique + (unique[0] == ':' ? 1 : 0));
        for (gchar *cursor = sender; *cursor != '\0'; cursor++) {
            if (*cursor == '.') *cursor = '_';
        }
        state->sender = sender;
    } else {
        g_strlcpy(portal_start_error, failure != NULL ? failure->message : "no session bus",
                  sizeof portal_start_error);
        g_clear_error(&failure);
    }
    g_main_loop_run(state->loop);
    g_main_context_pop_thread_default(state->context);
    return NULL;
}

typedef struct Ready {
    GMutex lock;
    GCond changed;
    gboolean ready;
} Ready;

static gboolean mark_ready(gpointer data) {
    Ready *ready = data;
    g_mutex_lock(&ready->lock);
    ready->ready = TRUE;
    g_cond_signal(&ready->changed);
    g_mutex_unlock(&ready->lock);
    return G_SOURCE_REMOVE;
}

/* Starts the portal thread once and waits until its bus is connected. */
static Portal *portal_get(char *error, size_t capacity) {
    g_mutex_lock(&portal_lock);
    if (portal == NULL) {
        Portal *state = g_new0(Portal, 1);
        state->context = g_main_context_new();
        state->loop = g_main_loop_new(state->context, FALSE);
        Ready ready = { 0 };
        g_mutex_init(&ready.lock);
        g_cond_init(&ready.changed);
        state->thread = g_thread_new("jsti-portal", portal_thread, state);
        GSource *source = g_idle_source_new();
        g_source_set_callback(source, mark_ready, &ready, NULL);
        g_source_attach(source, state->context);
        g_source_unref(source);
        g_mutex_lock(&ready.lock);
        while (!ready.ready) g_cond_wait(&ready.changed, &ready.lock);
        g_mutex_unlock(&ready.lock);
        g_mutex_clear(&ready.lock);
        g_cond_clear(&ready.changed);
        portal = state;
    }
    Portal *state = portal;
    g_mutex_unlock(&portal_lock);
    if (state->bus == NULL) {
        jsti_set_error(error, capacity, "The desktop session bus is unavailable: %s", portal_start_error);
        return NULL;
    }
    return state;
}

gboolean portal_started(void) {
    g_mutex_lock(&portal_lock);
    gboolean started = portal != NULL;
    g_mutex_unlock(&portal_lock);
    return started;
}

/* ------------------------------------------------------ run on the thread */

typedef struct PortalCall {
    GMutex lock;
    GCond changed;
    gboolean done;
    PortalWork work;
    gpointer data;
    int32_t result;
    char error[512];
} PortalCall;

static gboolean portal_call_run(gpointer pointer) {
    PortalCall *call = pointer;
    call->result = call->work(portal, call->data, call->error, sizeof call->error);
    g_mutex_lock(&call->lock);
    call->done = TRUE;
    g_cond_signal(&call->changed);
    g_mutex_unlock(&call->lock);
    return G_SOURCE_REMOVE;
}

int32_t portal_run(PortalWork work, gpointer data, char *error, size_t capacity) {
    Portal *state = portal_get(error, capacity);
    if (state == NULL) return -1;
    PortalCall call = { .work = work, .data = data };
    g_mutex_init(&call.lock);
    g_cond_init(&call.changed);
    g_main_context_invoke(state->context, portal_call_run, &call);
    g_mutex_lock(&call.lock);
    while (!call.done) g_cond_wait(&call.changed, &call.lock);
    g_mutex_unlock(&call.lock);
    g_mutex_clear(&call.lock);
    g_cond_clear(&call.changed);
    if (call.result != 0) jsti_set_error(error, capacity, "%s", call.error);
    return call.result;
}

/* ------------------------------------------------------------ requests */

typedef struct Response {
    gboolean received;
    guint32 code;
    GVariant *results;
} Response;

static void response_received(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    Response *response = data;
    g_variant_get(parameters, "(u@a{sv})", &response->code, &response->results);
    response->received = TRUE;
}

static gboolean timeout_reached(gpointer data) {
    *(gboolean *)data = TRUE;
    return G_SOURCE_REMOVE;
}

static gchar *next_token(Portal *state) { return g_strdup_printf("jsti%u_%u", (guint)getpid(), ++state->token); }

/*
 * Calls a portal method whose last argument is an a{sv} options dictionary
 * that takes a handle_token, then waits for the Request's Response. The
 * caller supplies the leading arguments already built into `arguments`, a
 * tuple builder left open for the options. Returns the Response's results,
 * whatever its `code` (0 success, 1 declined, 2 other), or NULL when no
 * Response arrived.
 */
static GVariant *portal_request_response(
    Portal *state, const char *interface, const char *method, GVariantBuilder *arguments,
    GVariantBuilder *options, guint timeout_ms, guint32 *code, char *error, size_t capacity) {
    gchar *token = next_token(state);
    gchar *path = g_strdup_printf("%s/request/%s/%s", PORTAL_PATH, state->sender, token);
    g_variant_builder_add(options, "{sv}", "handle_token", g_variant_new_string(token));
    g_variant_builder_add_value(arguments, g_variant_builder_end(options));
    GVariant *parameters = g_variant_builder_end(arguments);
    Response response = { 0 };
    guint subscription = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, REQUEST_INTERFACE, "Response", path, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        response_received, &response, NULL);
    GError *failure = NULL;
    GVariant *handle = g_dbus_connection_call_sync(
        state->bus, PORTAL_BUS_NAME, PORTAL_PATH, interface, method, parameters, G_VARIANT_TYPE("(o)"),
        G_DBUS_CALL_FLAGS_NONE, CALL_TIMEOUT_MS, NULL, &failure);
    GVariant *results = NULL;
    if (handle == NULL) {
        jsti_set_error(error, capacity, "The desktop portal refused %s: %s", method,
                       failure != NULL ? failure->message : "unknown error");
        g_clear_error(&failure);
        goto done;
    }
    const gchar *returned = NULL;
    g_variant_get(handle, "(&o)", &returned);
    if (g_strcmp0(returned, path) != 0) {
        /* Portals older than 0.9 pick their own path; listen there too. */
        g_dbus_connection_signal_unsubscribe(state->bus, subscription);
        subscription = g_dbus_connection_signal_subscribe(
            state->bus, PORTAL_BUS_NAME, REQUEST_INTERFACE, "Response", returned, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
            response_received, &response, NULL);
    }
    g_variant_unref(handle);
    gboolean expired = FALSE;
    GSource *timer = g_timeout_source_new(timeout_ms);
    g_source_set_callback(timer, timeout_reached, &expired, NULL);
    g_source_attach(timer, state->context);
    while (!response.received && !expired) g_main_context_iteration(state->context, TRUE);
    g_source_destroy(timer);
    g_source_unref(timer);
    if (!response.received) {
        jsti_set_error(error, capacity, "The desktop did not answer %s in time.", method);
    } else {
        *code = response.code;
        results = response.results != NULL ? response.results : g_variant_ref_sink(g_variant_new("a{sv}", NULL));
        response.results = NULL;
    }
done:
    if (response.results != NULL) g_variant_unref(response.results);
    g_dbus_connection_signal_unsubscribe(state->bus, subscription);
    g_free(path);
    g_free(token);
    return results;
}

/* portal_request_response for requests that must succeed: returns the
 * results only when the Response's code is 0. */
GVariant *portal_request(
    Portal *state, const char *interface, const char *method, GVariantBuilder *arguments,
    GVariantBuilder *options, guint timeout_ms, char *error, size_t capacity) {
    guint32 code = 0;
    GVariant *results = portal_request_response(
        state, interface, method, arguments, options, timeout_ms, &code, error, capacity);
    if (results == NULL || code == 0) return results;
    g_variant_unref(results);
    if (code == 1) jsti_set_error(error, capacity, "Permission was declined in the desktop dialog.");
    else jsti_set_error(error, capacity, "The desktop portal could not complete %s.", method);
    return NULL;
}

GVariant *portal_call(
    Portal *state, const char *interface, const char *method, GVariant *parameters, char *error, size_t capacity) {
    GError *failure = NULL;
    GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
        state->bus, PORTAL_BUS_NAME, PORTAL_PATH, interface, method, parameters, NULL, G_DBUS_CALL_FLAGS_NONE,
        CALL_TIMEOUT_MS, NULL, NULL, NULL, &failure);
    if (reply == NULL) {
        jsti_set_error(error, capacity, "The desktop portal refused %s: %s", method,
                       failure != NULL ? failure->message : "unknown error");
        g_clear_error(&failure);
    }
    return reply;
}

gchar *portal_create_session(Portal *state, const char *interface, char *error, size_t capacity) {
    GVariantBuilder arguments, options;
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    gchar *session_token = next_token(state);
    g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(session_token));
    g_free(session_token);
    GVariant *results = portal_request(
        state, interface, "CreateSession", &arguments, &options, CALL_TIMEOUT_MS, error, capacity);
    if (results == NULL) return NULL;
    gchar *session = NULL;
    if (!g_variant_lookup(results, "session_handle", "s", &session) &&
        !g_variant_lookup(results, "session_handle", "o", &session)) {
        jsti_set_error(error, capacity, "The desktop portal did not create a session.");
    }
    g_variant_unref(results);
    return session;
}

void portal_close_session(Portal *state, const gchar *session) {
    if (session == NULL || state->bus == NULL) return;
    g_dbus_connection_call(
        state->bus, PORTAL_BUS_NAME, session, SESSION_INTERFACE, "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE,
        CALL_TIMEOUT_MS, NULL, NULL, NULL);
}

/* ------------------------------------------------------------ availability */

typedef struct Availability {
    const char *interface_name;
    guint32 version;
} Availability;

static int32_t availability_work(Portal *state, gpointer data, char *error, size_t capacity) {
    Availability *query = data;
    GError *failure = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        state->bus, PORTAL_BUS_NAME, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", query->interface_name, "version"), G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE,
        2000, NULL, &failure);
    if (reply == NULL) {
        jsti_set_error(error, capacity, "%s", failure != NULL ? failure->message : "unavailable");
        g_clear_error(&failure);
        return -1;
    }
    GVariant *value = NULL;
    g_variant_get(reply, "(v)", &value);
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) query->version = g_variant_get_uint32(value);
    g_variant_unref(value);
    g_variant_unref(reply);
    return 0;
}

int32_t jsti_portal_available(const char *interface_name, uint32_t *version) {
    char error[256];
    Availability query = { .interface_name = interface_name };
    if (portal_run(availability_work, &query, error, sizeof error) != 0) return 0;
    if (version != NULL) *version = query.version;
    return 1;
}

/* -------------------------------------------------------------- Background */

typedef struct BackgroundRequest {
    gboolean autostart;
    const char *reason;
    const char *const *commandline;
    int32_t reached;
} BackgroundRequest;

static int32_t background_work(Portal *state, gpointer data, char *error, size_t capacity) {
    BackgroundRequest *request = data;
    GVariantBuilder arguments, options;
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_add(&arguments, "s", "");
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "reason", g_variant_new_string(request->reason));
    g_variant_builder_add(&options, "{sv}", "autostart", g_variant_new_boolean(request->autostart));
    g_variant_builder_add(&options, "{sv}", "commandline", g_variant_new_strv(request->commandline, -1));
    g_variant_builder_add(&options, "{sv}", "dbus-activatable", g_variant_new_boolean(FALSE));
    guint32 code = 0;
    GVariant *results = portal_request_response(
        state, BACKGROUND_INTERFACE, "RequestBackground", &arguments, &options, DIALOG_TIMEOUT_MS, &code, error,
        capacity);
    if (results == NULL) return -1;
    gboolean autostart = FALSE, background = code == 0;
    g_variant_lookup(results, "autostart", "b", &autostart);
    g_variant_lookup(results, "background", "b", &background);
    g_variant_unref(results);
    if (code > 1) {
        jsti_set_error(error, capacity, "The desktop portal could not complete RequestBackground.");
        return -1;
    }
    /* A refusal is remembered by the desktop, which answers every later
     * request the same way until the user allows it in its settings. */
    request->reached = autostart ? 1 : (request->autostart && (code == 1 || !background)) ? 2 : 0;
    return 0;
}

int32_t jsti_background_request(
    int32_t autostart, const char *reason, const char *const *commandline, int32_t *reached, char *error,
    size_t capacity) {
    if (reason == NULL || commandline == NULL || commandline[0] == NULL || reached == NULL) {
        jsti_set_error(error, capacity, "The background request is incomplete.");
        return -1;
    }
    BackgroundRequest request = { .autostart = autostart != 0, .reason = reason, .commandline = commandline };
    int32_t result = portal_run(background_work, &request, error, capacity);
    if (result == 0) *reached = request.reached;
    return result;
}
