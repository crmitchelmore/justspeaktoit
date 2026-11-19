/* Fixture idling and the deterministic AT-SPI contract self-tests, run by the
 * shipped binary and the platform tests without a desktop. */
#include "LinuxAtspiInternal.h"

typedef struct {
    gint refs;
    Session *session;
    GMutex lock;
    GCond changed;
    gboolean done, idle;
} FixtureFence;
static void fixture_fence_free(gpointer data) {
    FixtureFence *f = data;
    if (!g_atomic_int_dec_and_test(&f->refs)) return;
    session_unref(f->session); g_mutex_clear(&f->lock); g_cond_clear(&f->changed); g_free(f);
}
static gboolean fixture_fence_ready(gpointer data) {
    FixtureFence *f = data; Session *s = f->session;
    gboolean stopped = g_atomic_int_get(&s->stopped);
    if (!stopped && (s->busy || s->admission_queued)) return G_SOURCE_CONTINUE;
    g_mutex_lock(&f->lock); f->idle = !stopped; f->done = TRUE;
    g_cond_broadcast(&f->changed); g_mutex_unlock(&f->lock);
    return G_SOURCE_REMOVE;
}
int32_t jsti_atspi_selection_fixture_idle(void) {
    if (g_strcmp0(g_getenv("JSTI_ATSPI_SELECTION_FIXTURE"), "1") != 0) return 0;
    atspi_lock();
    Session *s = selection_session_locked();
    if (s == NULL || g_atomic_int_get(&s->stopped)) { atspi_unlock(); return 0; }
    FixtureFence *f = g_new0(FixtureFence, 1);
    f->refs = 2; f->session = session_ref(s); g_mutex_init(&f->lock); g_cond_init(&f->changed);
    GSource *source = g_timeout_source_new(1);
    g_source_set_priority(source, G_PRIORITY_LOW);
    g_source_set_callback(source, fixture_fence_ready, f, fixture_fence_free);
    g_source_attach(source, s->context);
    atspi_unlock();
    g_mutex_lock(&f->lock);
    const gint64 deadline = g_get_monotonic_time() + BUDGET_US + 500000;
    while (!f->done && g_cond_wait_until(&f->changed, &f->lock, deadline)) {}
    gboolean idle = f->done && f->idle;
    g_mutex_unlock(&f->lock);
    g_source_destroy(source); g_source_unref(source); fixture_fence_free(f);
    return idle ? 1 : 0;
}

static gboolean selection_admission_contract(void) {
    SelectionAdmission gate = {0};
    Session *s = g_new0(Session, 1);
    s->refs = 1; s->purpose = SELECTION_SESSION; s->epoch = 1;
    s->context = g_main_context_new(); s->cancel = g_cancellable_new();
    JSTIAtspiTarget *t = g_new0(JSTIAtspiTarget, 1);
    t->refs = 1; t->session = session_ref(s); t->epoch = 1;
    t->parents = g_ptr_array_new_with_free_func(g_free); s->admitted = t;
    JSTIAtspiSelection *lease = capture_selection(s, &gate);
    gboolean ok = lease != NULL && capture_selection(s, &gate) == NULL;
    for (guint i = 0; i < 1000; ++i) ok &= capture_selection(s, &gate) == NULL;
    if (lease != NULL) {
        Request *r = g_new0(Request, 1);
        r->refs = 1; r->target = target_ref(t); r->selection = lease;
        g_mutex_init(&r->lock); g_cond_init(&r->changed); g_atomic_int_inc(&lease->refs);
        g_atomic_int_set(&s->stopped, TRUE);
        jsti_atspi_selection_release(lease);
        ok &= g_atomic_int_get(&gate.pending) && capture_selection(s, &gate) == NULL;
        request_free(r);
        ok &= !g_atomic_int_get(&gate.pending);
    }
    g_atomic_int_set(&s->stopped, FALSE); g_atomic_int_set(&t->cancelled, FALSE);
    g_atomic_int_set(&t->captured, FALSE);
    s->purpose = CORRECTION_SESSION;
    ok &= capture_selection(s, &gate) == NULL;
    s->purpose = SELECTION_SESSION;
    lease = capture_selection(s, &gate);
    ok &= lease != NULL;
    g_atomic_int_set(&s->stopped, TRUE);
    if (lease != NULL) jsti_atspi_selection_release(lease);
    jsti_atspi_release(t); session_unref(s);
    return ok && !g_atomic_int_get(&gate.pending);
}
int32_t jsti_atspi_selection_contract_self_test(void) {
    JSTIAtspiSelection empty = {0};
    char output[4] = {0};
    ConsentLedger observation = {0}, selection = {0};
    guint64 observation_token = advance_consent(&observation, TRUE);
    guint64 selection_token = advance_consent(&selection, TRUE);
    advance_consent(&selection, FALSE);
    gboolean ok = consent_action_current(&observation, TRUE, observation_token)
        && !consent_action_current(&selection, TRUE, selection_token)
        && !request_allowed((SessionPurpose)99, 0) && !request_allowed((SessionPurpose)99, 3);
    ok &= jsti_atspi_selection_read(&empty, NULL, 0) == 0 && !g_atomic_int_get(&empty.started)
        && jsti_atspi_selection_read(&empty, output, sizeof(output)) == 0 && g_atomic_int_get(&empty.started)
        && jsti_atspi_selection_read(&empty, output, sizeof(output)) == 0 && output[0] == '\0';
    /* A plain selection lease never replaces; an edit lease only after its read. */
    JSTIAtspiSelection edit = {0}; edit.edit = TRUE;
    ok &= jsti_atspi_voice_edit_replace(&empty, "x") == 0 && !g_atomic_int_get(&empty.replaced)
        && jsti_atspi_voice_edit_replace(&edit, "x") == 0 && !g_atomic_int_get(&edit.replaced)
        && jsti_atspi_voice_edit_replace(NULL, "x") == 0 && jsti_atspi_voice_edit_is_current(&empty) == 0
        && jsti_atspi_voice_edit_is_current(NULL) == 0;
    selection_token = advance_consent(&selection, TRUE);
    advance_consent(&observation, FALSE);
    ok &= consent_action_current(&selection, TRUE, selection_token);
    for (gint kind = -1; kind <= 4; ++kind) {
        ok &= request_allowed(SELECTION_SESSION, kind) == (kind == 3 || kind == 4);
        ok &= request_allowed(CORRECTION_SESSION, kind) == (kind >= 0 && kind <= 2);
    }
    Session s = {0}; s.purpose = SELECTION_SESSION; s.epoch = 7; s.focus = 8;
    JSTIAtspiTarget t = {0}; t.session = &s; t.epoch = 7; t.focus = 8; t.owner = ":1.99"; t.path = "/fixture";
    object_event(NULL, t.owner, t.path, OBJECT_EVENT, "TextSelectionChanged", NULL, &t);
    ok &= !current_target(&t);
    /* The published selection session lives in LinuxAtspi.c: without one, nothing is captured. */
    atspi_lock();
    gboolean published = selection_session_locked() != NULL;
    atspi_unlock();
    ok &= published || jsti_atspi_selection_capture() == NULL;
    return ok && selection_range_valid(1, 0, LIMIT, LIMIT)
        && selection_range_valid(1, 100000, 100010, 200000)
        && !selection_range_valid(0, 0, 1, 1) && !selection_range_valid(2, 0, 1, 1)
        && !selection_range_valid(1, -1, 1, 1) && !selection_range_valid(1, 1, 1, 1)
        && !selection_range_valid(1, 1, 0, 1) && !selection_range_valid(1, 0, 2, 1)
        && !selection_range_valid(1, 0, LIMIT + 1, LIMIT + 1)
        && selection_admission_contract() ? 0 : -1;
}

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
static gboolean replacement_contract(void) {
    Session s = {0}; s.purpose = SELECTION_SESSION; s.epoch = 3; s.focus = 4;
    JSTIAtspiTarget t = {0};
    t.session = &s; t.epoch = 3; t.focus = 4; t.phase = SELECTED;
    t.start = 2; t.end = 6; t.original = "Susy"; t.tracked = "Sue";
    /* Before dispatch any text change is foreign. */
    gboolean ok = !track(&t, "delete", 2, 4, "Susy");
    t.phase = REPLACING;
    ok &= !track(&t, "insert", 2, 3, "Sue") && !track(&t, "delete", 3, 4, "usy ")
        && !track(&t, "delete", 2, 3, "Sus") && !track(&t, "delete", 2, 4, "Susi")
        && track(&t, "delete:system", 2, 4, "Susy") && !track(&t, "delete", 2, 4, "Susy")
        && !track(&t, "insert", 3, 3, "Sue") && !track(&t, "insert", 2, 3, "Sum")
        && track(&t, "insert", 2, 3, "Sue") && !track(&t, "insert", 2, 3, "Sue");
    ok &= t.delete_events == 1 && t.insert_events == 1;
    ok &= replacement_observed(&t, 10, 9, "Sue") && !replacement_observed(&t, 10, 10, "Sue")
        && !replacement_observed(&t, 10, 9, "Sum") && !replacement_observed(&t, 10, 9, NULL);
    s.focus = 5; ok &= !replacement_observed(&t, 10, 9, "Sue"); s.focus = 4;
    t.phase = FINISHED; ok &= !replacement_observed(&t, 10, 9, "Sue") && !track(&t, "insert", 2, 1, "x");
    /* A caret or selection move invalidates a held selection, but not our own edit. */
    t.owner = ":1.5"; t.path = "/edit"; t.phase = REPLACING;
    object_event(NULL, t.owner, t.path, OBJECT_EVENT, "TextCaretMoved", NULL, &t);
    ok &= current_target(&t);
    t.phase = SELECTED;
    object_event(NULL, t.owner, t.path, OBJECT_EVENT, "TextCaretMoved", NULL, &t);
    ok &= !current_target(&t);
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
    return bitmap_contract() && tracking_contract() && replacement_contract() && observational_contract()
        && cleanup_contract() && consent_contract() ? 0 : -1;
}
