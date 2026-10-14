#include "LinuxSupportInternal.h"
#include <gio/gio.h>
#include <unistd.h>
#include <string.h>

static GDBusConnection *system_bus, *session_bus;
static guint system_signals[5], screen_signals[3];
static gchar *session_path;
static const char *screen_service;
static gint registered, blocked;

static void absent(const char *reason, gint bit) {
    g_atomic_int_or(&blocked, bit);
    jsti_window_emit(JSTI_EVENT_USER_ABSENT, reason, 0);
}

static void system_signal(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)interface; (void)data;
    if (g_strcmp0(signal, "PrepareForSleep") == 0 && g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) {
        gboolean sleeping;
        g_variant_get(parameters, "(b)", &sleeping);
        if (sleeping) absent("computer suspended", 2);
        else g_atomic_int_and(&blocked, ~2);
    } else if (g_strcmp0(path, session_path) == 0) {
        if (g_strcmp0(signal, "Lock") == 0) absent("session locked", 1);
        else if (g_strcmp0(signal, "Unlock") == 0) g_atomic_int_and(&blocked, ~1);
        else if (g_strcmp0(signal, "PropertiesChanged") == 0 &&
                 g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sa{sv}as)"))) {
            const char *changed_interface;
            GVariant *changed, *invalidated;
            g_variant_get(parameters, "(&s@a{sv}@as)", &changed_interface, &changed, &invalidated);
            if (g_strcmp0(changed_interface, "org.freedesktop.login1.Session") == 0) {
                gboolean value;
                if (g_variant_lookup(changed, "Active", "b", &value)) {
                    if (!value) absent("session inactive", 4);
                    else g_atomic_int_and(&blocked, ~4);
                }
                if (g_variant_lookup(changed, "LockedHint", "b", &value)) {
                    if (value) absent("session locked", 1);
                    else g_atomic_int_and(&blocked, ~1);
                }
                GVariantIter iterator;
                const char *property;
                g_variant_iter_init(&iterator, invalidated);
                while (g_variant_iter_next(&iterator, "&s", &property)) {
                    if (g_strcmp0(property, "Active") == 0 || g_strcmp0(property, "LockedHint") == 0) {
                        g_atomic_int_set(&registered, 0);
                        absent("session monitoring state invalidated", 8);
                    }
                }
            }
            g_variant_unref(changed);
            g_variant_unref(invalidated);
        }
    }
}

static void screen_signal(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal; (void)data;
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
    gboolean active;
    g_variant_get(parameters, "(b)", &active);
    if (active) absent("screen locked", 16);
    else g_atomic_int_and(&blocked, ~16);
}

static void bus_closed(GDBusConnection *bus, gboolean remote, GError *error, gpointer data) {
    (void)bus; (void)remote; (void)error; (void)data;
    g_atomic_int_set(&registered, 0);
    absent("session monitoring disconnected", 8);
}

static void owner_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal; (void)data;
    const char *name, *old_owner, *new_owner;
    g_variant_get(parameters, "(&s&s&s)", &name, &old_owner, &new_owner);
    if (new_owner[0] == '\0' && old_owner[0] != '\0' &&
        (g_strcmp0(name, "org.freedesktop.login1") == 0 ||
         g_strcmp0(name, screen_service) == 0)) {
        g_atomic_int_set(&registered, 0);
        absent("session monitoring service ended", 8);
    }
}

static gboolean has_owner(const char *name) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(session_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    gboolean owned = FALSE;
    if (reply) { g_variant_get(reply, "(b)", &owned); g_variant_unref(reply); }
    if (error) { g_printerr("Hands-free lock service query failed: %s\n", error->message); g_error_free(error); }
    return owned;
}

void jsti_hands_free_guard_stop(void) {
    g_atomic_int_set(&registered, 0);
    if (system_bus) {
        for (size_t i = 0; i < G_N_ELEMENTS(system_signals); ++i)
            if (system_signals[i]) g_dbus_connection_signal_unsubscribe(system_bus, system_signals[i]);
        g_signal_handlers_disconnect_by_func(system_bus, G_CALLBACK(bus_closed), NULL);
    }
    if (session_bus) {
        for (size_t i = 0; i < G_N_ELEMENTS(screen_signals); ++i)
            if (screen_signals[i]) g_dbus_connection_signal_unsubscribe(session_bus, screen_signals[i]);
        g_signal_handlers_disconnect_by_func(session_bus, G_CALLBACK(bus_closed), NULL);
    }
    memset(system_signals, 0, sizeof(system_signals));
    memset(screen_signals, 0, sizeof(screen_signals));
    g_clear_object(&system_bus);
    g_clear_object(&session_bus);
    g_clear_pointer(&session_path, g_free);
    screen_service = NULL;
}

void jsti_hands_free_guard_start(void) {
    jsti_hands_free_guard_stop();
    g_atomic_int_set(&blocked, 0);
    GError *error = NULL;
    system_bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (!system_bus) goto failed;
    session_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!session_bus) goto failed;
    GVariant *reply = g_dbus_connection_call_sync(system_bus, "org.freedesktop.login1",
        "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID",
        g_variant_new("(u)", (guint)getpid()), G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    if (!reply) {
        const char *session_id = g_getenv("XDG_SESSION_ID");
        if (!session_id || !session_id[0]) goto failed;
        g_clear_error(&error);
        reply = g_dbus_connection_call_sync(system_bus, "org.freedesktop.login1",
            "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSession",
            g_variant_new("(s)", session_id), G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    }
    if (!reply) goto failed;
    g_variant_get(reply, "(o)", &session_path);
    g_variant_unref(reply);
    gboolean standard = has_owner("org.freedesktop.ScreenSaver"), gnome = has_owner("org.gnome.ScreenSaver");
    if (!standard && !gnome) goto failed;
    const char *screen_name = gnome ? "org.gnome.ScreenSaver" : "org.freedesktop.ScreenSaver";
    const char *screen_path = gnome ? "/org/gnome/ScreenSaver" : "/org/freedesktop/ScreenSaver";
    screen_service = screen_name;
    system_signals[0] = g_dbus_connection_signal_subscribe(system_bus, "org.freedesktop.login1",
        "org.freedesktop.login1.Manager", "PrepareForSleep", "/org/freedesktop/login1", NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, system_signal, NULL, NULL);
    system_signals[1] = g_dbus_connection_signal_subscribe(system_bus, "org.freedesktop.login1",
        "org.freedesktop.login1.Session", "Lock", session_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, system_signal, NULL, NULL);
    system_signals[2] = g_dbus_connection_signal_subscribe(system_bus, "org.freedesktop.login1",
        "org.freedesktop.login1.Session", "Unlock", session_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, system_signal, NULL, NULL);
    system_signals[3] = g_dbus_connection_signal_subscribe(system_bus, "org.freedesktop.login1",
        "org.freedesktop.DBus.Properties", "PropertiesChanged", session_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, system_signal, NULL, NULL);
    system_signals[4] = g_dbus_connection_signal_subscribe(system_bus, "org.freedesktop.DBus",
        "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", "org.freedesktop.login1",
        G_DBUS_SIGNAL_FLAGS_NONE, owner_changed, NULL, NULL);
    screen_signals[0] = g_dbus_connection_signal_subscribe(session_bus, screen_name, screen_name, "ActiveChanged",
        screen_path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, screen_signal, NULL, NULL);
    screen_signals[2] = g_dbus_connection_signal_subscribe(session_bus, "org.freedesktop.DBus",
        "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, owner_changed, NULL, NULL);
    g_signal_connect(system_bus, "closed", G_CALLBACK(bus_closed), NULL);
    g_signal_connect(session_bus, "closed", G_CALLBACK(bus_closed), NULL);
    reply = g_dbus_connection_call_sync(system_bus, "org.freedesktop.login1", session_path,
        "org.freedesktop.DBus.Properties", "GetAll", g_variant_new("(s)", "org.freedesktop.login1.Session"),
        G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    if (!reply) goto failed;
    GVariant *properties;
    g_variant_get(reply, "(@a{sv})", &properties);
    gboolean active = FALSE, locked = TRUE;
    gboolean known = g_variant_lookup(properties, "Active", "b", &active) &&
        g_variant_lookup(properties, "LockedHint", "b", &locked);
    GVariant *user = g_variant_lookup_value(properties, "User", G_VARIANT_TYPE("(uo)"));
    if (user) {
        guint uid;
        const char *user_path;
        g_variant_get(user, "(u&o)", &uid, &user_path);
        known = known && uid == (guint)getuid();
        g_variant_unref(user);
    } else known = FALSE;
    g_variant_unref(properties);
    g_variant_unref(reply);
    if (!known) goto failed;
    if (!active) g_atomic_int_or(&blocked, 4);
    if (locked) g_atomic_int_or(&blocked, 1);
    reply = g_dbus_connection_call_sync(session_bus, screen_name, screen_path, screen_name, "GetActive",
        NULL, G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    if (!reply) goto failed;
    g_variant_get(reply, "(b)", &active);
    g_variant_unref(reply);
    if (active) g_atomic_int_or(&blocked, 16);
    g_atomic_int_set(&registered, 1);
    return;
failed:
    g_printerr("Hands-free unavailable: native lock/sleep monitoring failed%s%s. Manual recording is unaffected.\n",
        error ? ": " : "", error ? error->message : "");
    g_clear_error(&error);
    jsti_hands_free_guard_stop();
}

int32_t jsti_window_hands_free_guard_ready(void) {
    return g_atomic_int_get(&registered) && !g_atomic_int_get(&blocked);
}

int32_t jsti_hands_free_guard_self_test(char *error, size_t capacity) {
    const gint saved_blocked = g_atomic_int_get(&blocked), saved_registered = g_atomic_int_get(&registered);
    g_atomic_int_set(&blocked, 0);
    GVariant *yes = g_variant_ref_sink(g_variant_new("(b)", TRUE));
    GVariant *no = g_variant_ref_sink(g_variant_new("(b)", FALSE));
    system_signal(NULL, NULL, "/org/freedesktop/login1", NULL, "PrepareForSleep", yes, NULL);
    screen_signal(NULL, NULL, NULL, NULL, NULL, yes, NULL);
    system_signal(NULL, NULL, "/org/freedesktop/login1", NULL, "PrepareForSleep", no, NULL);
    const gboolean stayed_locked = g_atomic_int_get(&blocked) == 16 && !jsti_window_hands_free_guard_ready();
    screen_signal(NULL, NULL, NULL, NULL, NULL, no, NULL);
    const gboolean cleared = g_atomic_int_get(&blocked) == 0;
    GVariant *lost = g_variant_ref_sink(g_variant_new("(sss)", "org.freedesktop.login1", ":fixture", ""));
    owner_changed(NULL, NULL, NULL, NULL, NULL, lost, NULL);
    const gboolean refused = !jsti_window_hands_free_guard_ready();
    g_variant_unref(yes); g_variant_unref(no); g_variant_unref(lost);
    g_atomic_int_set(&blocked, saved_blocked);
    g_atomic_int_set(&registered, saved_registered);
    if (stayed_locked && cleared && refused) return 0;
    jsti_set_error(error, capacity, "Hands-free native lock/sleep ownership fixture failed.");
    return -1;
}
