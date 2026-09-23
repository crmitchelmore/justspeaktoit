#include "LinuxSupportInternal.h"

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <string.h>
#include <unistd.h>
#include <X11/keysym.h>

/*
 * XDG desktop portals over the session bus: GlobalShortcuts for the dictation
 * shortcut, and one RemoteDesktop session (keyboard only, persist mode 2)
 * with the Clipboard portal attached for Wayland insertion. Everything runs on
 * one dedicated thread with its own GMainContext, so the portals work without
 * the GTK loop and never block it. Public calls marshal onto that thread and
 * wait. Portal requests that may show a consent dialog wait up to five
 * minutes; the user can always dismiss them.
 */

#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define REQUEST_INTERFACE "org.freedesktop.portal.Request"
#define SESSION_INTERFACE "org.freedesktop.portal.Session"
#define SHORTCUTS_INTERFACE "org.freedesktop.portal.GlobalShortcuts"
#define REMOTE_INTERFACE "org.freedesktop.portal.RemoteDesktop"
#define CLIPBOARD_INTERFACE "org.freedesktop.portal.Clipboard"
#define DIALOG_TIMEOUT_MS (5 * 60 * 1000)
#define CALL_TIMEOUT_MS 10000

typedef struct Portal {
    GThread *thread;
    GMainContext *context;
    GMainLoop *loop;
    GDBusConnection *bus;
    gchar *sender;
    guint token;
    /* GlobalShortcuts */
    gchar *shortcuts_session;
    guint shortcuts_activated;
    guint shortcuts_deactivated;
    jsti_hotkey_fn shortcut_callback;
    void *shortcut_context;
    gchar *shortcut_id;
    /* RemoteDesktop */
    gchar *remote_session;
    gboolean remote_clipboard;
    guint remote_closed;
    guint selection_transfer;
    gchar *selection_text;
} Portal;

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

/* ------------------------------------------------------ run on the thread */

typedef struct PortalCall {
    GMutex lock;
    GCond changed;
    gboolean done;
    int32_t (*work)(Portal *state, gpointer data, char *error, size_t capacity);
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

/* Runs `work` on the portal thread; the caller waits for it to finish. Work
 * is bounded by its own D-Bus and dialog timeouts. */
static int32_t portal_run(
    int32_t (*work)(Portal *, gpointer, char *, size_t), gpointer data, char *error, size_t capacity) {
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
 * tuple builder left open for the options. Returns the results on success.
 */
static GVariant *portal_request(
    Portal *state, const char *interface, const char *method, GVariantBuilder *arguments,
    GVariantBuilder *options, guint timeout_ms, char *error, size_t capacity) {
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
    } else if (response.code == 1) {
        jsti_set_error(error, capacity, "Permission was declined in the desktop dialog.");
    } else if (response.code != 0) {
        jsti_set_error(error, capacity, "The desktop portal could not complete %s.", method);
    } else {
        results = response.results;
        response.results = NULL;
    }
done:
    if (response.results != NULL) g_variant_unref(response.results);
    g_dbus_connection_signal_unsubscribe(state->bus, subscription);
    g_free(path);
    g_free(token);
    return results;
}

static GVariant *portal_call(
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

static gchar *create_session(Portal *state, const char *interface, char *error, size_t capacity) {
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

static void close_session(Portal *state, const gchar *session) {
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

/* --------------------------------------------------------- GlobalShortcuts */

static void shortcut_signal(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface;
    Portal *state = data;
    const gchar *session = NULL, *identifier = NULL;
    guint64 timestamp = 0;
    g_variant_get(parameters, "(&o&st@a{sv})", &session, &identifier, &timestamp, NULL);
    if (g_strcmp0(session, state->shortcuts_session) != 0 || g_strcmp0(identifier, state->shortcut_id) != 0) return;
    if (state->shortcut_callback != NULL) {
        state->shortcut_callback(g_strcmp0(signal, "Activated") == 0 ? 1 : 0, state->shortcut_context);
    }
}

typedef struct ShortcutRequest {
    const char *identifier;
    const char *description;
    const char *trigger;
    jsti_hotkey_fn callback;
    void *context;
    char *trigger_description;
    size_t trigger_capacity;
} ShortcutRequest;

static void shortcuts_stop_on_thread(Portal *state) {
    if (state->shortcuts_activated != 0) g_dbus_connection_signal_unsubscribe(state->bus, state->shortcuts_activated);
    if (state->shortcuts_deactivated != 0) {
        g_dbus_connection_signal_unsubscribe(state->bus, state->shortcuts_deactivated);
    }
    state->shortcuts_activated = state->shortcuts_deactivated = 0;
    close_session(state, state->shortcuts_session);
    g_clear_pointer(&state->shortcuts_session, g_free);
    g_clear_pointer(&state->shortcut_id, g_free);
    state->shortcut_callback = NULL;
    state->shortcut_context = NULL;
}

static int32_t shortcuts_start_work(Portal *state, gpointer data, char *error, size_t capacity) {
    ShortcutRequest *request = data;
    shortcuts_stop_on_thread(state);
    gchar *session = create_session(state, SHORTCUTS_INTERFACE, error, capacity);
    if (session == NULL) return -1;
    state->shortcuts_session = session;
    state->shortcut_id = g_strdup(request->identifier);
    state->shortcut_callback = request->callback;
    state->shortcut_context = request->context;
    state->shortcuts_activated = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SHORTCUTS_INTERFACE, "Activated", PORTAL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        shortcut_signal, state, NULL);
    state->shortcuts_deactivated = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SHORTCUTS_INTERFACE, "Deactivated", PORTAL_PATH, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, shortcut_signal, state, NULL);
    GVariantBuilder shortcut, shortcuts, arguments, options;
    g_variant_builder_init(&shortcut, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&shortcut, "{sv}", "description", g_variant_new_string(request->description));
    if (request->trigger != NULL && request->trigger[0] != '\0') {
        g_variant_builder_add(&shortcut, "{sv}", "preferred_trigger", g_variant_new_string(request->trigger));
    }
    g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
    g_variant_builder_add(&shortcuts, "(s@a{sv})", request->identifier, g_variant_builder_end(&shortcut));
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_add(&arguments, "o", session);
    g_variant_builder_add_value(&arguments, g_variant_builder_end(&shortcuts));
    g_variant_builder_add(&arguments, "s", "");
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    GVariant *results = portal_request(
        state, SHORTCUTS_INTERFACE, "BindShortcuts", &arguments, &options, DIALOG_TIMEOUT_MS, error, capacity);
    if (results == NULL) {
        shortcuts_stop_on_thread(state);
        return -1;
    }
    GVariant *bound = g_variant_lookup_value(results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
    gboolean found = FALSE;
    if (bound != NULL) {
        GVariantIter iterator;
        const gchar *identifier = NULL;
        GVariant *properties = NULL;
        g_variant_iter_init(&iterator, bound);
        while (g_variant_iter_next(&iterator, "(&s@a{sv})", &identifier, &properties)) {
            if (g_strcmp0(identifier, request->identifier) == 0) {
                found = TRUE;
                const gchar *description = NULL;
                if (request->trigger_description != NULL &&
                    g_variant_lookup(properties, "trigger_description", "&s", &description)) {
                    g_strlcpy(request->trigger_description, description, request->trigger_capacity);
                }
            }
            g_variant_unref(properties);
        }
        g_variant_unref(bound);
    }
    g_variant_unref(results);
    if (!found) {
        jsti_set_error(error, capacity, "The desktop did not assign the dictation shortcut.");
        shortcuts_stop_on_thread(state);
        return -1;
    }
    return 0;
}

int32_t jsti_shortcuts_start(
    const char *shortcut_id, const char *description, const char *preferred_trigger, jsti_hotkey_fn callback,
    void *context, char *trigger_description, size_t trigger_capacity, char *error, size_t capacity) {
    if (trigger_description != NULL && trigger_capacity > 0) trigger_description[0] = '\0';
    ShortcutRequest request = {
        .identifier = shortcut_id, .description = description, .trigger = preferred_trigger, .callback = callback,
        .context = context, .trigger_description = trigger_description, .trigger_capacity = trigger_capacity
    };
    return portal_run(shortcuts_start_work, &request, error, capacity);
}

static int32_t shortcuts_stop_work(Portal *state, gpointer data, char *error, size_t capacity) {
    (void)data; (void)error; (void)capacity;
    shortcuts_stop_on_thread(state);
    return 0;
}

void jsti_shortcuts_stop(void) {
    g_mutex_lock(&portal_lock);
    gboolean started = portal != NULL;
    g_mutex_unlock(&portal_lock);
    if (!started) return;
    char error[128];
    portal_run(shortcuts_stop_work, NULL, error, sizeof error);
}

/* ----------------------------------------------------------- RemoteDesktop */

static void remote_closed(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)interface; (void)signal; (void)parameters;
    Portal *state = data;
    if (g_strcmp0(path, state->remote_session) != 0) return;
    g_clear_pointer(&state->remote_session, g_free);
    state->remote_clipboard = FALSE;
}

/* Serves the offered selection when the focused application pastes. */
static void selection_transfer(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    Portal *state = data;
    const gchar *session = NULL, *mime = NULL;
    guint32 serial = 0;
    g_variant_get(parameters, "(&o&su)", &session, &mime, &serial);
    if (g_strcmp0(session, state->remote_session) != 0) return;
    GError *failure = NULL;
    GUnixFDList *descriptors = NULL;
    GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
        state->bus, PORTAL_BUS_NAME, PORTAL_PATH, CLIPBOARD_INTERFACE, "SelectionWrite",
        g_variant_new("(ou)", session, serial), G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, CALL_TIMEOUT_MS,
        NULL, &descriptors, NULL, &failure);
    gboolean written = FALSE;
    if (reply != NULL && descriptors != NULL) {
        gint32 handle = 0;
        g_variant_get(reply, "(h)", &handle);
        int descriptor = g_unix_fd_list_get(descriptors, handle, NULL);
        if (descriptor >= 0) {
            const char *text = state->selection_text != NULL ? state->selection_text : "";
            size_t remaining = strlen(text);
            written = TRUE;
            while (remaining > 0) {
                ssize_t count = write(descriptor, text, remaining);
                if (count <= 0) { written = FALSE; break; }
                text += count;
                remaining -= (size_t)count;
            }
            close(descriptor);
        }
    }
    g_clear_error(&failure);
    if (reply != NULL) g_variant_unref(reply);
    if (descriptors != NULL) g_object_unref(descriptors);
    g_dbus_connection_call(
        state->bus, PORTAL_BUS_NAME, PORTAL_PATH, CLIPBOARD_INTERFACE, "SelectionWriteDone",
        g_variant_new("(oub)", session, serial, written), NULL, G_DBUS_CALL_FLAGS_NONE, CALL_TIMEOUT_MS, NULL, NULL,
        NULL);
}

static void remote_stop_on_thread(Portal *state) {
    if (state->remote_closed != 0) g_dbus_connection_signal_unsubscribe(state->bus, state->remote_closed);
    if (state->selection_transfer != 0) g_dbus_connection_signal_unsubscribe(state->bus, state->selection_transfer);
    state->remote_closed = state->selection_transfer = 0;
    close_session(state, state->remote_session);
    g_clear_pointer(&state->remote_session, g_free);
    g_clear_pointer(&state->selection_text, g_free);
    state->remote_clipboard = FALSE;
}

typedef struct RemoteStart {
    const char *restore_token;
    char *new_token;
    size_t new_token_capacity;
} RemoteStart;

static int32_t remote_start_work(Portal *state, gpointer data, char *error, size_t capacity) {
    RemoteStart *request = data;
    if (state->remote_session != NULL) return 0;
    gchar *session = create_session(state, REMOTE_INTERFACE, error, capacity);
    if (session == NULL) return -1;
    state->remote_session = session;
    state->remote_closed = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SESSION_INTERFACE, "Closed", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        remote_closed, state, NULL);
    GVariantBuilder arguments, options;
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_add(&arguments, "o", session);
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(1)); /* KEYBOARD */
    g_variant_builder_add(&options, "{sv}", "persist_mode", g_variant_new_uint32(2)); /* until revoked */
    if (request->restore_token != NULL && request->restore_token[0] != '\0') {
        g_variant_builder_add(&options, "{sv}", "restore_token", g_variant_new_string(request->restore_token));
    }
    GVariant *results = portal_request(
        state, REMOTE_INTERFACE, "SelectDevices", &arguments, &options, CALL_TIMEOUT_MS, error, capacity);
    if (results == NULL) {
        remote_stop_on_thread(state);
        return -1;
    }
    g_variant_unref(results);
    /* The Clipboard portal must be requested before Start. It is optional:
     * without it the app's own clipboard is used. */
    char ignored[256];
    GVariant *clipboard = portal_call(
        state, CLIPBOARD_INTERFACE, "RequestClipboard", g_variant_new("(o@a{sv})", session,
        g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0)), ignored, sizeof ignored);
    if (clipboard != NULL) g_variant_unref(clipboard);
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_add(&arguments, "o", session);
    g_variant_builder_add(&arguments, "s", "");
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    results = portal_request(
        state, REMOTE_INTERFACE, "Start", &arguments, &options, DIALOG_TIMEOUT_MS, error, capacity);
    if (results == NULL) {
        remote_stop_on_thread(state);
        return -1;
    }
    guint32 devices = 0;
    gboolean clipboard_enabled = FALSE;
    const gchar *token = NULL;
    g_variant_lookup(results, "devices", "u", &devices);
    g_variant_lookup(results, "clipboard_enabled", "b", &clipboard_enabled);
    if (g_variant_lookup(results, "restore_token", "&s", &token) && request->new_token != NULL) {
        g_strlcpy(request->new_token, token, request->new_token_capacity);
    }
    g_variant_unref(results);
    if ((devices & 1) == 0) {
        jsti_set_error(error, capacity, "Keyboard access was not granted.");
        remote_stop_on_thread(state);
        return -1;
    }
    state->remote_clipboard = clipboard_enabled;
    if (clipboard_enabled) {
        state->selection_transfer = g_dbus_connection_signal_subscribe(
            state->bus, PORTAL_BUS_NAME, CLIPBOARD_INTERFACE, "SelectionTransfer", PORTAL_PATH, NULL,
            G_DBUS_SIGNAL_FLAGS_NONE, selection_transfer, state, NULL);
    }
    return 0;
}

int32_t jsti_remote_desktop_start(
    const char *restore_token, char *new_token, size_t new_token_capacity, char *error, size_t capacity) {
    if (new_token != NULL && new_token_capacity > 0) new_token[0] = '\0';
    RemoteStart request = {
        .restore_token = restore_token, .new_token = new_token, .new_token_capacity = new_token_capacity
    };
    return portal_run(remote_start_work, &request, error, capacity);
}

static int32_t remote_active_work(Portal *state, gpointer data, char *error, size_t capacity) {
    (void)error; (void)capacity;
    *(int32_t *)data = state->remote_session != NULL ? (state->remote_clipboard ? 2 : 1) : 0;
    return 0;
}

/* 0 inactive, 1 keyboard only, 2 keyboard and clipboard. */
int32_t jsti_remote_desktop_active(void) {
    g_mutex_lock(&portal_lock);
    gboolean started = portal != NULL;
    g_mutex_unlock(&portal_lock);
    if (!started) return 0;
    int32_t active = 0;
    char error[128];
    portal_run(remote_active_work, &active, error, sizeof error);
    return active;
}

typedef struct RemotePaste {
    const char *text;
    int32_t shift;
} RemotePaste;

static gboolean press(Portal *state, guint32 keysym, gboolean down, char *error, size_t capacity) {
    GVariant *reply = portal_call(
        state, REMOTE_INTERFACE, "NotifyKeyboardKeysym",
        g_variant_new("(o@a{sv}iu)", state->remote_session, g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0),
                      (gint32)keysym, down ? 1u : 0u), error, capacity);
    if (reply == NULL) return FALSE;
    g_variant_unref(reply);
    return TRUE;
}

static int32_t remote_paste_work(Portal *state, gpointer data, char *error, size_t capacity) {
    RemotePaste *request = data;
    if (state->remote_session == NULL) {
        jsti_set_error(error, capacity, "The keyboard session ended.");
        return -1;
    }
    if (request->text != NULL) {
        if (!state->remote_clipboard) {
            jsti_set_error(error, capacity, "The desktop did not share its clipboard with this session.");
            return -1;
        }
        g_free(state->selection_text);
        state->selection_text = g_strdup(request->text);
        const gchar *types[] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", NULL };
        GVariantBuilder options;
        g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
        g_variant_builder_add(&options, "{sv}", "mime_types", g_variant_new_strv(types, -1));
        GVariant *reply = portal_call(
            state, CLIPBOARD_INTERFACE, "SetSelection",
            g_variant_new("(o@a{sv})", state->remote_session, g_variant_builder_end(&options)), error, capacity);
        if (reply == NULL) return -1;
        g_variant_unref(reply);
    }
    gboolean sent = press(state, XK_Control_L, TRUE, error, capacity);
    if (sent && request->shift) sent = press(state, XK_Shift_L, TRUE, error, capacity);
    sent = sent && press(state, XK_v, TRUE, error, capacity) && press(state, XK_v, FALSE, error, capacity);
    if (request->shift) press(state, XK_Shift_L, FALSE, error, capacity);
    gboolean released = press(state, XK_Control_L, FALSE, error, capacity);
    return sent && released ? 0 : -1;
}

/* `text` NULL presses the keys without offering a selection. */
int32_t jsti_remote_desktop_paste(const char *text, int32_t shift, char *error, size_t capacity) {
    RemotePaste request = { .text = text, .shift = shift };
    return portal_run(remote_paste_work, &request, error, capacity);
}

static int32_t remote_stop_work(Portal *state, gpointer data, char *error, size_t capacity) {
    (void)data; (void)error; (void)capacity;
    remote_stop_on_thread(state);
    return 0;
}

void jsti_remote_desktop_stop(void) {
    g_mutex_lock(&portal_lock);
    gboolean started = portal != NULL;
    g_mutex_unlock(&portal_lock);
    if (!started) return;
    char error[128];
    portal_run(remote_stop_work, NULL, error, sizeof error);
}
