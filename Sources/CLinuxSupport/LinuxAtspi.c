#include "LinuxAtspiInternal.h"

/* Accessibility work has a private context. No GTK, audio or recording-start
 * caller waits for discovery. An admitted target is metadata only until consented
 * output; all captured text stays inside its bounded, short-lived lease. */

static GMutex state_lock;
/* The published correction and selection sessions. */
static Session *current;
static Session *selection_current;
/* At most one selection lease is pending across every selection target. */
static SelectionAdmission selection_admission;
static guint64 next_epoch;
static ConsentLedger consent;
static ConsentLedger selection_consent;

void atspi_lock(void) { g_mutex_lock(&state_lock); }
void atspi_unlock(void) { g_mutex_unlock(&state_lock); }
Session *selection_session_locked(void) { return selection_current; }
JSTIAtspiSelection *jsti_atspi_selection_capture(void) {
    g_mutex_lock(&state_lock);
    JSTIAtspiSelection *lease = capture_selection(selection_current, &selection_admission);
    g_mutex_unlock(&state_lock); return lease;
}

Session *session_ref(Session *s) { g_atomic_int_inc(&s->refs); return s; }
void session_unref(Session *s) {
    if (!g_atomic_int_dec_and_test(&s->refs)) return;
    g_clear_object(&s->cancel);
    g_main_context_unref(s->context);
    g_free(s);
}
JSTIAtspiTarget *target_ref(JSTIAtspiTarget *t) { g_atomic_int_inc(&t->refs); return t; }
void jsti_atspi_release(JSTIAtspiTarget *t) {
    if (t == NULL || !g_atomic_int_dec_and_test(&t->refs)) return;
    session_unref(t->session);
    g_free(t->owner); g_free(t->path); g_free(t->app); g_free(t->top);
    g_ptr_array_unref(t->parents);
    if (t->signals != NULL) g_array_unref(t->signals);
    g_free(t->original); g_free(t->tracked); g_free(t->left); g_free(t->right); g_free(t);
}
gboolean current_target(JSTIAtspiTarget *t) {
    return !g_atomic_int_get(&t->cancelled) && !g_atomic_int_get(&t->session->stopped)
        && t->epoch == t->session->epoch && t->focus == t->session->focus;
}
void invalidate(JSTIAtspiTarget *t) {
    if (t != NULL) g_atomic_int_set(&t->cancelled, TRUE);
}
void invalidate_focus(Session *s) {
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
GVariant *rpc(
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
GVariant *property(Session *s, const char *owner, const char *path,
    const char *interface, const char *name, gint64 deadline) {
    GVariant *reply = rpc(s, owner, path, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", interface, name), "(v)", deadline);
    if (reply == NULL) return NULL;
    GVariant *wrapped = g_variant_get_child_value(reply, 0);
    GVariant *value = g_variant_get_variant(wrapped);
    g_variant_unref(wrapped); g_variant_unref(reply); return value;
}
gboolean integer_property(JSTIAtspiTarget *t, const char *name, gint *out, gint64 deadline) {
    GVariant *v = property(t->session, t->owner, t->path, TEXT, name, deadline);
    gboolean ok = v != NULL && g_variant_is_of_type(v, G_VARIANT_TYPE_INT32);
    if (ok) *out = g_variant_get_int32(v);
    if (v != NULL) g_variant_unref(v);
    return ok && current_target(t);
}

gboolean bitmap(GVariant *array, guint64 *bits) {
    if (!g_variant_is_of_type(array, G_VARIANT_TYPE("au")) || g_variant_n_children(array) != 2) return FALSE;
    guint32 a, b; g_variant_get_child(array, 0, "u", &a); g_variant_get_child(array, 1, "u", &b);
    *bits = (guint64)a | ((guint64)b << 32); return TRUE;
}
gboolean safe_state(guint64 bits) {
    const guint64 required = ((guint64)1 << 7) | ((guint64)1 << 8) | ((guint64)1 << 12)
        | ((guint64)1 << 24) | ((guint64)1 << 25) | ((guint64)1 << 30);
    const guint64 forbidden = ((guint64)1 << 0) | ((guint64)1 << 6) | ((guint64)1 << 27)
        | ((guint64)1 << 28) | ((guint64)1 << 43);
    return (bits & required) == required && (bits & forbidden) == 0;
}
gboolean ordinary_role(guint32 role) { return role == 61 || role == 79; }
gboolean external_pid(guint32 pid) { return pid > 0 && pid != (guint32)getpid(); }
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
gboolean identity(JSTIAtspiTarget *t, gboolean admit, gint64 deadline) {
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
gboolean collapsed(JSTIAtspiTarget *t, gint *caret, gint *count, gint64 deadline) {
    GVariant *reply = rpc(t->session, t->owner, t->path, TEXT, "GetNSelections", NULL, "(i)", deadline);
    gint selections = -1;
    if (reply != NULL) { g_variant_get(reply, "(i)", &selections); g_variant_unref(reply); }
    return selections == 0 && integer_property(t, "CharacterCount", count, deadline)
        && integer_property(t, "CaretOffset", caret, deadline)
        && *count >= 0 && *count <= LIMIT && *caret >= 0 && *caret <= *count && current_target(t);
}
gchar *read_text(JSTIAtspiTarget *t, gint start, gint end, gint64 deadline) {
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
gboolean track(JSTIAtspiTarget *t, const char *detail, gint start, gint length, const char *text) {
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
guint64 advance_consent(ConsentLedger *ledger, gboolean offer) {
    if (ledger->exhausted || ledger->generation == G_MAXUINT64) {
        ledger->exhausted = TRUE; ledger->offer = 0; return 0;
    }
    ++ledger->generation; ledger->offer = offer ? ledger->generation : 0;
    return ledger->generation;
}
gboolean consent_action_current(const ConsentLedger *ledger, gboolean allowed, guint64 token) {
    return !ledger->exhausted && token != 0 && token == ledger->generation
        && (!allowed || token == ledger->offer);
}
static Session *revoke_session_locked(Session **slot) {
    Session *old = *slot; *slot = NULL;
    if (old != NULL) {
        g_atomic_int_set(&old->stopped, TRUE);
        invalidate(old->admitted);
        g_cancellable_cancel(old->cancel); g_main_context_wakeup(old->context);
    }
    return old;
}
uint64_t jsti_atspi_offer_local_consent(void) {
    g_mutex_lock(&state_lock);
    Session *old = revoke_session_locked(&current);
    guint64 token = advance_consent(&consent, TRUE);
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return token;
}
uint64_t jsti_atspi_revoke_local_consent(void) {
    g_mutex_lock(&state_lock);
    Session *old = revoke_session_locked(&current);
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
static int32_t apply_consent(Session **slot, ConsentLedger *ledger, SessionPurpose purpose,
    int32_t allowed, uint64_t token) {
    g_mutex_lock(&state_lock);
    if ((token == 0 && allowed) || (token != 0 && !consent_action_current(ledger, allowed != 0, token))) {
        g_mutex_unlock(&state_lock); return 0;
    }
    if (token == 0) advance_consent(ledger, FALSE);
    else ledger->offer = 0;
    Session *old = revoke_session_locked(slot);
    if (allowed) {
        Session *s = g_new0(Session, 1);
        s->refs = 1; s->epoch = ++next_epoch; s->status = 1; s->purpose = purpose;
        s->context = g_main_context_new(); s->cancel = g_cancellable_new(); *slot = s;
        const char *name = purpose == SELECTION_SESSION ? "selection-atspi" : "correction-atspi";
        GThread *thread = g_thread_new(name, worker, session_ref(s)); g_thread_unref(thread);
    }
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return 1;
}
int32_t jsti_atspi_observational_consent(int32_t allowed, uint64_t token) {
    return apply_consent(&current, &consent, CORRECTION_SESSION, allowed, token);
}
uint64_t jsti_atspi_selection_offer(void) {
    g_mutex_lock(&state_lock);
    Session *old = revoke_session_locked(&selection_current);
    guint64 token = advance_consent(&selection_consent, TRUE);
    g_mutex_unlock(&state_lock);
    if (old != NULL) session_unref(old);
    return token;
}
int32_t jsti_atspi_selection_consent(int32_t allowed, uint64_t token) {
    return apply_consent(&selection_current, &selection_consent, SELECTION_SESSION, allowed, token);
}
int32_t jsti_atspi_selection_status(void) {
    g_mutex_lock(&state_lock);
    int status = selection_current != NULL ? g_atomic_int_get(&selection_current->status) : 0;
    g_mutex_unlock(&state_lock); return status;
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
