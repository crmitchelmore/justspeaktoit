#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * The StatusNotifierItem: the Linux counterpart of the Mac's menu bar extra,
 * shown by KDE Plasma, Ubuntu's GNOME (the AppIndicator extension), Cinnamon,
 * XFCE, Budgie, sway bars and most others. Plain GNOME has no watcher, and
 * then nothing is registered. The icon is the brand icon, with a red dot while
 * recording; its com.canonical.dbusmenu menu shows the state and the
 * dashboard's totals and offers Start or Stop Recording, Open, Settings and
 * Quit. The item registers under the app's own bus connection (no extra
 * well-known name), so it also works inside Flatpak with only
 * --talk-name=org.kde.StatusNotifierWatcher.
 */

enum { MENU_ROOT, MENU_STATUS, MENU_SUMMARY, MENU_SEPARATOR, MENU_TOGGLE, MENU_OPEN, MENU_SETTINGS, MENU_SEPARATOR_2,
       MENU_QUIT, MENU_COUNT };

static const char *item_xml =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>"
    "<property name='WindowId' type='i' access='read'/><property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='AttentionIconName' type='s' access='read'/>"
    "<property name='AttentionIconPixmap' type='a(iiay)' access='read'/>"
    "<property name='OverlayIconName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/><property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewToolTip'/>"
    "<signal name='NewStatus'><arg type='s'/></signal>"
    "</interface></node>";

static const char *menu_xml =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/><property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/><property name='IconThemePath' type='as' access='read'/>"
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
    "<signal name='ItemActivationRequested'><arg type='i'/><arg type='u'/></signal>"
    "</interface></node>";

#define ITEM_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define WATCHER "org.kde.StatusNotifierWatcher"

static struct {
    GDBusConnection *bus;
    GDBusNodeInfo *item_info, *menu_info;
    guint item_id, menu_id, watch;
    gint32 state;
    gchar *summary;
    guint32 revision;
} tray;

/* -------------------------------------------------------------- content */

static const char *status_label(gint32 state) {
    return state == JSTI_STATE_RECORDING ? "Recording…" : state == JSTI_STATE_WORKING ? "Transcribing…"
                                                                                     : "Ready to dictate";
}

static const char *toggle_label(gint32 state) {
    return state == JSTI_STATE_RECORDING ? "Stop Recording" : state == JSTI_STATE_WORKING ? "Cancel Transcription"
                                                                                         : "Start Recording";
}

/* ARGB32 in network byte order, not premultiplied, at 22, 32 and 48 px. */
static GVariant *icon_pixmaps(gboolean recording) {
    GVariantBuilder pixmaps;
    g_variant_builder_init(&pixmaps, G_VARIANT_TYPE("a(iiay)"));
    static const int sizes[] = { 22, 32, 48 };
    for (size_t index = 0; index < G_N_ELEMENTS(sizes); ++index) {
        const int size = sizes[index];
        cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size);
        cairo_t *cr = cairo_create(surface);
        jsti_brand_icon_paint(cr, size);
        if (recording) {
            const double dot = MAX(6.0, size * 7.0 / 16.0);
            cairo_arc(cr, size - dot / 2, size - dot / 2, dot / 2, 0, 2 * G_PI);
            cairo_set_source_rgb(cr, 1, 1, 1);
            cairo_fill(cr);
            cairo_arc(cr, size - dot / 2, size - dot / 2, dot / 2 - 1, 0, 2 * G_PI);
            cairo_set_source_rgb(cr, 0xD9 / 255.0, 0x2A / 255.0, 0x2A / 255.0);
            cairo_fill(cr);
        }
        cairo_destroy(cr);
        cairo_surface_flush(surface);
        const int stride = cairo_image_surface_get_stride(surface);
        const guint8 *data = cairo_image_surface_get_data(surface);
        guint8 *bytes = g_malloc((gsize)size * size * 4);
        for (int y = 0; y < size; ++y) {
            for (int x = 0; x < size; ++x) {
                const guint32 pixel = *(const guint32 *)(data + y * stride + x * 4);
                const guint8 alpha = pixel >> 24;
                guint8 *out = bytes + (y * size + x) * 4;
                out[0] = alpha;
                for (int channel = 0; channel < 3; ++channel) {
                    const guint8 value = (pixel >> (16 - 8 * channel)) & 0xFF;
                    out[1 + channel] = alpha ? (guint8)MIN(255, value * 255 / alpha) : 0;
                }
            }
        }
        cairo_surface_destroy(surface);
        g_variant_builder_add(&pixmaps, "(ii@ay)", size, size,
                              g_variant_new_from_data(G_VARIANT_TYPE_BYTESTRING, bytes, (gsize)size * size * 4, TRUE,
                                                      g_free, bytes));
    }
    return g_variant_builder_end(&pixmaps);
}

static GVariant *item_properties(gint id) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    switch (id) {
    case MENU_ROOT:
        g_variant_builder_add(&properties, "{sv}", "children-display", g_variant_new_string("submenu"));
        break;
    case MENU_SEPARATOR: case MENU_SEPARATOR_2:
        g_variant_builder_add(&properties, "{sv}", "type", g_variant_new_string("separator"));
        break;
    case MENU_STATUS: case MENU_SUMMARY: {
        const char *label = id == MENU_STATUS ? status_label(tray.state) : (tray.summary != NULL ? tray.summary : "");
        g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(label));
        g_variant_builder_add(&properties, "{sv}", "enabled", g_variant_new_boolean(FALSE));
        if (id == MENU_SUMMARY && label[0] == '\0') {
            g_variant_builder_add(&properties, "{sv}", "visible", g_variant_new_boolean(FALSE));
        }
        break;
    }
    default: {
        const char *label = id == MENU_TOGGLE ? toggle_label(tray.state) : id == MENU_OPEN ? "Open Just Speak to It"
                          : id == MENU_SETTINGS ? "Settings…" : "Quit Just Speak to It";
        g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(label));
        break;
    }
    }
    return g_variant_builder_end(&properties);
}

static GVariant *layout(gint id, gboolean children) {
    GVariantBuilder items;
    g_variant_builder_init(&items, G_VARIANT_TYPE("av"));
    if (id == MENU_ROOT && children) {
        for (gint child = MENU_STATUS; child < MENU_COUNT; ++child) {
            g_variant_builder_add(&items, "v", layout(child, FALSE));
        }
    }
    return g_variant_new("(i@a{sv}@av)", id, item_properties(id), g_variant_builder_end(&items));
}

static void command(gint id) {
    const int commands[MENU_COUNT] = { [MENU_TOGGLE] = 1, [MENU_OPEN] = 2, [MENU_SETTINGS] = 3, [MENU_QUIT] = 4 };
    if (id > 0 && id < MENU_COUNT && commands[id] != 0) jsti_window_tray_command(commands[id]);
}

/* ------------------------------------------------------------- D-Bus */

static GVariant *item_get(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                          const char *name, GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error; (void)data;
    const gboolean recording = tray.state == JSTI_STATE_RECORDING;
    if (g_strcmp0(name, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (g_strcmp0(name, "Id") == 0) return g_variant_new_string("com.justspeaktoit.JustSpeakToIt");
    if (g_strcmp0(name, "Title") == 0) return g_variant_new_string("Just Speak to It");
    if (g_strcmp0(name, "Status") == 0) return g_variant_new_string("Active");
    if (g_strcmp0(name, "WindowId") == 0) return g_variant_new_int32(0);
    if (g_strcmp0(name, "IconPixmap") == 0) return icon_pixmaps(recording);
    if (g_strcmp0(name, "AttentionIconPixmap") == 0) return icon_pixmaps(TRUE);
    if (g_strcmp0(name, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(name, "Menu") == 0) return g_variant_new_object_path(MENU_PATH);
    if (g_strcmp0(name, "ToolTip") == 0) {
        return g_variant_new("(s@a(iiay)ss)", "", g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0),
                             "Just Speak to It", status_label(tray.state));
    }
    return g_variant_new_string(""); /* IconName, AttentionIconName, OverlayIconName */
}

static void item_call(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                      const char *method, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)parameters; (void)data;
    if (g_strcmp0(method, "Activate") == 0) command(MENU_OPEN);
    else if (g_strcmp0(method, "SecondaryActivate") == 0) command(MENU_TOGGLE);
    g_dbus_method_invocation_return_value(invocation, NULL);
}

static GVariant *menu_get(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                          const char *name, GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error; (void)data;
    if (g_strcmp0(name, "Version") == 0) return g_variant_new_uint32(3);
    if (g_strcmp0(name, "TextDirection") == 0) return g_variant_new_string("ltr");
    if (g_strcmp0(name, "Status") == 0) return g_variant_new_string("normal");
    return g_variant_new_strv(NULL, 0);
}

static void menu_call(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                      const char *method, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)data;
    if (g_strcmp0(method, "GetLayout") == 0) {
        gint parent = 0, depth = 0;
        g_variant_get(parameters, "(ii^a&s)", &parent, &depth, NULL);
        if (parent < 0 || parent >= MENU_COUNT) parent = MENU_ROOT;
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(u@(ia{sv}av))", tray.revision,
                                                                        layout(parent, depth != 0)));
    } else if (g_strcmp0(method, "GetGroupProperties") == 0) {
        GVariantIter *ids = NULL;
        g_variant_get(parameters, "(ai^a&s)", &ids, NULL);
        GVariantBuilder result;
        g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
        gint id;
        while (g_variant_iter_next(ids, "i", &id)) {
            if (id >= 0 && id < MENU_COUNT) g_variant_builder_add(&result, "(i@a{sv})", id, item_properties(id));
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
    } else if (g_strcmp0(method, "GetProperty") == 0) {
        gint id = 0;
        const char *name = NULL;
        g_variant_get(parameters, "(i&s)", &id, &name);
        GVariant *properties = item_properties(id >= 0 && id < MENU_COUNT ? id : MENU_ROOT);
        GVariant *value = g_variant_lookup_value(properties, name, NULL);
        g_variant_unref(g_variant_ref_sink(properties));
        g_dbus_method_invocation_return_value(invocation,
                                              g_variant_new("(v)", value != NULL ? value : g_variant_new_string("")));
        if (value != NULL) g_variant_unref(value);
    } else if (g_strcmp0(method, "Event") == 0) {
        gint id = 0;
        const char *event = NULL;
        g_variant_get(parameters, "(i&svu)", &id, &event, NULL, NULL);
        if (g_strcmp0(event, "clicked") == 0) command(id);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else if (g_strcmp0(method, "EventGroup") == 0) {
        GVariantIter *events = NULL;
        g_variant_get(parameters, "(a(isvu))", &events);
        gint id;
        const char *event;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, NULL, NULL)) {
            if (g_strcmp0(event, "clicked") == 0) command(id);
        }
        g_variant_iter_free(events);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else if (g_strcmp0(method, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
    } else if (g_strcmp0(method, "AboutToShowGroup") == 0) {
        GVariant *none = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0);
        GVariant *errors = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai@ai)", none, errors));
    } else {
        g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown method");
    }
}

static const GDBusInterfaceVTable item_vtable = { item_call, item_get, NULL, { 0 } };
static const GDBusInterfaceVTable menu_vtable = { menu_call, menu_get, NULL, { 0 } };

static void watcher_appeared(GDBusConnection *bus, const char *name, const char *owner, gpointer data) {
    (void)name; (void)owner; (void)data;
    g_dbus_connection_call(bus, WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
                           g_variant_new("(s)", g_dbus_connection_get_unique_name(bus)), NULL,
                           G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL, NULL);
}

void jsti_tray_start(void) {
    if (tray.bus != NULL) return;
    GApplication *application = g_application_get_default();
    GDBusConnection *bus = application != NULL ? g_application_get_dbus_connection(application) : NULL;
    if (bus == NULL) return;
    tray.item_info = g_dbus_node_info_new_for_xml(item_xml, NULL);
    tray.menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    if (tray.item_info == NULL || tray.menu_info == NULL) { jsti_tray_stop(); return; }
    tray.bus = g_object_ref(bus);
    tray.item_id = g_dbus_connection_register_object(bus, ITEM_PATH, tray.item_info->interfaces[0], &item_vtable,
                                                     NULL, NULL, NULL);
    tray.menu_id = g_dbus_connection_register_object(bus, MENU_PATH, tray.menu_info->interfaces[0], &menu_vtable,
                                                     NULL, NULL, NULL);
    /* Registers now and again whenever the panel restarts its watcher. */
    tray.watch = g_bus_watch_name_on_connection(bus, WATCHER, G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared, NULL,
                                                NULL, NULL);
}

static void emit_signal(const char *path, const char *interface, const char *name, GVariant *parameters) {
    if (tray.bus != NULL) g_dbus_connection_emit_signal(tray.bus, NULL, path, interface, name, parameters, NULL);
}

void jsti_tray_set_state(int32_t state, const char *summary) {
    const gboolean changed = state != tray.state || g_strcmp0(summary, tray.summary) != 0;
    const gboolean icon = state != tray.state;
    tray.state = state;
    g_free(tray.summary);
    tray.summary = g_strdup(summary);
    if (!changed) return;
    tray.revision++;
    if (icon) {
        emit_signal(ITEM_PATH, "org.kde.StatusNotifierItem", "NewIcon", NULL);
        emit_signal(ITEM_PATH, "org.kde.StatusNotifierItem", "NewToolTip", NULL);
    }
    emit_signal(MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", tray.revision, 0));
}

void jsti_tray_stop(void) {
    if (tray.watch != 0) g_bus_unwatch_name(tray.watch);
    if (tray.bus != NULL && tray.item_id != 0) g_dbus_connection_unregister_object(tray.bus, tray.item_id);
    if (tray.bus != NULL && tray.menu_id != 0) g_dbus_connection_unregister_object(tray.bus, tray.menu_id);
    tray.watch = tray.item_id = tray.menu_id = 0;
    g_clear_pointer(&tray.item_info, g_dbus_node_info_unref);
    g_clear_pointer(&tray.menu_info, g_dbus_node_info_unref);
    g_clear_object(&tray.bus);
}

/* ------------------------------------------------------------ self-test */

static gchar *layout_label(GVariant *root, gsize index) {
    GVariant *children = g_variant_get_child_value(root, 2);
    GVariant *boxed = g_variant_get_child_value(children, index);
    GVariant *child = g_variant_get_variant(boxed);
    GVariant *properties = g_variant_get_child_value(child, 1);
    gchar *label = NULL;
    g_variant_lookup(properties, "label", "s", &label);
    g_variant_unref(properties);
    g_variant_unref(child);
    g_variant_unref(boxed);
    g_variant_unref(children);
    return label;
}

int32_t jsti_tray_self_test(char *error, size_t capacity) {
    const gint32 saved = tray.state;
    gchar *saved_summary = g_strdup(tray.summary);
    const char *problem = NULL;
    const gint32 states[] = { JSTI_STATE_IDLE, JSTI_STATE_RECORDING, JSTI_STATE_WORKING };
    for (size_t index = 0; index < G_N_ELEMENTS(states) && problem == NULL; ++index) {
        tray.state = states[index];
        g_free(tray.summary);
        tray.summary = g_strdup("5 sessions · 01m 40s · $0.01");
        GVariant *root = g_variant_ref_sink(layout(MENU_ROOT, TRUE));
        GVariant *children = g_variant_get_child_value(root, 2);
        const gsize count = g_variant_n_children(children);
        g_variant_unref(children);
        gchar *status = count == MENU_COUNT - 1 ? layout_label(root, MENU_STATUS - 1) : NULL;
        gchar *summary = count == MENU_COUNT - 1 ? layout_label(root, MENU_SUMMARY - 1) : NULL;
        gchar *toggle = count == MENU_COUNT - 1 ? layout_label(root, MENU_TOGGLE - 1) : NULL;
        if (count != MENU_COUNT - 1 || g_strcmp0(status, status_label(states[index])) != 0 ||
            g_strcmp0(summary, "5 sessions · 01m 40s · $0.01") != 0 ||
            g_strcmp0(toggle, toggle_label(states[index])) != 0) {
            problem = "the menu does not offer the expected commands.";
        }
        g_free(status);
        g_free(summary);
        g_free(toggle);
        g_variant_unref(root);
    }
    if (problem == NULL) {
        GVariant *pixmaps = g_variant_ref_sink(icon_pixmaps(TRUE));
        GVariant *first = g_variant_get_child_value(pixmaps, 0);
        gint width = 0, height = 0;
        GVariant *bytes = NULL;
        g_variant_get(first, "(ii@ay)", &width, &height, &bytes);
        if (g_variant_n_children(pixmaps) != 3 || width != 22 || height != 22 || g_variant_get_size(bytes) != 22 * 22 * 4) {
            problem = "the icon pixmaps are malformed.";
        }
        g_variant_unref(bytes);
        g_variant_unref(first);
        g_variant_unref(pixmaps);
    }
    tray.state = saved;
    g_free(tray.summary);
    tray.summary = saved_summary;
    if (problem != NULL) {
        jsti_set_error(error, capacity, "Status notifier: %s", problem);
        return -1;
    }
    return 0;
}
