/* The accessibility bus worker: AT-SPI event subscriptions, registry cleanup,
 * metadata attachment, bus connection and focus admission. */
#include "LinuxAtspiInternal.h"

static const char *metadata_events[] = { "object:state-changed", "object:property-change",
    "object:attributes-changed", "object:children-changed", "window:" };
static const char *selection_events[] = { "object:text-selection-changed", "object:text-caret-moved" };

void object_event(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)interface;
    JSTIAtspiTarget *t = data;
    if (!current_target(t) || g_strcmp0(sender, t->owner) != 0) return;
    if (g_strcmp0(signal, "TextChanged") == 0 && g_strcmp0(path, t->path) == 0) {
        if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(siiva{sv})"))) { invalidate(t); return; }
        const gchar *detail; gint start, length; GVariant *wrapped, *properties;
        g_variant_get(parameters, "(&sii@v@a{sv})", &detail, &start, &length, &wrapped, &properties);
        GVariant *value = g_variant_get_variant(wrapped);
        gboolean ok = g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)
            && track(t, detail, start, length, g_variant_get_string(value, NULL));
        g_variant_unref(value); g_variant_unref(wrapped); g_variant_unref(properties);
        if (!ok) invalidate(t);
    } else if (g_strcmp0(signal, "TextCaretMoved") == 0 || g_strcmp0(signal, "TextSelectionChanged") == 0) {
        /* Re-admit the same known control, but never retarget an outstanding read. */
        if (t->session->purpose == SELECTION_SESSION) {
            invalidate(t); queue_target_readmission(t);
        }
    } else {
        /* Privacy, parent, attributes, children, window and lifetime changes
         * make the lease ambiguous. No text is fetched by these callbacks. */
        invalidate(t);
    }
}
CleanupShape registry_schema(const char *xml) {
    GError *error = NULL;
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(xml, &error);
    g_clear_error(&error);
    if (node == NULL) return CLEANUP_UNKNOWN;
    GDBusInterfaceInfo *interface = g_dbus_node_info_lookup_interface(node, REGISTRY);
    GDBusMethodInfo *method = interface != NULL
        ? g_dbus_interface_info_lookup_method(interface, "DeregisterEvent") : NULL;
    CleanupShape shape = CLEANUP_UNKNOWN;
    if (method != NULL && (method->out_args == NULL || method->out_args[0] == NULL)
        && method->in_args != NULL && method->in_args[0] != NULL
        && g_strcmp0(method->in_args[0]->signature, "s") == 0) {
        if (method->in_args[1] == NULL) shape = CLEANUP_EVENT;
        else if (g_strcmp0(method->in_args[1]->signature, "s") == 0 && method->in_args[2] == NULL)
            shape = CLEANUP_APPLICATION;
    }
    method = interface != NULL ? g_dbus_interface_info_lookup_method(interface, "RegisterEvent") : NULL;
    if (method == NULL || (method->out_args != NULL && method->out_args[0] != NULL)
        || method->in_args == NULL || method->in_args[0] == NULL
        || g_strcmp0(method->in_args[0]->signature, "s") != 0 || method->in_args[1] == NULL
        || g_strcmp0(method->in_args[1]->signature, "as") != 0 || method->in_args[2] == NULL
        || g_strcmp0(method->in_args[2]->signature, "s") != 0 || method->in_args[3] != NULL)
        shape = CLEANUP_UNKNOWN;
    g_dbus_node_info_unref(node); return shape;
}
GVariant *cleanup_arguments(CleanupShape shape, const char *event, const char *owner) {
    if (shape == CLEANUP_EVENT) return g_variant_new("(s)", event);
    if (shape == CLEANUP_APPLICATION) return g_variant_new("(ss)", event, owner);
    return NULL;
}
static void cleanup_failed(Session *s) {
    g_atomic_int_set(&s->status, 4); g_atomic_int_set(&s->stopped, TRUE);
    g_cancellable_cancel(s->cancel); g_main_context_wakeup(s->context);
    /* Closing the private connection also removes its registry registrations. */
    g_dbus_connection_close(s->bus, NULL, NULL, NULL);
}
static gboolean registry_cleanup_call(Session *s, const char *method, GVariant *args) {
    if (args == NULL) { cleanup_failed(s); return FALSE; }
    GError *error = NULL;
    /* Only the private worker calls this. No borrowed callback survives
     * teardown; native revocation remains synchronous and never waits here. */
    GVariant *reply = g_dbus_connection_call_sync(s->bus, "org.a11y.atspi.Registry",
        "/org/a11y/atspi/registry", REGISTRY, method, args, G_VARIANT_TYPE("()"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 300, s->cancel, &error);
    gboolean ok = reply != NULL;
    if (reply != NULL) g_variant_unref(reply);
    g_clear_error(&error);
    if (!ok) cleanup_failed(s);
    return ok;
}
void detach(JSTIAtspiTarget *t) {
    Session *s = t->session;
    if (t->signals != NULL) {
        for (guint i = 0; i < t->signals->len; ++i)
            g_dbus_connection_signal_unsubscribe(s->bus, g_array_index(t->signals, guint, i));
        g_array_set_size(t->signals, 0);
    }
    const gboolean had_metadata = t->metadata_registrations > 0;
    if (t->registered && !g_atomic_int_get(&s->stopped)) {
        t->registered = FALSE;
        registry_cleanup_call(s, "DeregisterEvent",
            cleanup_arguments(s->cleanup_shape, "object:text-changed", t->owner));
    }
    for (guint i = 0; i < t->metadata_registrations && !g_atomic_int_get(&s->stopped); ++i) {
        registry_cleanup_call(s, "DeregisterEvent",
            cleanup_arguments(s->cleanup_shape, metadata_events[i], t->owner));
    }
    t->metadata_registrations = 0;
    for (guint i = 0; i < t->selection_registrations && !g_atomic_int_get(&s->stopped); ++i) {
        registry_cleanup_call(s, "DeregisterEvent",
            cleanup_arguments(s->cleanup_shape, selection_events[i], t->owner));
    }
    t->selection_registrations = 0;
    if (had_metadata && s->cleanup_shape == CLEANUP_EVENT && !g_atomic_int_get(&s->stopped)) {
        /* Older prefix-based cleanup can also remove our minimal focus
         * registration. Restore metadata discovery, never a text listener. */
        registry_cleanup_call(s, "RegisterEvent", g_variant_new("(s@ass)",
            "object:state-changed:focused", g_variant_new_strv(NULL, 0), ""));
    }
}
void target_destroy(gpointer data) { jsti_atspi_release(data); }
void subscribe_target(JSTIAtspiTarget *t, const char *interface, const char *signal, const char *path) {
    Session *s = t->session;
    guint id = g_dbus_connection_signal_subscribe(s->bus, t->owner, interface, signal,
        path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, object_event, target_ref(t), target_destroy);
    g_array_append_val(t->signals, id);
}
static gboolean attach_metadata(JSTIAtspiTarget *t, gint64 deadline) {
    t->signals = g_array_new(FALSE, FALSE, sizeof(guint));
    const char *signals[] = { "StateChanged", "PropertyChange", "AttributesChanged", "ChildrenChanged" };
    for (guint j = 0; j < G_N_ELEMENTS(signals); ++j) {
        subscribe_target(t, OBJECT_EVENT, signals[j], t->path);
        for (guint i = 0; i < t->parents->len; ++i)
            subscribe_target(t, OBJECT_EVENT, signals[j], g_ptr_array_index(t->parents, i));
    }
    subscribe_target(t, "org.a11y.atspi.Event.Window", NULL, t->top);
    for (guint i = 0; i < G_N_ELEMENTS(metadata_events); ++i) {
        GVariant *reply = rpc(t->session, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry", REGISTRY,
            "RegisterEvent", g_variant_new("(s@ass)", metadata_events[i], g_variant_new_strv(NULL, 0), t->owner),
            "()", deadline);
        if (reply == NULL) return FALSE;
        g_variant_unref(reply);
        ++t->metadata_registrations;
    }
    if (t->session->purpose == SELECTION_SESSION) {
        subscribe_target(t, OBJECT_EVENT, "TextSelectionChanged", t->path);
        subscribe_target(t, OBJECT_EVENT, "TextCaretMoved", t->path);
        for (guint i = 0; i < G_N_ELEMENTS(selection_events); ++i) {
            GVariant *reply = rpc(t->session, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry", REGISTRY,
                "RegisterEvent", g_variant_new("(s@ass)", selection_events[i], g_variant_new_strv(NULL, 0), t->owner),
                "()", deadline);
            if (reply == NULL) return FALSE;
            g_variant_unref(reply); ++t->selection_registrations;
        }
    }
    return current_target(t);
}

typedef struct { gboolean done; GDBusConnection *bus; } ConnectionReply;
static void accessibility_bus_ready(GObject *object, GAsyncResult *result, gpointer data) {
    (void)object; ConnectionReply *r = data; GError *error = NULL;
    r->bus = g_dbus_connection_new_for_address_finish(result, &error);
    g_clear_error(&error); r->done = TRUE;
}
static gboolean cancel_connect(gpointer data) { g_cancellable_cancel(data); return G_SOURCE_REMOVE; }
static GDBusConnection *connect_bus(Session *s, const char *address) {
    /* Never let GIO autolaunch a bus/helper, activate a screen reader, or
     * contact a remote transport. Missing existing buses mean unavailable. */
    if (address == NULL) address = g_getenv("DBUS_SESSION_BUS_ADDRESS");
    if (address == NULL || !g_str_has_prefix(address, "unix:") || strchr(address, ';') != NULL) return NULL;
    ConnectionReply r = {0};
    GSource *timer = g_timeout_source_new(2000);
    g_source_set_callback(timer, cancel_connect, g_object_ref(s->cancel), g_object_unref);
    g_source_attach(timer, s->context);
    g_dbus_connection_new_for_address(address,
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, s->cancel, accessibility_bus_ready, &r);
    while (!r.done) g_main_context_iteration(s->context, TRUE);
    g_source_destroy(timer); g_source_unref(timer); return r.bus;
}
static gboolean initialize_bus(Session *s) {
    s->bus = connect_bus(s, NULL);
    if (s->bus == NULL) return FALSE;
    const gint64 deadline = g_get_monotonic_time() + BUDGET_US;
    GVariant *enabled = property(s, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled", deadline);
    gboolean allowed = enabled != NULL && g_variant_is_of_type(enabled, G_VARIANT_TYPE_BOOLEAN)
        && g_variant_get_boolean(enabled);
    if (enabled != NULL) g_variant_unref(enabled);
    if (!allowed) return FALSE;
    GVariant *address = rpc(s, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
        NULL, "(s)", deadline);
    if (address == NULL) return FALSE;
    gchar *value; g_variant_get(address, "(s)", &value); g_variant_unref(address);
    g_dbus_connection_close(s->bus, NULL, NULL, NULL);
    g_clear_object(&s->bus);
    s->bus = connect_bus(s, value); g_free(value);
    if (s->bus == NULL) return FALSE;
    g_dbus_connection_set_exit_on_close(s->bus, FALSE);
    GVariant *schema = rpc(s, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry",
        "org.freedesktop.DBus.Introspectable", "Introspect", NULL, "(s)",
        g_get_monotonic_time() + BUDGET_US);
    if (schema == NULL) return FALSE;
    const char *xml; g_variant_get(schema, "(&s)", &xml);
    s->cleanup_shape = strlen(xml) <= 65536 ? registry_schema(xml) : CLEANUP_UNKNOWN;
    g_variant_unref(schema);
    if (s->cleanup_shape == CLEANUP_UNKNOWN) {
        g_atomic_int_set(&s->status, 5);
        return FALSE;
    }
    return TRUE;
}
void queue_admission(Session *s) {
    if (s->admission_queued || g_atomic_int_get(&s->stopped)) return;
    s->admission_queued = TRUE;
    GSource *idle = g_idle_source_new();
    g_source_set_callback(idle, admission, s, NULL); g_source_attach(idle, s->context); g_source_unref(idle);
}
void queue_target_readmission(JSTIAtspiTarget *t) {
    Session *s = t->session;
    if (g_atomic_int_get(&s->stopped) || t != s->admitted || t->focus != s->focus) return;
    g_free(s->pending_owner); g_free(s->pending_path);
    s->pending_owner = g_strdup(t->owner); s->pending_path = g_strdup(t->path);
    if (!s->busy) queue_admission(s);
}
gboolean admission(gpointer data) {
    Session *s = data;
    s->admission_queued = FALSE;
    if (s->busy || g_atomic_int_get(&s->stopped) || s->pending_owner == NULL) return G_SOURCE_REMOVE;
    s->busy = TRUE;
    atspi_lock();
    JSTIAtspiTarget *old = s->admitted; s->admitted = NULL;
    atspi_unlock();
    if (old != NULL) { detach(old); jsti_atspi_release(old); }
    JSTIAtspiTarget *t = g_new0(JSTIAtspiTarget, 1);
    t->refs = 1; t->session = session_ref(s); t->focus = s->focus; t->epoch = s->epoch;
    t->owner = g_steal_pointer(&s->pending_owner); t->path = g_steal_pointer(&s->pending_path);
    t->parents = g_ptr_array_new_with_free_func(g_free);
    const gint64 deadline = g_get_monotonic_time() + BUDGET_US;
    GVariant *pid = rpc(s, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetConnectionUnixProcessID", g_variant_new("(s)", t->owner), "(u)", deadline);
    if (pid != NULL) { g_variant_get(pid, "(u)", &t->pid); g_variant_unref(pid); }
    gboolean ok = external_pid(t->pid) && identity(t, TRUE, deadline)
        && attach_metadata(t, deadline);
    atspi_lock();
    ok = ok && current_target(t);
    s->admitted = ok ? target_ref(t) : NULL;
    atspi_unlock();
    if (!ok) { invalidate(t); detach(t); }
    jsti_atspi_release(t); s->busy = FALSE;
    if (s->pending_owner != NULL && !g_atomic_int_get(&s->stopped)) queue_admission(s);
    return G_SOURCE_REMOVE;
}
static void focus_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)interface; (void)signal;
    Session *s = data;
    if (g_atomic_int_get(&s->stopped)) return;
    invalidate_focus(s);
    g_clear_pointer(&s->pending_owner, g_free); g_clear_pointer(&s->pending_path, g_free);
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(siiva{sv})"))
        || sender == NULL || sender[0] != ':' || !g_variant_is_object_path(path)) return;
    gint focused; g_variant_get_child(parameters, 1, "i", &focused);
    if (focused != 1) return;
    s->pending_owner = g_strdup(sender); s->pending_path = g_strdup(path);
    queue_admission(s);
}
void owner_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    Session *s = data;
    const gchar *name, *old, *now;
    g_variant_get(parameters, "(&s&s&s)", &name, &old, &now);
    if (s->admitted != NULL && g_strcmp0(name, s->admitted->owner) == 0 && old[0] != '\0'
        && g_strcmp0(old, now) != 0) invalidate_focus(s);
}
void bus_closed(GDBusConnection *bus, gboolean remote, GError *error, gpointer data) {
    (void)bus; (void)remote; (void)error;
    Session *s = data;
    if (g_atomic_int_get(&s->status) != 4 && g_atomic_int_get(&s->status) != 5)
        g_atomic_int_set(&s->status, 3);
    invalidate_focus(s);
    g_atomic_int_set(&s->stopped, TRUE); g_cancellable_cancel(s->cancel);
}
gpointer worker(gpointer data) {
    Session *s = data;
    g_main_context_push_thread_default(s->context);
    if (initialize_bus(s) && !g_atomic_int_get(&s->stopped)) {
        g_signal_connect(s->bus, "closed", G_CALLBACK(bus_closed), s);
        s->focus_signal = g_dbus_connection_signal_subscribe(s->bus, NULL, OBJECT_EVENT, "StateChanged",
            NULL, "focused", G_DBUS_SIGNAL_FLAGS_NONE, focus_changed, s, NULL);
        s->owner_signal = g_dbus_connection_signal_subscribe(s->bus, "org.freedesktop.DBus",
            "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", NULL,
            G_DBUS_SIGNAL_FLAGS_NONE, owner_changed, s, NULL);
        GVariant *reply = rpc(s, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry", REGISTRY,
            "RegisterEvent", g_variant_new("(s@ass)", "object:state-changed:focused",
                g_variant_new_strv(NULL, 0), ""), "()", g_get_monotonic_time() + BUDGET_US);
        if (reply != NULL) { g_variant_unref(reply); g_atomic_int_set(&s->status, 2); }
        else g_atomic_int_set(&s->status, 3);
        while (!g_atomic_int_get(&s->stopped) && g_atomic_int_get(&s->status) == 2)
            g_main_context_iteration(s->context, TRUE);
    } else if (g_atomic_int_get(&s->status) != 5) g_atomic_int_set(&s->status, 3);
    atspi_lock();
    g_atomic_int_set(&s->stopped, TRUE);
    atspi_unlock();
    invalidate_focus(s);
    atspi_lock();
    JSTIAtspiTarget *t = s->admitted; s->admitted = NULL;
    atspi_unlock();
    if (t != NULL) { detach(t); jsti_atspi_release(t); }
    if (s->bus != NULL) {
        if (s->focus_signal) g_dbus_connection_signal_unsubscribe(s->bus, s->focus_signal);
        if (s->owner_signal) g_dbus_connection_signal_unsubscribe(s->bus, s->owner_signal);
        s->focus_signal = s->owner_signal = 0;
    }
    /* Resolve already-enqueued heap requests before dropping the context.
     * Stopped requests do no IPC and cannot start a new admission. */
    while (g_main_context_pending(s->context)) g_main_context_iteration(s->context, FALSE);
    if (s->bus != NULL) {
        if (s->focus_signal) g_dbus_connection_signal_unsubscribe(s->bus, s->focus_signal);
        if (s->owner_signal) g_dbus_connection_signal_unsubscribe(s->bus, s->owner_signal);
        g_signal_handlers_disconnect_by_data(s->bus, s);
        g_dbus_connection_close(s->bus, NULL, NULL, NULL);
        g_clear_object(&s->bus);
    }
    while (g_main_context_pending(s->context)) g_main_context_iteration(s->context, FALSE);
    g_clear_pointer(&s->pending_owner, g_free); g_clear_pointer(&s->pending_path, g_free);
    g_main_context_pop_thread_default(s->context); session_unref(s); return NULL;
}
