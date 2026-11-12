/* The GlobalShortcuts portal: the dictation shortcut's session and its
 * Activated/Deactivated signals. */
#include "LinuxPortalInternal.h"

/* The bound session; portal thread only. */
static struct {
    gchar *session;
    guint activated;
    guint deactivated;
    jsti_hotkey_fn callback;
    void *context;
    gchar *id;
} shortcuts;

static void shortcut_signal(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)data;
    const gchar *session = NULL, *identifier = NULL;
    guint64 timestamp = 0;
    g_variant_get(parameters, "(&o&st@a{sv})", &session, &identifier, &timestamp, NULL);
    if (g_strcmp0(session, shortcuts.session) != 0 || g_strcmp0(identifier, shortcuts.id) != 0) return;
    if (shortcuts.callback != NULL) {
        shortcuts.callback(g_strcmp0(signal, "Activated") == 0 ? 1 : 0, shortcuts.context);
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
    if (shortcuts.activated != 0) g_dbus_connection_signal_unsubscribe(state->bus, shortcuts.activated);
    if (shortcuts.deactivated != 0) {
        g_dbus_connection_signal_unsubscribe(state->bus, shortcuts.deactivated);
    }
    shortcuts.activated = shortcuts.deactivated = 0;
    portal_close_session(state, shortcuts.session);
    g_clear_pointer(&shortcuts.session, g_free);
    g_clear_pointer(&shortcuts.id, g_free);
    shortcuts.callback = NULL;
    shortcuts.context = NULL;
}

static int32_t shortcuts_start_work(Portal *state, gpointer data, char *error, size_t capacity) {
    ShortcutRequest *request = data;
    shortcuts_stop_on_thread(state);
    gchar *session = portal_create_session(state, SHORTCUTS_INTERFACE, error, capacity);
    if (session == NULL) return -1;
    shortcuts.session = session;
    shortcuts.id = g_strdup(request->identifier);
    shortcuts.callback = request->callback;
    shortcuts.context = request->context;
    shortcuts.activated = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SHORTCUTS_INTERFACE, "Activated", PORTAL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        shortcut_signal, NULL, NULL);
    shortcuts.deactivated = g_dbus_connection_signal_subscribe(
        state->bus, PORTAL_BUS_NAME, SHORTCUTS_INTERFACE, "Deactivated", PORTAL_PATH, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, shortcut_signal, NULL, NULL);
    GVariantBuilder shortcut, bindings, arguments, options;
    g_variant_builder_init(&shortcut, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&shortcut, "{sv}", "description", g_variant_new_string(request->description));
    if (request->trigger != NULL && request->trigger[0] != '\0') {
        g_variant_builder_add(&shortcut, "{sv}", "preferred_trigger", g_variant_new_string(request->trigger));
    }
    g_variant_builder_init(&bindings, G_VARIANT_TYPE("a(sa{sv})"));
    g_variant_builder_add(&bindings, "(s@a{sv})", request->identifier, g_variant_builder_end(&shortcut));
    g_variant_builder_init(&arguments, G_VARIANT_TYPE_TUPLE);
    g_variant_builder_add(&arguments, "o", session);
    g_variant_builder_add_value(&arguments, g_variant_builder_end(&bindings));
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
    if (!portal_started()) return;
    char error[128];
    portal_run(shortcuts_stop_work, NULL, error, sizeof error);
}
