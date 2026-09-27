#include "LinuxWindowInternal.h"

#include <gio/gio.h>
#include <string.h>

/*
 * A StatusNotifierItem tray icon with a small com.canonical.dbusmenu menu
 * (Start or Stop dictation, Show, Quit), served on the GTK main loop. It is
 * registered with org.kde.StatusNotifierWatcher under this connection's unique
 * name, so no well-known name (and no extra Flatpak permission beyond talking
 * to the watcher) is needed. KDE Plasma, most wlroots bars and GNOME with the
 * AppIndicator extension provide a watcher; without one the tray stays off,
 * closing the window quits as before, and the Startup group says so.
 */

#define ITEM_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define WATCHER_NAME "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"

static const gchar item_xml[] =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='WindowId' type='i' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='AttentionIconName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewAttentionIcon'/>"
    "<signal name='NewToolTip'/><signal name='NewStatus'><arg type='s'/></signal>"
    "</interface></node>";

static const gchar menu_xml[] =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/>"
    "<property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconThemePath' type='as' access='read'/>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/>"
    "<arg type='as' direction='in'/><arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' direction='out'/>"
    "<arg type='ai' direction='out'/></method>"
    "<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "</interface></node>";

enum { MENU_TOGGLE = 1, MENU_SHOW = 2, MENU_SEPARATOR = 3, MENU_QUIT = 4 };

typedef struct Tray {
    GDBusConnection *bus;
    GDBusNodeInfo *item_info, *menu_info;
    guint item_id, menu_id, watch_id;
    gchar *app_id;
    gboolean registered;
    gboolean recording;
    guint32 revision;
    jsti_tray_action_fn action;
} Tray;

static Tray tray;

gboolean jsti_tray_registered(void) { return tray.registered; }

static const char *status_text(void) { return tray.recording ? "NeedsAttention" : "Active"; }

static const char *toggle_label(void) { return tray.recording ? "Stop dictation" : "Start dictation"; }

/* ----------------------------------------------------------------- item */

static GVariant *item_property(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name,
    GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error; (void)data;
    if (g_strcmp0(name, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (g_strcmp0(name, "Id") == 0) return g_variant_new_string(tray.app_id);
    if (g_strcmp0(name, "Title") == 0) return g_variant_new_string("Just Speak to It");
    if (g_strcmp0(name, "Status") == 0) return g_variant_new_string(status_text());
    if (g_strcmp0(name, "WindowId") == 0) return g_variant_new_int32(0);
    if (g_strcmp0(name, "IconName") == 0) return g_variant_new_string(tray.app_id);
    if (g_strcmp0(name, "AttentionIconName") == 0) return g_variant_new_string("media-record");
    if (g_strcmp0(name, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(name, "Menu") == 0) return g_variant_new_object_path(MENU_PATH);
    if (g_strcmp0(name, "ToolTip") == 0) {
        return g_variant_new("(s@a(iiay)ss)", "", g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0),
                             "Just Speak to It", tray.recording ? "Dictating… click to show the window." : "Ready to dictate.");
    }
    return NULL;
}

static void item_method(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *method,
    GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)parameters; (void)data;
    if (g_strcmp0(method, "Activate") == 0) tray.action(JSTI_TRAY_SHOW);
    else if (g_strcmp0(method, "SecondaryActivate") == 0) tray.action(JSTI_TRAY_TOGGLE);
    g_dbus_method_invocation_return_value(invocation, NULL);
}

/* ----------------------------------------------------------------- menu */

static GVariant *menu_item(gint32 id, gboolean with_children) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    switch (id) {
    case 0: g_variant_builder_add(&properties, "{sv}", "children-display", g_variant_new_string("submenu")); break;
    case MENU_TOGGLE: g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(toggle_label())); break;
    case MENU_SHOW: g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string("Show Just Speak to It")); break;
    case MENU_SEPARATOR: g_variant_builder_add(&properties, "{sv}", "type", g_variant_new_string("separator")); break;
    case MENU_QUIT: g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string("Quit")); break;
    default: break;
    }
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (id == 0 && with_children) {
        for (gint32 child = MENU_TOGGLE; child <= MENU_QUIT; child++) {
            g_variant_builder_add(&children, "v", menu_item(child, FALSE));
        }
    }
    return g_variant_new("(ia{sv}av)", id, &properties, &children);
}

static void menu_method(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *method,
    GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)data;
    if (g_strcmp0(method, "GetLayout") == 0) {
        gint32 parent = 0, depth = -1;
        g_variant_get(parameters, "(ii@as)", &parent, &depth, NULL);
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(u@(ia{sv}av))", tray.revision, menu_item(parent, depth != 0)));
    } else if (g_strcmp0(method, "GetGroupProperties") == 0) {
        GVariantIter *ids = NULL;
        g_variant_get(parameters, "(ai@as)", &ids, NULL);
        GVariantBuilder result;
        g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id;
        while (g_variant_iter_next(ids, "i", &id)) {
            GVariant *item = g_variant_ref_sink(menu_item(id, FALSE));
            GVariant *properties = g_variant_get_child_value(item, 1);
            g_variant_builder_add(&result, "(i@a{sv})", id, properties);
            g_variant_unref(properties);
            g_variant_unref(item);
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(a(ia{sv}))", &result));
    } else if (g_strcmp0(method, "GetProperty") == 0) {
        gint32 id = 0;
        const gchar *name = NULL;
        g_variant_get(parameters, "(i&s)", &id, &name);
        GVariant *item = g_variant_ref_sink(menu_item(id, FALSE));
        GVariant *properties = g_variant_get_child_value(item, 1);
        GVariant *value = g_variant_lookup_value(properties, name, NULL);
        g_variant_unref(properties);
        g_variant_unref(item);
        if (value == NULL) {
            g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "No such property");
        } else {
            g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
            g_variant_unref(value);
        }
    } else if (g_strcmp0(method, "Event") == 0) {
        gint32 id = 0;
        const gchar *event = NULL;
        g_variant_get(parameters, "(i&s@vu)", &id, &event, NULL, NULL);
        g_dbus_method_invocation_return_value(invocation, NULL);
        if (g_strcmp0(event, "clicked") == 0) {
            if (id == MENU_TOGGLE) tray.action(JSTI_TRAY_TOGGLE);
            else if (id == MENU_SHOW) tray.action(JSTI_TRAY_SHOW);
            else if (id == MENU_QUIT) tray.action(JSTI_TRAY_QUIT);
        }
    } else if (g_strcmp0(method, "EventGroup") == 0) {
        GVariantIter *events = NULL;
        g_variant_get(parameters, "(a(isvu))", &events);
        gint32 id;
        const gchar *event;
        GVariant *payload;
        guint32 timestamp;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, &payload, &timestamp)) {
            if (g_strcmp0(event, "clicked") == 0) {
                if (id == MENU_TOGGLE) tray.action(JSTI_TRAY_TOGGLE);
                else if (id == MENU_SHOW) tray.action(JSTI_TRAY_SHOW);
                else if (id == MENU_QUIT) tray.action(JSTI_TRAY_QUIT);
            }
            g_variant_unref(payload);
        }
        g_variant_iter_free(events);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else if (g_strcmp0(method, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
    } else if (g_strcmp0(method, "AboutToShowGroup") == 0) {
        GVariant *empty = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0);
        GVariant *errors = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai@ai)", empty, errors));
    } else {
        g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown method");
    }
}

static GVariant *menu_property(
    GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name,
    GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error; (void)data;
    if (g_strcmp0(name, "Version") == 0) return g_variant_new_uint32(3);
    if (g_strcmp0(name, "TextDirection") == 0) return g_variant_new_string("ltr");
    if (g_strcmp0(name, "Status") == 0) return g_variant_new_string("normal");
    if (g_strcmp0(name, "IconThemePath") == 0) return g_variant_new_strv(NULL, 0);
    return NULL;
}

static const GDBusInterfaceVTable item_vtable = { item_method, item_property, NULL, { 0 } };
static const GDBusInterfaceVTable menu_vtable = { menu_method, menu_property, NULL, { 0 } };

/* ----------------------------------------------------------- registration */

static void registered(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *failure = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &failure);
    tray.registered = reply != NULL;
    if (reply != NULL) g_variant_unref(reply);
    g_clear_error(&failure);
    tray.action(tray.registered ? JSTI_TRAY_AVAILABLE : JSTI_TRAY_UNAVAILABLE);
}

static void watcher_appeared(GDBusConnection *bus, const gchar *name, const gchar *owner, gpointer data) {
    (void)name; (void)owner; (void)data;
    g_dbus_connection_call(
        bus, WATCHER_NAME, WATCHER_PATH, WATCHER_NAME, "RegisterStatusNotifierItem",
        g_variant_new("(s)", g_dbus_connection_get_unique_name(bus)), NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL,
        registered, NULL);
}

static void watcher_vanished(GDBusConnection *bus, const gchar *name, gpointer data) {
    (void)bus; (void)name; (void)data;
    tray.registered = FALSE;
    tray.action(JSTI_TRAY_UNAVAILABLE);
}

int32_t jsti_tray_start(const char *app_id, jsti_tray_action_fn action, char *error, size_t capacity) {
    if (tray.bus != NULL) return 0;
    GError *failure = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &failure);
    if (bus == NULL) {
        jsti_set_error(error, capacity, "No session bus for the tray: %s", failure != NULL ? failure->message : "unknown");
        g_clear_error(&failure);
        return -1;
    }
    tray.bus = bus;
    tray.app_id = g_strdup(app_id);
    tray.action = action;
    tray.revision = 1;
    tray.item_info = g_dbus_node_info_new_for_xml(item_xml, NULL);
    tray.menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    tray.item_id = g_dbus_connection_register_object(
        bus, ITEM_PATH, tray.item_info->interfaces[0], &item_vtable, NULL, NULL, &failure);
    if (tray.item_id != 0) {
        tray.menu_id = g_dbus_connection_register_object(
            bus, MENU_PATH, tray.menu_info->interfaces[0], &menu_vtable, NULL, NULL, &failure);
    }
    if (tray.item_id == 0 || tray.menu_id == 0) {
        jsti_set_error(error, capacity, "The tray icon could not be exported: %s",
                       failure != NULL ? failure->message : "unknown");
        g_clear_error(&failure);
        jsti_tray_stop();
        return -1;
    }
    tray.watch_id = g_bus_watch_name_on_connection(
        bus, WATCHER_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared, watcher_vanished, NULL, NULL);
    return 0;
}

void jsti_tray_set_recording(gboolean recording) {
    if (tray.bus == NULL || tray.recording == recording) return;
    tray.recording = recording;
    tray.revision++;
    g_dbus_connection_emit_signal(tray.bus, NULL, ITEM_PATH, "org.kde.StatusNotifierItem", "NewStatus",
                                  g_variant_new("(s)", status_text()), NULL);
    g_dbus_connection_emit_signal(tray.bus, NULL, ITEM_PATH, "org.kde.StatusNotifierItem", "NewToolTip", NULL, NULL);
    g_dbus_connection_emit_signal(tray.bus, NULL, MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated",
                                  g_variant_new("(ui)", tray.revision, 0), NULL);
}

void jsti_tray_stop(void) {
    if (tray.bus == NULL) return;
    if (tray.watch_id != 0) g_bus_unwatch_name(tray.watch_id);
    if (tray.item_id != 0) g_dbus_connection_unregister_object(tray.bus, tray.item_id);
    if (tray.menu_id != 0) g_dbus_connection_unregister_object(tray.bus, tray.menu_id);
    g_clear_pointer(&tray.item_info, g_dbus_node_info_unref);
    g_clear_pointer(&tray.menu_info, g_dbus_node_info_unref);
    g_clear_object(&tray.bus);
    g_clear_pointer(&tray.app_id, g_free);
    tray = (Tray){ 0 };
}
