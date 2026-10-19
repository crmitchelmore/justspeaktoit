#include "include/LinuxAtspi.h"
#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

/* Accessibility work has a private context. No GTK, audio or recording-start
 * caller waits for discovery. An admitted target is metadata only until consented
 * output; all captured text stays inside its bounded, short-lived lease. */
#define ACCESSIBLE "org.a11y.atspi.Accessible"
#define TEXT "org.a11y.atspi.Text"
#define EDITABLE "org.a11y.atspi.EditableText"
#define OBJECT_EVENT "org.a11y.atspi.Event.Object"
#define REGISTRY "org.a11y.atspi.Registry"
#define LIMIT 8192
#define GUARD 32
#define BUDGET_US (2500 * 1000)

typedef struct Session Session;
typedef enum { CLEANUP_UNKNOWN, CLEANUP_EVENT, CLEANUP_APPLICATION } CleanupShape;
typedef enum { FRESH, DISPATCHED, INSERTED, SAMPLING, FINISHED } Phase;
struct JSTIAtspiTarget {
    gint refs, cancelled, captured, dispatched;
    Session *session;
    guint64 focus, epoch;
    gchar *owner, *path, *app, *top;
    GPtrArray *parents;
    guint32 pid;
    Phase phase;
    gint start, end, count, initial_count, insert_events, mutations;
    gchar *original, *tracked, *left, *right;
    gboolean left_edge, right_edge;
    GArray *signals;
    gboolean registered;
    guint metadata_registrations;
};
struct Session {
    gint refs, stopped, status;
    GMainContext *context;
    GDBusConnection *bus;
    GCancellable *cancel;
    guint focus_signal, owner_signal;
    guint64 focus, epoch;
    gboolean busy, admission_queued;
    CleanupShape cleanup_shape;
    JSTIAtspiTarget *active_target;
    JSTIAtspiTarget *admitted;
    gchar *pending_owner, *pending_path;
};
static GMutex state_lock;
static Session *current;
static guint64 next_epoch;
typedef struct { guint64 generation, offer; gboolean exhausted; } ConsentLedger;
static ConsentLedger consent;
static const char *metadata_events[] = { "object:state-changed", "object:property-change",
    "object:attributes-changed", "object:children-changed", "window:" };

static Session *session_ref(Session *s) { g_atomic_int_inc(&s->refs); return s; }
static void session_unref(Session *s) {
    if (!g_atomic_int_dec_and_test(&s->refs)) return;
    g_clear_object(&s->cancel);
    g_main_context_unref(s->context);
    g_free(s);
}
static JSTIAtspiTarget *target_ref(JSTIAtspiTarget *t) { g_atomic_int_inc(&t->refs); return t; }
void jsti_atspi_release(JSTIAtspiTarget *t) {
    if (t == NULL || !g_atomic_int_dec_and_test(&t->refs)) return;
    session_unref(t->session);
    g_free(t->owner); g_free(t->path); g_free(t->app); g_free(t->top);
    g_ptr_array_unref(t->parents);
    if (t->signals != NULL) g_array_unref(t->signals);
    g_free(t->original); g_free(t->tracked); g_free(t->left); g_free(t->right); g_free(t);
}
static gboolean current_target(JSTIAtspiTarget *t) {
    return !g_atomic_int_get(&t->cancelled) && !g_atomic_int_get(&t->session->stopped)
        && t->epoch == t->session->epoch && t->focus == t->session->focus;
}
static void invalidate(JSTIAtspiTarget *t) {
    if (t != NULL) g_atomic_int_set(&t->cancelled, TRUE);
}
static void invalidate_focus(Session *s) {
    /* The lock protects only publication/capture, never IPC. */
    g_mutex_lock(&state_lock);
    ++s->focus;
    invalidate(s->admitted);
    g_mutex_unlock(&state_lock);
}

typedef struct { gboolean done; GVariant *reply; } Reply;
static void replied(GObject *object, GAsyncResult *result, gpointer data) {
    Reply *r = data;
    GError *error = NULL;
    r->reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
    g_clear_error(&error); /* Never expose provider messages containing field data. */
    r->done = TRUE;
}
static GVariant *rpc(
    Session *s, const char *owner, const char *path, const char *interface,
    const char *method, GVariant *args, const char *reply_type, gint64 deadline
) {
    g_mutex_lock(&state_lock);
    if (g_atomic_int_get(&s->stopped) || g_get_monotonic_time() >= deadline
        || (s->active_target != NULL && g_atomic_int_get(&s->active_target->cancelled))) {
        g_mutex_unlock(&state_lock);
        if (args != NULL) g_variant_unref(g_variant_ref_sink(args));
        return NULL;
    }
    Reply reply = {0};
    const gint remaining = (gint)((deadline - g_get_monotonic_time()) / 1000);
    g_dbus_connection_call(s->bus, owner, path, interface, method, args, G_VARIANT_TYPE(reply_type),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, MAX(1, MIN(remaining, 400)), s->cancel, replied, &reply);
    g_mutex_unlock(&state_lock);
    /* The async call has a finite timeout and cancellable. Retain the stack
     * callback until completion even when ownership was revoked meanwhile. */
    while (!reply.done) g_main_context_iteration(s->context, TRUE);
    return reply.reply;
}
static GVariant *property(Session *s, const char *owner, const char *path,
    const char *interface, const char *name, gint64 deadline) {
    GVariant *reply = rpc(s, owner, path, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", interface, name), "(v)", deadline);
    if (reply == NULL) return NULL;
    GVariant *wrapped = g_variant_get_child_value(reply, 0);
    GVariant *value = g_variant_get_variant(wrapped);
    g_variant_unref(wrapped); g_variant_unref(reply); return value;
}
static gboolean integer_property(JSTIAtspiTarget *t, const char *name, gint *out, gint64 deadline) {
    GVariant *v = property(t->session, t->owner, t->path, TEXT, name, deadline);
    gboolean ok = v != NULL && g_variant_is_of_type(v, G_VARIANT_TYPE_INT32);
    if (ok) *out = g_variant_get_int32(v);
    if (v != NULL) g_variant_unref(v);
    return ok && current_target(t);
}

static gboolean bitmap(GVariant *array, guint64 *bits) {
    if (!g_variant_is_of_type(array, G_VARIANT_TYPE("au")) || g_variant_n_children(array) != 2) return FALSE;
    guint32 a, b; g_variant_get_child(array, 0, "u", &a); g_variant_get_child(array, 1, "u", &b);
    *bits = (guint64)a | ((guint64)b << 32); return TRUE;
}
static gboolean safe_state(guint64 bits) {
    const guint64 required = ((guint64)1 << 7) | ((guint64)1 << 8) | ((guint64)1 << 12)
        | ((guint64)1 << 24) | ((guint64)1 << 25) | ((guint64)1 << 30);
    const guint64 forbidden = ((guint64)1 << 0) | ((guint64)1 << 6) | ((guint64)1 << 27)
        | ((guint64)1 << 28) | ((guint64)1 << 43);
    return (bits & required) == required && (bits & forbidden) == 0;
}
static gboolean ordinary_role(guint32 role) { return role == 61 || role == 79; }
static gboolean external_pid(guint32 pid) { return pid > 0 && pid != (guint32)getpid(); }
static gboolean state_for(Session *s, const char *owner, const char *path, guint64 *bits, gint64 deadline) {
    GVariant *reply = rpc(s, owner, path, ACCESSIBLE, "GetState", NULL, "(au)", deadline);
    if (reply == NULL) return FALSE;
    GVariant *array = g_variant_get_child_value(reply, 0);
    gboolean ok = bitmap(array, bits);
    g_variant_unref(array); g_variant_unref(reply); return ok;
}
static gboolean role_for(Session *s, const char *owner, const char *path, guint32 *role, gint64 deadline) {
    GVariant *reply = rpc(s, owner, path, ACCESSIBLE, "GetRole", NULL, "(u)", deadline);
    if (reply == NULL) return FALSE;
    g_variant_get(reply, "(u)", role); g_variant_unref(reply); return TRUE;
}
static gchar *reference_path(GVariant *value, const char *owner) {
    if (value == NULL || !g_variant_is_of_type(value, G_VARIANT_TYPE("(so)"))) return NULL;
    const gchar *name, *path; g_variant_get(value, "(&s&o)", &name, &path);
    if (g_strcmp0(name, owner) != 0 || g_strcmp0(path, "/org/a11y/atspi/null") == 0) return NULL;
    return g_strdup(path);
}
static gboolean identity(JSTIAtspiTarget *t, gboolean admit, gint64 deadline) {
    Session *s = t->session;
    guint32 role; guint64 bits;
    if (!current_target(t) || !role_for(s, t->owner, t->path, &role, deadline)
        || !ordinary_role(role) || !state_for(s, t->owner, t->path, &bits, deadline)
        || !safe_state(bits) || !current_target(t)) return FALSE;
    GVariant *reply = rpc(s, t->owner, t->path, ACCESSIBLE, "GetInterfaces", NULL, "(as)", deadline);
    if (reply == NULL) return FALSE;
    gchar **interfaces; g_variant_get(reply, "(^as)", &interfaces);
    gboolean text = FALSE, editable = FALSE;
    for (guint i = 0; interfaces[i] != NULL; ++i) {
        text |= g_strcmp0(interfaces[i], TEXT) == 0;
        editable |= g_strcmp0(interfaces[i], EDITABLE) == 0;
    }
    g_strfreev(interfaces); g_variant_unref(reply);
    if (!text || !editable) return FALSE;
    reply = rpc(s, t->owner, t->path, ACCESSIBLE, "GetApplication", NULL, "((so))", deadline);
    if (reply == NULL) return FALSE;
    GVariant *app_ref = g_variant_get_child_value(reply, 0);
    gchar *app = reference_path(app_ref, t->owner);
    g_variant_unref(app_ref); g_variant_unref(reply);
    if (app == NULL) return FALSE;
    gboolean ok = admit || g_strcmp0(app, t->app) == 0;
    if (admit) t->app = g_strdup(app);
    gchar *path = g_strdup(t->path);
    guint index = 0;
    gboolean found_top = FALSE;
    while (ok && g_strcmp0(path, app) != 0 && index < 16) {
        GVariant *parent_ref = property(s, t->owner, path, ACCESSIBLE, "Parent", deadline);
        gchar *parent = reference_path(parent_ref, t->owner);
        if (parent_ref != NULL) g_variant_unref(parent_ref);
        g_free(path); path = parent;
        if (path == NULL) { ok = FALSE; break; }
        if (admit) g_ptr_array_add(t->parents, g_strdup(path));
        else if (index >= t->parents->len || g_strcmp0(path, g_ptr_array_index(t->parents, index)) != 0)
            ok = FALSE;
        ++index;
        if (!role_for(s, t->owner, path, &role, deadline)
            || !state_for(s, t->owner, path, &bits, deadline)
            || (bits & (((guint64)1 << 6) | ((guint64)1 << 27))) != 0) { ok = FALSE; break; }
        if (!found_top && (role == 16 || role == 23 || role == 69)) {
            found_top = TRUE;
            if ((bits & ((guint64)1 << 1)) == 0) ok = FALSE;
            if (admit) t->top = g_strdup(path);
            else if (g_strcmp0(path, t->top) != 0) ok = FALSE;
        }
    }
    ok = ok && found_top && g_strcmp0(path, app) == 0 && (admit || index == t->parents->len);
    g_free(path); g_free(app);
    return ok && current_target(t);
}
static gboolean collapsed(JSTIAtspiTarget *t, gint *caret, gint *count, gint64 deadline) {
    GVariant *reply = rpc(t->session, t->owner, t->path, TEXT, "GetNSelections", NULL, "(i)", deadline);
    gint selections = -1;
    if (reply != NULL) { g_variant_get(reply, "(i)", &selections); g_variant_unref(reply); }
    return selections == 0 && integer_property(t, "CharacterCount", count, deadline)
        && integer_property(t, "CaretOffset", caret, deadline)
        && *count >= 0 && *count <= LIMIT && *caret >= 0 && *caret <= *count && current_target(t);
}
static gchar *read_text(JSTIAtspiTarget *t, gint start, gint end, gint64 deadline) {
    if (!current_target(t) || start < 0 || end < start || end - start > LIMIT) return NULL;
    guint32 role; guint64 bits;
    if (!role_for(t->session, t->owner, t->path, &role, deadline) || !ordinary_role(role)
        || !state_for(t->session, t->owner, t->path, &bits, deadline) || !safe_state(bits)
        || !current_target(t)) return NULL;
    GVariant *reply = rpc(t->session, t->owner, t->path, TEXT, "GetText",
        g_variant_new("(ii)", start, end), "(s)", deadline);
    if (reply == NULL) return NULL;
    const char *value; g_variant_get(reply, "(&s)", &value);
    gchar *copy = strlen(value) <= LIMIT * 4 && g_utf8_validate(value, -1, NULL)
        && g_utf8_strlen(value, -1) == end - start && current_target(t) ? g_strdup(value) : NULL;
    g_variant_unref(reply); return copy;
}

/* Pure character-offset accounting. Boundary edits cannot prove whether a
 * change belongs to our span; only strict interior edits are retained. */
static gboolean operation(const char *detail, const char *name) {
    if (g_strcmp0(detail, name) == 0) return TRUE;
    const size_t length = strlen(name);
    return strncmp(detail, name, length) == 0 && detail[length] == ':'
        && (g_strcmp0(detail + length + 1, "system") == 0 || g_strcmp0(detail + length + 1, "user") == 0);
}
static gboolean track(JSTIAtspiTarget *t, const char *detail, gint start, gint length, const char *text) {
    if (length <= 0 || length > LIMIT || start < 0 || strlen(text) > LIMIT * 4
        || !g_utf8_validate(text, -1, NULL) || g_utf8_strlen(text, -1) != length) return FALSE;
    if (t->phase == DISPATCHED) {
        if (!operation(detail, "insert") || t->insert_events != 0 || start != t->start
            || length != t->end - t->start || g_strcmp0(text, t->original) != 0) return FALSE;
        ++t->insert_events; return TRUE;
    }
    if (t->phase != INSERTED && t->phase != SAMPLING) return FALSE;
    if (start <= t->start || start >= t->end || ++t->mutations > 128) return FALSE;
    if (t->tracked == NULL || g_utf8_strlen(t->tracked, -1) != t->end - t->start) return FALSE;
    gchar *at = g_utf8_offset_to_pointer(t->tracked, start - t->start);
    gchar *next = NULL;
    if (operation(detail, "insert")) {
        if (t->count + length > LIMIT) return FALSE;
        gchar *prefix = g_strndup(t->tracked, (gsize)(at - t->tracked));
        next = g_strconcat(prefix, text, at, NULL); g_free(prefix);
        t->end += length; t->count += length;
    } else if (operation(detail, "delete")) {
        if (length >= t->end - start) return FALSE;
        gchar *past = g_utf8_offset_to_pointer(at, length);
        if (strlen(text) != (gsize)(past - at) || strncmp(at, text, (gsize)(past - at)) != 0) return FALSE;
        gchar *prefix = g_strndup(t->tracked, (gsize)(at - t->tracked));
        next = g_strconcat(prefix, past, NULL); g_free(prefix);
        t->end -= length; t->count -= length;
    } else return FALSE;
    g_free(t->tracked); t->tracked = next;
    return TRUE;
}
static void object_event(GDBusConnection *bus, const gchar *sender, const gchar *path,
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
        /* Final caret/selection checks are independent of mutation origin. */
    } else {
        /* Privacy, parent, attributes, children, window and lifetime changes
         * make the lease ambiguous. No text is fetched by these callbacks. */
        invalidate(t);
    }
}
static CleanupShape registry_schema(const char *xml) {
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
static GVariant *cleanup_arguments(CleanupShape shape, const char *event, const char *owner) {
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
static void detach(JSTIAtspiTarget *t) {
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
    if (had_metadata && s->cleanup_shape == CLEANUP_EVENT && !g_atomic_int_get(&s->stopped)) {
        /* Older prefix-based cleanup can also remove our minimal focus
         * registration. Restore metadata discovery, never a text listener. */
        registry_cleanup_call(s, "RegisterEvent", g_variant_new("(s@ass)",
            "object:state-changed:focused", g_variant_new_strv(NULL, 0), ""));
    }
}
static void target_destroy(gpointer data) { jsti_atspi_release(data); }
static void subscribe_target(JSTIAtspiTarget *t, const char *interface, const char *signal, const char *path) {
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
static gboolean admission(gpointer data);
static void queue_admission(Session *s) {
    if (s->admission_queued || g_atomic_int_get(&s->stopped)) return;
    s->admission_queued = TRUE;
    GSource *idle = g_idle_source_new();
    g_source_set_callback(idle, admission, s, NULL); g_source_attach(idle, s->context); g_source_unref(idle);
}
static gboolean admission(gpointer data) {
    Session *s = data;
    s->admission_queued = FALSE;
    if (s->busy || g_atomic_int_get(&s->stopped) || s->pending_owner == NULL) return G_SOURCE_REMOVE;
    s->busy = TRUE;
    g_mutex_lock(&state_lock);
    JSTIAtspiTarget *old = s->admitted; s->admitted = NULL;
    g_mutex_unlock(&state_lock);
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
    g_mutex_lock(&state_lock);
    ok = ok && current_target(t);
    s->admitted = ok ? target_ref(t) : NULL;
    g_mutex_unlock(&state_lock);
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
static void owner_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    Session *s = data;
    const gchar *name, *old, *now;
    g_variant_get(parameters, "(&s&s&s)", &name, &old, &now);
    if (s->admitted != NULL && g_strcmp0(name, s->admitted->owner) == 0 && old[0] != '\0'
        && g_strcmp0(old, now) != 0) invalidate_focus(s);
}
static void bus_closed(GDBusConnection *bus, gboolean remote, GError *error, gpointer data) {
    (void)bus; (void)remote; (void)error;
    Session *s = data;
    if (g_atomic_int_get(&s->status) != 4 && g_atomic_int_get(&s->status) != 5)
        g_atomic_int_set(&s->status, 3);
    invalidate_focus(s);
    g_atomic_int_set(&s->stopped, TRUE); g_cancellable_cancel(s->cancel);
}
static gpointer worker(gpointer data) {
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
    g_mutex_lock(&state_lock);
    g_atomic_int_set(&s->stopped, TRUE);
    g_mutex_unlock(&state_lock);
    invalidate_focus(s);
    g_mutex_lock(&state_lock);
    JSTIAtspiTarget *t = s->admitted; s->admitted = NULL;
    g_mutex_unlock(&state_lock);
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
static guint64 advance_consent(ConsentLedger *ledger, gboolean offer) {
    if (ledger->exhausted || ledger->generation == G_MAXUINT64) {
        ledger->exhausted = TRUE; ledger->offer = 0; return 0;
    }
    ++ledger->generation; ledger->offer = offer ? ledger->generation : 0;
    return ledger->generation;
}
static gboolean consent_action_current(const ConsentLedger *ledger, gboolean allowed, guint64 token) {
    return !ledger->exhausted && token != 0 && token == ledger->generation
        && (!allowed || token == ledger->offer);
}
static Session *revoke_current_locked(void) {
    Session *old = current; current = NULL;
    if (old != NULL) {
        g_atomic_int_set(&old->stopped, TRUE);
        invalidate(old->admitted);
        g_cancellable_cancel(old->cancel); g_main_context_wakeup(old->context);
    }
    return old;
}
uint64_t jsti_atspi_offer_local_consent(void) {
    g_mutex_lock(&state_lock);
    Session *old = revoke_current_locked();
    guint64 token = advance_consent(&consent, TRUE);
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return token;
}
uint64_t jsti_atspi_revoke_local_consent(void) {
    g_mutex_lock(&state_lock);
    Session *old = revoke_current_locked();
    guint64 token = advance_consent(&consent, FALSE);
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return token;
}
int32_t jsti_atspi_consent_action_is_current(int32_t allowed, uint64_t token) {
    g_mutex_lock(&state_lock);
    gboolean valid = consent_action_current(&consent, allowed != 0, token);
    g_mutex_unlock(&state_lock); return valid ? 1 : 0;
}
int32_t jsti_atspi_observational_consent(int32_t allowed, uint64_t token) {
    g_mutex_lock(&state_lock);
    if ((token == 0 && allowed) || (token != 0 && !consent_action_current(&consent, allowed != 0, token))) {
        g_mutex_unlock(&state_lock); return 0;
    }
    if (token == 0) advance_consent(&consent, FALSE);
    else consent.offer = 0;
    Session *old = revoke_current_locked();
    if (allowed) {
        Session *s = g_new0(Session, 1);
        s->refs = 1; s->epoch = ++next_epoch; s->status = 1;
        s->context = g_main_context_new(); s->cancel = g_cancellable_new(); current = s;
        GThread *thread = g_thread_new("correction-atspi", worker, session_ref(s)); g_thread_unref(thread);
    }
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return 1;
}
int32_t jsti_atspi_observational_status(void) {
    g_mutex_lock(&state_lock);
    int status = current != NULL ? g_atomic_int_get(&current->status) : 0;
    g_mutex_unlock(&state_lock); return status;
}
JSTIAtspiTarget *jsti_atspi_capture(void) {
    g_mutex_lock(&state_lock);
    JSTIAtspiTarget *t = current != NULL ? current->admitted : NULL;
    if (t != NULL && current_target(t) && g_atomic_int_compare_and_exchange(&t->captured, 0, 1)) target_ref(t);
    else t = NULL;
    g_mutex_unlock(&state_lock); return t;
}
int32_t jsti_atspi_is_current(JSTIAtspiTarget *t) {
    if (t == NULL) return 0;
    g_mutex_lock(&state_lock);
    gboolean valid = current_target(t);
    g_mutex_unlock(&state_lock); return valid ? 1 : 0;
}

typedef struct {
    gint refs;
    GMutex lock;
    GCond changed;
    gboolean done;
    JSTIAtspiTarget *target;
    gint kind, result;
    gchar *input, *output;
} Request;
static void request_free(gpointer data) {
    Request *r = data;
    if (!g_atomic_int_dec_and_test(&r->refs)) return;
    jsti_atspi_release(r->target); g_free(r->input); g_free(r->output);
    g_mutex_clear(&r->lock); g_cond_clear(&r->changed); g_free(r);
}
static gboolean guards(JSTIAtspiTarget *t, gint64 deadline) {
    const gint left_len = (gint)g_utf8_strlen(t->left, -1);
    const gint right_len = (gint)g_utf8_strlen(t->right, -1);
    if ((t->left_edge && t->start != left_len) || (t->right_edge && t->end + right_len != t->count))
        return FALSE;
    gchar *left = read_text(t, t->start - left_len, t->start, deadline);
    gchar *right = read_text(t, t->end, t->end + right_len, deadline);
    gboolean ok = left != NULL && right != NULL && g_strcmp0(left, t->left) == 0
        && g_strcmp0(right, t->right) == 0;
    g_free(left); g_free(right); return ok;
}
static gboolean insertion_observed(JSTIAtspiTarget *t, gboolean accepted, gint caret, gint count) {
    return current_target(t) && accepted && t->phase == DISPATCHED && t->insert_events == 1
        && caret == t->end && count == t->initial_count + t->end - t->start;
}
static gint insert(JSTIAtspiTarget *t, const gchar *text, gint64 deadline) {
    Session *s = t->session;
    gint caret, count;
    if (g_atomic_int_get(&t->dispatched)) return -1;
    if (t->phase != FRESH || !g_utf8_validate(text, -1, NULL) || strlen(text) > LIMIT * 4
        || text[0] == '\0' || !identity(t, FALSE, deadline) || !collapsed(t, &caret, &count, deadline)) return 0;
    const gint length = (gint)g_utf8_strlen(text, -1);
    if (count + length > LIMIT) return 0;
    t->start = caret; t->end = caret; t->count = count; t->initial_count = count;
    t->left = read_text(t, MAX(0, caret - GUARD), caret, deadline);
    t->right = read_text(t, caret, MIN(count, caret + GUARD), deadline);
    if (t->left == NULL || t->right == NULL) return 0;
    t->left_edge = caret <= GUARD; t->right_edge = count - caret <= GUARD;
    t->original = g_strdup(text);
    subscribe_target(t, OBJECT_EVENT, "TextChanged", t->path);
    GVariant *reply = rpc(s, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry", REGISTRY,
        "RegisterEvent", g_variant_new("(s@ass)", "object:text-changed", g_variant_new_strv(NULL, 0), t->owner),
        "()", deadline);
    if (reply == NULL) { detach(t); return 0; }
    g_variant_unref(reply); t->registered = TRUE;
    /* Establish a final preflight after listener registration. */
    gint final_caret, final_count;
    if (!identity(t, FALSE, deadline) || !collapsed(t, &final_caret, &final_count, deadline)
        || final_caret != caret || final_count != count || !guards(t, deadline) || !current_target(t)) {
        detach(t); return 0;
    }
    t->phase = DISPATCHED; g_atomic_int_set(&t->dispatched, TRUE); t->end += length;
    reply = rpc(s, t->owner, t->path, EDITABLE, "InsertText",
        g_variant_new("(isi)", caret, text, (gint)strlen(text)), "(b)", deadline);
    gboolean accepted = FALSE;
    if (reply != NULL) { g_variant_get(reply, "(b)", &accepted); g_variant_unref(reply); }
    /* No retry/fallback is safe beyond DISPATCHED, even on FALSE. */
    if (!accepted || !current_target(t)) return -1;
    /* A bounded round-trip lets already-enqueued native events drain. No
     * invented revision/token: matching observations remain non-causal. */
    if (!identity(t, FALSE, deadline) || !collapsed(t, &final_caret, &final_count, deadline)
        || !insertion_observed(t, accepted, final_caret, final_count)) return -1;
    t->count = final_count;
    gchar *observed = read_text(t, t->start, t->end, deadline);
    gboolean ok = observed != NULL && g_strcmp0(observed, text) == 0 && guards(t, deadline)
        && identity(t, FALSE, deadline) && t->insert_events == 1 && current_target(t);
    g_free(observed);
    if (!ok) return -1;
    t->tracked = g_strdup(text); t->phase = INSERTED; return 1;
}
static gboolean execute(gpointer data) {
    Request *r = data;
    JSTIAtspiTarget *t = r->target; Session *s = t->session;
    gint result = r->kind == 0 && t->phase >= DISPATCHED ? -1 : 0;
    if (current_target(t) && !s->busy) {
        s->busy = TRUE;
        s->active_target = t;
        const gint64 deadline = g_get_monotonic_time() + BUDGET_US;
        if (r->kind == 0) result = insert(t, r->input, deadline);
        else if (r->kind == 1) {
            if (t->phase == INSERTED && g_strcmp0(r->input, t->original) == 0
                && identity(t, FALSE, deadline)) { t->phase = SAMPLING; result = 1; }
        } else if (r->kind == 2 && t->phase == SAMPLING && identity(t, FALSE, deadline)) {
            gint caret, count;
            const gint mutation = t->mutations;
            if (collapsed(t, &caret, &count, deadline) && count == t->count && caret >= t->start
                && caret <= t->end && guards(t, deadline)) {
                r->output = read_text(t, t->start, t->end, deadline);
                if (r->output != NULL && g_strcmp0(r->output, t->tracked) == 0
                    && identity(t, FALSE, deadline) && mutation == t->mutations
                    && current_target(t)) result = 1;
            }
            t->phase = FINISHED;
        }
        if (result != 1) { invalidate(t); detach(t); }
        s->active_target = NULL;
        s->busy = FALSE;
        if (s->pending_owner != NULL && !g_atomic_int_get(&s->stopped)) queue_admission(s);
    }
    g_mutex_lock(&r->lock); r->result = result; r->done = TRUE;
    g_cond_broadcast(&r->changed); g_mutex_unlock(&r->lock); return G_SOURCE_REMOVE;
}
static gint submit(JSTIAtspiTarget *t, gint kind, const char *input, char *out, size_t capacity) {
    if (t == NULL) return 0;
    g_mutex_lock(&state_lock);
    if (g_atomic_int_get(&t->cancelled) || g_atomic_int_get(&t->session->stopped)) {
        g_mutex_unlock(&state_lock);
        return kind == 0 && g_atomic_int_get(&t->dispatched) ? -1 : 0;
    }
    Request *r = g_new0(Request, 1);
    r->refs = 2; g_mutex_init(&r->lock); g_cond_init(&r->changed);
    r->target = target_ref(t); r->kind = kind; r->input = g_strdup(input);
    /* Always enqueue: invoke_full can run inline on a caller acquiring an idle
     * context. These operations must run exclusively on the private worker. */
    GSource *source = g_idle_source_new();
    g_source_set_callback(source, execute, r, request_free);
    g_source_attach(source, t->session->context); g_source_unref(source);
    g_mutex_unlock(&state_lock);
    g_mutex_lock(&r->lock);
    const gint64 until = g_get_monotonic_time() + BUDGET_US + 500000;
    while (!r->done && g_cond_wait_until(&r->changed, &r->lock, until)) {}
    gint result = r->done ? r->result : kind == 0 ? -1 : 0;
    if (!r->done) invalidate(t);
    if (result == 1 && kind == 2) {
        if (r->output == NULL || strlen(r->output) >= capacity) result = 0;
        else g_strlcpy(out, r->output, capacity);
    }
    g_mutex_unlock(&r->lock); request_free(r); return result;
}
static gboolean cancel_lease(gpointer data) {
    JSTIAtspiTarget *t = data; Session *s = t->session;
    detach(t);
    /* A new lease may revalidate the SAME known control off the hot path.
     * This never discovers a late arbitrary focused field or reuses a span. */
    if (!g_atomic_int_get(&s->stopped) && t == s->admitted && t->focus == s->focus) {
        g_free(s->pending_owner); g_free(s->pending_path);
        s->pending_owner = g_strdup(t->owner); s->pending_path = g_strdup(t->path);
        if (!s->busy) queue_admission(s);
    }
    return G_SOURCE_REMOVE;
}
void jsti_atspi_cancel(JSTIAtspiTarget *t) {
    if (t == NULL) return;
    invalidate(t);
    g_mutex_lock(&state_lock);
    if (g_atomic_int_get(&t->session->stopped)) { g_mutex_unlock(&state_lock); return; }
    GSource *source = g_idle_source_new();
    g_source_set_callback(source, cancel_lease, target_ref(t), target_destroy);
    g_source_attach(source, t->session->context); g_source_unref(source);
    g_mutex_unlock(&state_lock);
}
int32_t jsti_atspi_insert(JSTIAtspiTarget *t, const char *text) { return submit(t, 0, text, NULL, 0); }
int32_t jsti_atspi_begin(JSTIAtspiTarget *t, const char *text) { return submit(t, 1, text, NULL, 0); }
int32_t jsti_atspi_read(JSTIAtspiTarget *t, char *out, size_t capacity) { return submit(t, 2, NULL, out, capacity); }

static gboolean bitmap_contract(void) {
    GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("au"));
    const guint64 valid = ((guint64)1 << 7) | ((guint64)1 << 8) | ((guint64)1 << 12)
        | ((guint64)1 << 24) | ((guint64)1 << 25) | ((guint64)1 << 30);
    g_variant_builder_add(&b, "u", (guint32)valid); g_variant_builder_add(&b, "u", 0u);
    GVariant *array = g_variant_ref_sink(g_variant_builder_end(&b)); guint64 bits = 0;
    gboolean ok = bitmap(array, &bits) && bits == valid && safe_state(bits)
        && !safe_state(bits | ((guint64)1 << 43)) && !safe_state(bits | ((guint64)1 << 6))
        && !safe_state(bits | ((guint64)1 << 27)) && !safe_state(bits & ~((guint64)1 << 7))
        && !ordinary_role(40) && !ordinary_role(0) && !ordinary_role(67) && !ordinary_role(999)
        && ordinary_role(79) && ordinary_role(61) && !external_pid(0) && !external_pid((guint32)getpid());
    g_variant_unref(array);
    const guint32 short_array[] = { 79 };
    array = g_variant_ref_sink(g_variant_new_fixed_array(G_VARIANT_TYPE_UINT32, short_array, 1, sizeof(guint32)));
    ok &= !bitmap(array, &bits); g_variant_unref(array);
    const char *unicode = "\xe7\x95\x8c\xf0\x9f\x98\x80";
    ok &= strlen(unicode) == 7 && g_utf8_strlen(unicode, -1) == 2;
    return ok;
}
static gboolean tracking_contract(void) {
    gboolean ok = TRUE;
    JSTIAtspiTarget t = {0};
    t.phase = DISPATCHED; t.start = 3; t.end = 7; t.original = "Susy";
    ok &= track(&t, "insert", 3, 4, "Susy") && !track(&t, "insert", 3, 4, "Susy");
    t.phase = INSERTED; t.count = 10; t.tracked = g_strdup("Susy");
    ok &= track(&t, "insert", 5, 1, "i") && t.end == 8 && t.count == 11;
    ok &= !track(&t, "insert", 3, 1, "x") && !track(&t, "delete", 7, 1, "x")
        && !track(&t, "reset", 5, 1, "x") && !track(&t, "insert", 0, 1, "x");
    ok &= g_strcmp0(t.tracked, "Suisy") == 0;
    ok &= track(&t, "delete:user", 5, 1, "i") && g_strcmp0(t.tracked, "Susy") == 0;
    ok &= !track(&t, "delete", 4, 1, "x") && !track(&t, "insert:unknown", 4, 1, "x")
        && !track(&t, "insert", 4, 2, "x") && !track(&t, "insert", 4, LIMIT + 1, "x");
    g_free(t.tracked);
    t.start = 2; t.end = 6; t.count = 9; t.mutations = 0;
    t.tracked = g_strdup("S\xe7\x95\x8c\xf0\x9f\x98\x80y");
    ok &= track(&t, "insert:user", 4, 1, "e") && t.end == 7 && t.count == 10
        && track(&t, "delete", 3, 1, "\xe7\x95\x8c") && t.end == 6
        && g_strcmp0(t.tracked, "Se\xf0\x9f\x98\x80y") == 0;
    t.phase = FINISHED;
    ok &= !track(&t, "insert", 4, 1, "z");
    g_free(t.tracked);
    return ok;
}
static gboolean observational_contract(void) {
    Session s = {0}; s.epoch = 12; s.focus = 8;
    JSTIAtspiTarget t = {0};
    t.session = &s; t.epoch = 12; t.focus = 8; t.phase = DISPATCHED;
    t.original = "OK"; t.start = 0; t.end = 2;
    gboolean ok = !insertion_observed(&t, TRUE, 2, 2); /* TRUE without event is not evidence. */
    ok &= track(&t, "insert:system", 0, 2, "OK");
    ok &= insertion_observed(&t, TRUE, 2, 2) && !insertion_observed(&t, FALSE, 2, 2)
        && !insertion_observed(&t, TRUE, 0, 0);
    /* These identical values describe BOTH our insertion and the documented
     * app-prefill/no-op A/B case. The result must remain observational. */
    JSTIAtspiTarget app_prefill = t;
    ok &= insertion_observed(&app_prefill, TRUE, 2, 2);
    s.focus = 9; ok &= !current_target(&t); s.focus = 8;
    s.epoch = 13; ok &= !current_target(&t); s.epoch = 12;
    invalidate(&t); ok &= !current_target(&t);
    t.owner = ":1.42"; t.path = "/synthetic";
    const gint before = t.insert_events;
    GVariant *event = g_variant_ref_sink(g_variant_new("(siiv@a{sv})", "insert", 0, 2,
        g_variant_new_string("OK"), g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0)));
    object_event(NULL, t.owner, t.path, OBJECT_EVENT, "TextChanged", event, &t);
    g_variant_unref(event); ok &= t.insert_events == before;
    g_atomic_int_set(&t.cancelled, FALSE); s.admitted = &t;
    GVariant *lost = g_variant_ref_sink(g_variant_new("(sss)", t.owner, t.owner, ""));
    owner_changed(NULL, NULL, NULL, NULL, NULL, lost, &s);
    g_variant_unref(lost); ok &= !current_target(&t);
    g_atomic_int_set(&t.cancelled, FALSE); t.focus = s.focus;
    s.cancel = g_cancellable_new();
    bus_closed(NULL, TRUE, NULL, &s);
    ok &= !current_target(&t) && g_atomic_int_get(&s.stopped) && g_cancellable_is_cancelled(s.cancel);
    g_object_unref(s.cancel);
    return ok;
}
static CleanupShape fixture_schema(const char *cleanup) {
    gchar *xml = g_strdup_printf("<node><interface name='%s'>"
        "<method name='RegisterEvent'><arg type='s' direction='in'/>"
        "<arg type='as' direction='in'/><arg type='s' direction='in'/></method>"
        "<method name='DeregisterEvent'>%s</method></interface></node>", REGISTRY, cleanup);
    CleanupShape shape = registry_schema(xml); g_free(xml); return shape;
}
static gboolean cleanup_contract(void) {
    gboolean ok = fixture_schema("<arg type='s' direction='in'/>") == CLEANUP_EVENT
        && fixture_schema("<arg type='s' direction='in'/><arg type='s' direction='in'/>")
            == CLEANUP_APPLICATION
        && fixture_schema("<arg type='u' direction='in'/>") == CLEANUP_UNKNOWN
        && fixture_schema("<arg type='s' direction='in'/><arg type='b' direction='out'/>") == CLEANUP_UNKNOWN
        && fixture_schema("") == CLEANUP_UNKNOWN && registry_schema("<node/>") == CLEANUP_UNKNOWN;
    GVariant *old = g_variant_ref_sink(cleanup_arguments(CLEANUP_EVENT, "object:text-changed", ":1.7"));
    GVariant *newer = g_variant_ref_sink(cleanup_arguments(CLEANUP_APPLICATION, "object:text-changed", ":1.7"));
    ok &= g_variant_is_of_type(old, G_VARIANT_TYPE("(s)"))
        && g_variant_is_of_type(newer, G_VARIANT_TYPE("(ss)"))
        && cleanup_arguments(CLEANUP_UNKNOWN, "object:text-changed", ":1.7") == NULL;
    g_variant_unref(old); g_variant_unref(newer); return ok;
}
static gboolean consent_contract(void) {
    ConsentLedger ledger = {0};
    const guint64 a = advance_consent(&ledger, TRUE);
    const guint64 stop = advance_consent(&ledger, FALSE);
    const guint64 b = advance_consent(&ledger, TRUE);
    gboolean ok = !consent_action_current(&ledger, TRUE, a)
        && !consent_action_current(&ledger, FALSE, stop) && consent_action_current(&ledger, TRUE, b)
        && !consent_action_current(&ledger, TRUE, 0);
    ledger.offer = 0; /* The current grant consumes only its own offer. */
    ok &= !consent_action_current(&ledger, TRUE, b) && !consent_action_current(&ledger, FALSE, stop);
    advance_consent(&ledger, FALSE);
    ok &= !consent_action_current(&ledger, TRUE, b);
    ledger.generation = G_MAXUINT64;
    ok &= advance_consent(&ledger, TRUE) == 0 && !consent_action_current(&ledger, TRUE, G_MAXUINT64);
    return ok;
}
int32_t jsti_atspi_contract_self_test(void) {
    return bitmap_contract() && tracking_contract() && observational_contract()
        && cleanup_contract() && consent_contract() ? 0 : -1;
}
