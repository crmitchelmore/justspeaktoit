/* Requests on a captured target: guarded insertion, selection reads, the
 * voice-edit selection replacement and the worker hand-off with cancellation. */
#include "LinuxAtspiInternal.h"

JSTIAtspiSelection *capture_selection(Session *s, SelectionAdmission *admission) {
    JSTIAtspiTarget *t = s != NULL ? s->admitted : NULL;
    JSTIAtspiSelection *lease = NULL;
    if (!g_atomic_int_get(&admission->pending) && t != NULL && s->purpose == SELECTION_SESSION && current_target(t)
        && g_atomic_int_compare_and_exchange(&t->captured, 0, 1)) {
        g_atomic_int_set(&admission->pending, TRUE);
        lease = g_new0(JSTIAtspiSelection, 1);
        lease->refs = 1; lease->target = target_ref(t); lease->admission = admission;
        lease->deadline = g_get_monotonic_time() + BUDGET_US;
    }
    return lease;
}
static void selection_unref(JSTIAtspiSelection *lease) {
    if (lease == NULL || !g_atomic_int_dec_and_test(&lease->refs)) return;
    SelectionAdmission *admission = lease->admission;
    jsti_atspi_release(lease->target); g_free(lease);
    g_atomic_int_set(&admission->pending, FALSE);
}
void jsti_atspi_selection_release(JSTIAtspiSelection *lease) {
    if (lease == NULL) return;
    jsti_atspi_cancel(lease->target); selection_unref(lease);
}

void request_free(gpointer data) {
    Request *r = data;
    if (!g_atomic_int_dec_and_test(&r->refs)) return;
    jsti_atspi_release(r->target); selection_unref(r->selection);
    g_free(r->input); g_free(r->output);
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
gboolean insertion_observed(JSTIAtspiTarget *t, gboolean accepted, gint caret, gint count) {
    return current_target(t) && accepted && t->phase == DISPATCHED && t->insert_events == 1
        && caret == t->end && count == t->initial_count + t->end - t->start;
}
gint insert(JSTIAtspiTarget *t, const gchar *text, gint64 deadline) {
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
gboolean selection_range_valid(gint selections, gint start, gint end, gint count) {
    return selections == 1 && start >= 0 && end > start && end <= count && end - start <= LIMIT;
}
static gboolean selection_range(JSTIAtspiTarget *t, gint *start, gint *end, gint64 deadline) {
    GVariant *reply = rpc(t->session, t->owner, t->path, TEXT, "GetNSelections", NULL, "(i)", deadline);
    gint selections = -1, count = -1;
    if (reply != NULL) { g_variant_get(reply, "(i)", &selections); g_variant_unref(reply); }
    if (selections != 1 || !integer_property(t, "CharacterCount", &count, deadline)) return FALSE;
    reply = rpc(t->session, t->owner, t->path, TEXT, "GetSelection", g_variant_new("(i)", 0), "(ii)", deadline);
    if (reply == NULL) return FALSE;
    g_variant_get(reply, "(ii)", start, end); g_variant_unref(reply);
    return selection_range_valid(selections, *start, *end, count) && current_target(t);
}
static gboolean selection_guards(JSTIAtspiTarget *t, gint start, gint end, gint count, gint64 deadline) {
    t->start = start; t->end = end; t->count = count;
    t->left = read_text(t, MAX(0, start - GUARD), start, deadline);
    t->right = read_text(t, end, MIN(count, end + GUARD), deadline);
    t->left_edge = start <= GUARD; t->right_edge = count - end <= GUARD;
    return t->left != NULL && t->right != NULL;
}
static gchar *read_selection(JSTIAtspiTarget *t, gboolean edit, gint64 deadline) {
    if (t->phase != FRESH || !identity(t, FALSE, deadline)) return NULL;
    subscribe_target(t, OBJECT_EVENT, "TextChanged", t->path);
    GVariant *reply = rpc(t->session, "org.a11y.atspi.Registry", "/org/a11y/atspi/registry", REGISTRY,
        "RegisterEvent", g_variant_new("(s@ass)", "object:text-changed", g_variant_new_strv(NULL, 0), t->owner),
        "()", deadline);
    if (reply == NULL) return NULL;
    g_variant_unref(reply); t->registered = TRUE;
    gint start, end, final_start, final_end;
    if (!identity(t, FALSE, deadline) || !selection_range(t, &start, &end, deadline)) return NULL;
    gchar *text = read_text(t, start, end, deadline);
    gboolean ok = text != NULL && identity(t, FALSE, deadline)
        && selection_range(t, &final_start, &final_end, deadline) && start == final_start && end == final_end;
    gchar *again = ok ? read_text(t, start, end, deadline) : NULL;
    ok = ok && again != NULL && g_strcmp0(text, again) == 0
        && identity(t, FALSE, deadline) && selection_range(t, &final_start, &final_end, deadline)
        && start == final_start && end == final_end && current_target(t) && g_get_monotonic_time() < deadline;
    g_free(again);
    gint count = -1;
    /* A voice edit keeps the read range, text and surroundings to prove the
     * same selection is still there before replacing it. */
    if (ok && edit) ok = integer_property(t, "CharacterCount", &count, deadline)
        && selection_guards(t, start, end, count, deadline) && current_target(t);
    t->phase = ok && edit ? SELECTED : FINISHED;
    if (ok && edit) t->original = g_strdup(text);
    if (!ok) g_clear_pointer(&text, g_free);
    return text;
}
gboolean replacement_observed(JSTIAtspiTarget *t, gint count, gint final_count, const char *observed) {
    return current_target(t) && t->phase == REPLACING && t->delete_events <= 1 && t->insert_events <= 1
        && t->tracked != NULL && observed != NULL && g_strcmp0(observed, t->tracked) == 0
        && final_count == count - (t->end - t->start) + (gint)g_utf8_strlen(t->tracked, -1);
}
static gint replace_selection(JSTIAtspiTarget *t, const gchar *text, gint64 deadline) {
    Session *s = t->session;
    if (g_atomic_int_get(&t->dispatched)) return -1;
    if (t->phase != SELECTED || text == NULL || text[0] == '\0' || strlen(text) > LIMIT * 4
        || !g_utf8_validate(text, -1, NULL) || g_utf8_strlen(text, -1) > LIMIT) return 0;
    /* Final preflight: the same control still holds the same single selection,
     * text, surroundings and length that were read before dictation. */
    gint start, end, count = -1;
    if (!identity(t, FALSE, deadline) || !selection_range(t, &start, &end, deadline)
        || start != t->start || end != t->end
        || !integer_property(t, "CharacterCount", &count, deadline) || count != t->count) return 0;
    gchar *selected = read_text(t, start, end, deadline);
    gboolean same = selected != NULL && g_strcmp0(selected, t->original) == 0;
    g_free(selected);
    if (!same || !guards(t, deadline) || !identity(t, FALSE, deadline) || !current_target(t)) return 0;
    t->tracked = g_strdup(text);
    t->phase = REPLACING; g_atomic_int_set(&t->dispatched, TRUE);
    GVariant *reply = rpc(s, t->owner, t->path, EDITABLE, "DeleteText",
        g_variant_new("(ii)", start, end), "(b)", deadline);
    gboolean accepted = FALSE;
    if (reply != NULL) { g_variant_get(reply, "(b)", &accepted); g_variant_unref(reply); }
    /* No retry or fallback is safe once anything was dispatched. */
    if (!accepted || !current_target(t)) return -1;
    reply = rpc(s, t->owner, t->path, EDITABLE, "InsertText",
        g_variant_new("(isi)", start, text, (gint)strlen(text)), "(b)", deadline);
    accepted = FALSE;
    if (reply != NULL) { g_variant_get(reply, "(b)", &accepted); g_variant_unref(reply); }
    if (!accepted || !current_target(t)) return -1;
    gint final_count = -1;
    const gint length = (gint)g_utf8_strlen(text, -1);
    gchar *observed = NULL;
    gboolean ok = identity(t, FALSE, deadline) && integer_property(t, "CharacterCount", &final_count, deadline)
        && (observed = read_text(t, start, start + length, deadline)) != NULL
        && replacement_observed(t, count, final_count, observed);
    g_free(observed);
    if (ok) {
        /* The surroundings must be untouched around the new span. */
        t->end = start + length; t->count = final_count;
        ok = guards(t, deadline) && current_target(t);
    }
    t->phase = FINISHED;
    return ok ? 1 : -1;
}
gboolean request_allowed(SessionPurpose purpose, gint kind) {
    return (purpose == SELECTION_SESSION && (kind == 3 || kind == 4))
        || (purpose == CORRECTION_SESSION && kind >= 0 && kind <= 2);
}
static gboolean execute(gpointer data) {
    Request *r = data;
    JSTIAtspiTarget *t = r->target; Session *s = t->session;
    gint result = (r->kind == 0 && t->phase >= DISPATCHED)
        || (r->kind == 4 && g_atomic_int_get(&t->dispatched)) ? -1 : 0;
    if (current_target(t) && !s->busy && request_allowed(s->purpose, r->kind)) {
        s->busy = TRUE;
        s->active_target = t;
        const gint64 deadline = r->selection != NULL && !r->selection->edit
            ? r->selection->deadline : g_get_monotonic_time() + BUDGET_US;
        if (r->kind == 0) result = insert(t, r->input, deadline);
        else if (r->kind == 1) {
            if (t->phase == INSERTED && g_strcmp0(r->input, t->original) == 0
                && identity(t, FALSE, deadline)) { t->phase = SAMPLING; result = 1; }
        } else if (r->kind == 3) {
            r->output = read_selection(t, r->selection->edit, deadline);
            if (r->output != NULL) result = 1;
        } else if (r->kind == 4) {
            result = replace_selection(t, r->input, deadline);
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
static gint submit(JSTIAtspiTarget *t, gint kind, const char *input, char *out, size_t capacity,
    JSTIAtspiSelection *selection) {
    if (t == NULL || !request_allowed(t->session->purpose, kind)
        || ((kind == 3 || kind == 4) && (selection == NULL || selection->target != t))
        || (kind == 4 && !selection->edit)) return 0;
    atspi_lock();
    if (g_atomic_int_get(&t->cancelled) || g_atomic_int_get(&t->session->stopped)) {
        atspi_unlock();
        return (kind == 0 || kind == 4) && g_atomic_int_get(&t->dispatched) ? -1 : 0;
    }
    Request *r = g_new0(Request, 1);
    r->refs = 2; g_mutex_init(&r->lock); g_cond_init(&r->changed);
    r->target = target_ref(t); r->kind = kind; r->input = g_strdup(input);
    r->selection = selection;
    if (selection != NULL) g_atomic_int_inc(&selection->refs);
    /* Always enqueue: invoke_full can run inline on a caller acquiring an idle
     * context. These operations must run exclusively on the private worker. */
    GSource *source = g_idle_source_new();
    g_source_set_callback(source, execute, r, request_free);
    g_source_attach(source, t->session->context); g_source_unref(source);
    atspi_unlock();
    g_mutex_lock(&r->lock);
    const gint64 until = g_get_monotonic_time() + BUDGET_US + 500000;
    while (!r->done && g_cond_wait_until(&r->changed, &r->lock, until)) {}
    if (!r->done) invalidate(t);
    gint result = r->done ? r->result
        : kind == 0 || (kind == 4 && g_atomic_int_get(&t->dispatched)) ? -1 : 0;
    if (result == 1 && (kind == 2 || kind == 3)) {
        if (out == NULL || r->output == NULL || strlen(r->output) >= capacity
            || (kind == 3 && !jsti_atspi_is_current(t))) result = 0;
        else g_strlcpy(out, r->output, capacity);
    }
    g_mutex_unlock(&r->lock); request_free(r); return result;
}
static gboolean cancel_lease(gpointer data) {
    JSTIAtspiTarget *t = data;
    detach(t);
    /* A new lease may revalidate the SAME known control off the hot path.
     * This never discovers a late arbitrary focused field or reuses a span. */
    queue_target_readmission(t);
    return G_SOURCE_REMOVE;
}
void jsti_atspi_cancel(JSTIAtspiTarget *t) {
    if (t == NULL) return;
    invalidate(t);
    atspi_lock();
    if (g_atomic_int_get(&t->session->stopped)) { atspi_unlock(); return; }
    GSource *source = g_idle_source_new();
    g_source_set_callback(source, cancel_lease, target_ref(t), target_destroy);
    g_source_attach(source, t->session->context); g_source_unref(source);
    atspi_unlock();
}
int32_t jsti_atspi_insert(JSTIAtspiTarget *t, const char *text) { return submit(t, 0, text, NULL, 0, NULL); }
int32_t jsti_atspi_begin(JSTIAtspiTarget *t, const char *text) { return submit(t, 1, text, NULL, 0, NULL); }
int32_t jsti_atspi_read(JSTIAtspiTarget *t, char *out, size_t capacity) { return submit(t, 2, NULL, out, capacity, NULL); }
int32_t jsti_atspi_selection_read(JSTIAtspiSelection *lease, char *out, size_t capacity) {
    if (lease == NULL || out == NULL || capacity == 0
        || !g_atomic_int_compare_and_exchange(&lease->started, 0, 1)) return 0;
    return submit(lease->target, 3, NULL, out, capacity, lease);
}
int32_t jsti_atspi_voice_edit_is_current(JSTIAtspiSelection *lease) {
    if (lease == NULL || !lease->edit) return 0;
    atspi_lock();
    gboolean valid = current_target(lease->target) && lease->target->phase == SELECTED;
    atspi_unlock(); return valid ? 1 : 0;
}
int32_t jsti_atspi_voice_edit_replace(JSTIAtspiSelection *lease, const char *text) {
    if (lease == NULL || !lease->edit || text == NULL || !g_atomic_int_get(&lease->started)
        || !g_atomic_int_compare_and_exchange(&lease->replaced, 0, 1)) return 0;
    return submit(lease->target, 4, text, NULL, 0, lease);
}
void jsti_atspi_voice_edit_cancel(JSTIAtspiSelection *lease) {
    if (lease != NULL && lease->edit) jsti_atspi_cancel(lease->target);
}
