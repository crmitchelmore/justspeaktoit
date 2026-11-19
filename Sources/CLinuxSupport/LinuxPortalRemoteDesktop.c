/* The RemoteDesktop portal: one keyboard session (persist mode 2) with the
 * Clipboard portal attached, for Wayland insertion. */
#include "LinuxPortalInternal.h"

#include <gio/gunixfdlist.h>
#include <string.h>
#include <unistd.h>
#include <X11/keysym.h>

/* The keyboard session and the selection it offers; portal thread only. */
static struct {
    gchar *session;
    gboolean clipboard;
    guint closed;
    guint selection_transfer;
    gchar *selection_text;
} remote;

static void remote_closed(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)interface; (void)signal; (void)parameters; (void)data;
    if (g_strcmp0(path, remote.session) != 0) return;
    g_clear_pointer(&remote.session, g_free);
    remote.clipboard = FALSE;
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
    if (g_strcmp0(session, remote.session) != 0) return;
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
            const char *text = remote.selection_text != NULL ? remote.selection_text : "";
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
    if (remote.closed != 0) g_dbus_connection_signal_unsubscribe(state->bus, remote.closed);
    if (remote.selection_transfer != 0) g_dbus_connection_signal_unsubscribe(state->bus, remote.selection_transfer);
    remote.closed = remote.selection_transfer = 0;
    portal_close_session(state, remote.session);
    g_clear_pointer(&remote.session, g_free);
    g_clear_pointer(&remote.selection_text, g_free);
    remote.clipboard = FALSE;
}

typedef struct RemoteStart {
    const char *restore_token;
    char *new_token;
    size_t new_token_capacity;
} RemoteStart;

static int32_t remote_start_work(Portal *state, gpointer data, char *error, size_t capacity) {
    RemoteStart *request = data;
    if (remote.session != NULL) return 0;
    gchar *session = portal_create_session(state, REMOTE_INTERFACE, error, capacity);
    if (session == NULL) return -1;
    remote.session = session;
    remote.closed = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SESSION_INTERFACE, "Closed", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        remote_closed, NULL, NULL);
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
    remote.clipboard = clipboard_enabled;
    if (clipboard_enabled) {
        remote.selection_transfer = g_dbus_connection_signal_subscribe(
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
    (void)state; (void)error; (void)capacity;
    *(int32_t *)data = remote.session != NULL ? (remote.clipboard ? 2 : 1) : 0;
    return 0;
}

/* 0 inactive, 1 keyboard only, 2 keyboard and clipboard. */
int32_t jsti_remote_desktop_active(void) {
    if (!portal_started()) return 0;
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
        g_variant_new("(o@a{sv}iu)", remote.session, g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0),
                      (gint32)keysym, down ? 1u : 0u), error, capacity);
    if (reply == NULL) return FALSE;
    g_variant_unref(reply);
    return TRUE;
}

static int32_t remote_paste_work(Portal *state, gpointer data, char *error, size_t capacity) {
    RemotePaste *request = data;
    if (remote.session == NULL) {
        jsti_set_error(error, capacity, "The keyboard session ended.");
        return -1;
    }
    if (request->text != NULL) {
        if (!remote.clipboard) {
            jsti_set_error(error, capacity, "The desktop did not share its clipboard with this session.");
            return -1;
        }
        g_free(remote.selection_text);
        remote.selection_text = g_strdup(request->text);
        const gchar *types[] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", NULL };
        GVariantBuilder options;
        g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
        g_variant_builder_add(&options, "{sv}", "mime_types", g_variant_new_strv(types, -1));
        GVariant *reply = portal_call(
            state, CLIPBOARD_INTERFACE, "SetSelection",
            g_variant_new("(o@a{sv})", remote.session, g_variant_builder_end(&options)), error, capacity);
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
    if (!portal_started()) return;
    char error[128];
    portal_run(remote_stop_work, NULL, error, sizeof error);
}
