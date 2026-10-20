#include "LinuxSupportInternal.h"
#include "include/LinuxAtspi.h"
#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

#define FIXTURE "com.justspeaktoit.SelectionFixture"
#define FIXTURE_PATH "/org/a11y/bus"
typedef struct {
    GDBusConnection *bus;
    char *error;
    size_t capacity;
    const char *stage;
} Fixture;
typedef struct { guint reads, writes, bad_ranges, metadata, registrations; } Counts;

static gboolean require(Fixture *f, gboolean condition, const char *message) {
    if (!condition && f->error[0] == '\0') jsti_set_error(f->error, f->capacity, "%s: %s", f->stage, message);
    return condition;
}
static GVariant *call(Fixture *f, const char *owner, const char *path, const char *interface,
    const char *method, GVariant *args, const char *type) {
    GError *failure = NULL;
    GVariant *reply = g_dbus_connection_call_sync(f->bus, owner, path, interface, method, args,
        G_VARIANT_TYPE(type), G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, NULL, &failure);
    if (reply == NULL && f->error[0] == '\0')
        jsti_set_error(f->error, f->capacity, "%s: %s failed: %s", f->stage, method,
            failure != NULL ? failure->message : "no reply");
    g_clear_error(&failure); return reply;
}
static gboolean control(Fixture *f, const char *method, GVariant *args) {
    GVariant *reply = call(f, FIXTURE, FIXTURE_PATH, FIXTURE, method, args, "()");
    if (reply == NULL) return FALSE;
    g_variant_unref(reply); return TRUE;
}
static gboolean counts(Fixture *f, Counts *out) {
    GVariant *reply = call(f, FIXTURE, FIXTURE_PATH, FIXTURE, "Counts", NULL, "(uuuuu)");
    if (reply == NULL) return FALSE;
    g_variant_get(reply, "(uuuuu)", &out->reads, &out->writes, &out->bad_ranges,
        &out->metadata, &out->registrations);
    g_variant_unref(reply); return TRUE;
}
static gboolean no_registrations(Fixture *f) {
    const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    guint active = G_MAXUINT;
    do {
        GVariant *reply = call(f, FIXTURE, FIXTURE_PATH, FIXTURE, "Active", NULL, "(u)");
        if (reply == NULL) return FALSE;
        g_variant_get(reply, "(u)", &active); g_variant_unref(reply);
        if (active == 0) return TRUE;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    return require(f, FALSE, "private registry registrations survived revocation");
}
static gboolean peer_is_isolated(Fixture *f) {
    const char *pid_text = g_getenv("JSTI_ATSPI_FIXTURE_PID");
    char *end = NULL;
    guint64 expected = pid_text != NULL ? g_ascii_strtoull(pid_text, &end, 10) : 0;
    if (!require(f, expected > 0 && expected <= G_MAXUINT32 && expected != (guint64)getpid()
        && end != NULL && *end == '\0', "missing external fixture process identity")) return FALSE;
    const char *names[] = { FIXTURE, "org.a11y.Bus", "org.a11y.atspi.Registry" };
    gchar *owner = NULL;
    gboolean ok = TRUE;
    for (guint i = 0; ok && i < G_N_ELEMENTS(names); ++i) {
        GVariant *reply = call(f, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "GetNameOwner", g_variant_new("(s)", names[i]), "(s)");
        if (reply == NULL) { ok = FALSE; break; }
        const char *value; g_variant_get(reply, "(&s)", &value);
        if (owner == NULL) owner = g_strdup(value);
        ok = require(f, g_strcmp0(owner, value) == 0, "fixture service owners differ");
        g_variant_unref(reply);
    }
    if (ok) {
        GVariant *reply = call(f, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "GetConnectionUnixProcessID", g_variant_new("(s)", owner), "(u)");
        guint32 pid = 0;
        if (reply != NULL) { g_variant_get(reply, "(u)", &pid); g_variant_unref(reply); }
        ok = require(f, reply != NULL && pid == expected, "fixture owner is not the launched external process");
    }
    g_free(owner); return ok;
}
static gboolean ready(Fixture *f, gboolean observation) {
    const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    gint status;
    do {
        status = observation ? jsti_atspi_observational_status() : jsti_atspi_selection_status();
        if (status != 1) break;
        g_usleep(1000); /* Test-only, bounded metadata readiness; never a production delay. */
    } while (g_get_monotonic_time() < deadline);
    return require(f, status == 2, "private accessibility worker did not become ready");
}
static gboolean allow_selection(Fixture *f) {
    guint64 token = jsti_atspi_selection_offer();
    return require(f, token != 0 && jsti_atspi_selection_consent(1, token) == 1,
        "fixture selection consent failed") && ready(f, FALSE);
}
static gboolean settled(Fixture *f, guint metadata) {
    const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    Counts observed = {0};
    do {
        if (!counts(f, &observed)) return FALSE;
        if ((observed.metadata & metadata) == metadata) break;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    return require(f, (observed.metadata & metadata) == metadata, "focus metadata was not queried")
        && require(f, jsti_atspi_selection_fixture_idle() == 1, "metadata admission did not settle");
}
static gboolean focus(Fixture *f, const char *mode, guint metadata) {
    f->stage = mode;
    if (!require(f, jsti_atspi_selection_fixture_idle() == 1, "previous native cleanup did not settle")) return FALSE;
    return control(f, "Configure", g_variant_new("(s)", mode)) && control(f, "Focus", NULL) && settled(f, metadata);
}
static JSTIAtspiSelection *capture(Fixture *f) {
    JSTIAtspiSelection *lease;
    const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    do {
        lease = jsti_atspi_selection_capture();
        if (lease != NULL || jsti_atspi_selection_status() != 2) break;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    require(f, lease != NULL, "no admitted invocation receipt");
    return lease;
}
static gboolean read_case(Fixture *f, const char *mode, gboolean succeeds, guint32 scalar, guint repetitions) {
    if (!focus(f, mode, 7)) return FALSE;
    JSTIAtspiSelection *lease = capture(f);
    if (lease == NULL) return FALSE;
    char text[32769] = {0};
    gint result = jsti_atspi_selection_read(lease, text, sizeof(text));
    jsti_atspi_selection_release(lease);
    Counts observed = {0};
    gboolean ok = counts(f, &observed) && require(f, result == (succeeds ? 1 : 0), "unexpected read result")
        && require(f, observed.writes == 0 && observed.bad_ranges == 0, "mutation or nonselection text request");
    if (succeeds) {
        GString *expected = g_string_new(scalar == 0 ? "selected" : "");
        for (guint i = 0; i < repetitions; ++i) {
            g_string_append_unichar(expected, scalar);
            if (scalar == 'e') g_string_append_unichar(expected, 0x301);
        }
        ok = ok && require(f, g_strcmp0(text, expected->str) == 0 && observed.reads == 2,
            "snapshot or exact-range double read differs");
        g_string_free(expected, TRUE);
    } else {
        gboolean after_read = g_strcmp0(mode, "mutate") == 0 || g_strcmp0(mode, "role-change") == 0
            || g_strcmp0(mode, "short-text") == 0;
        ok = ok && require(f, text[0] == '\0' && (after_read ? observed.reads == 1 : observed.reads == 0),
            "refused snapshot escaped or an ineligible selection was sampled");
    }
    return ok;
}
static gboolean privacy_case(Fixture *f, const char *mode, guint metadata) {
    if (!focus(f, mode, metadata)) return FALSE;
    JSTIAtspiSelection *lease = jsti_atspi_selection_capture();
    gboolean ok = require(f, lease == NULL, "privacy/interface-ineligible field was admitted");
    if (lease != NULL) jsti_atspi_selection_release(lease);
    Counts observed = {0};
    return counts(f, &observed) && ok
        && require(f, observed.reads == 0 && observed.writes == 0, "privacy refusal performed field I/O");
}
static gboolean changed_receipt(Fixture *f) {
    if (!focus(f, "normal", 7)) return FALSE;
    f->stage = "changed-receipt";
    JSTIAtspiSelection *lease = capture(f);
    if (lease == NULL) return FALSE;
    gboolean ok = TRUE;
    for (guint i = 0; i < 1000; ++i) {
        JSTIAtspiSelection *extra = jsti_atspi_selection_capture();
        if (extra != NULL) {
            jsti_atspi_selection_release(extra);
            ok = require(f, FALSE, "burst capture admitted another pending receipt");
            break;
        }
    }
    ok = ok && control(f, "Change", NULL) && settled(f, 7);
    JSTIAtspiSelection *extra = ok ? jsti_atspi_selection_capture() : NULL;
    ok = ok && require(f, extra == NULL, "new metadata bypassed the pending invocation receipt");
    if (extra != NULL) jsti_atspi_selection_release(extra);
    char text[32769] = {0};
    gint result = ok ? jsti_atspi_selection_read(lease, text, sizeof(text)) : 0;
    jsti_atspi_selection_release(lease);
    Counts observed = {0};
    ok = counts(f, &observed) && ok && require(f, result == 0 && text[0] == '\0' && observed.reads == 0,
        "a changed selection retargeted the old receipt");
    if (ok) {
        extra = capture(f);
        ok = extra != NULL;
        if (extra != NULL) {
            result = jsti_atspi_selection_read(extra, text, sizeof(text));
            jsti_atspi_selection_release(extra);
            ok = counts(f, &observed) && require(f, result == 1 && g_strcmp0(text, "elected") == 0
                && observed.reads == 2 && observed.writes == 0 && observed.bad_ranges == 0,
                "a fresh receipt did not read only the new selected range");
        }
    }
    return ok;
}
static gboolean independent_consent(Fixture *f) {
    guint64 token = jsti_atspi_offer_local_consent();
    if (!require(f, token != 0 && jsti_atspi_observational_consent(1, token) == 1, "observation fixture consent failed")
        || !ready(f, TRUE) || !allow_selection(f) || !focus(f, "normal", 7)) return FALSE;
    JSTIAtspiTarget *observation = NULL;
    const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    do {
        observation = jsti_atspi_capture();
        if (observation != NULL) break;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    gboolean ok = require(f, observation != NULL, "separate observational metadata was not admitted");
    jsti_atspi_selection_consent(0, 0);
    ok = ok && require(f, jsti_atspi_observational_status() == 2 && jsti_atspi_is_current(observation) == 1,
        "selection revocation revoked observational authority");
    if (observation != NULL) { jsti_atspi_cancel(observation); jsti_atspi_release(observation); }
    jsti_atspi_observational_consent(0, 0);
    if (!ok || !no_registrations(f) || !allow_selection(f)) return FALSE;
    jsti_atspi_observational_consent(0, 0);
    return require(f, jsti_atspi_selection_status() == 2, "observation revocation revoked selection authority");
}
static gboolean expired_receipt(Fixture *f) {
    if (!focus(f, "normal", 7)) return FALSE;
    f->stage = "expired-receipt";
    JSTIAtspiSelection *lease = capture(f);
    if (lease == NULL) return FALSE;
    GMutex lock; GCond changed;
    g_mutex_init(&lock); g_cond_init(&changed); g_mutex_lock(&lock);
    const gint64 deadline = g_get_monotonic_time() + 2600000;
    while (g_cond_wait_until(&changed, &lock, deadline)) {}
    g_mutex_unlock(&lock); g_mutex_clear(&lock); g_cond_clear(&changed);
    char text[32769] = {0};
    gint result = jsti_atspi_selection_read(lease, text, sizeof(text));
    jsti_atspi_selection_release(lease);
    Counts observed = {0};
    return counts(f, &observed) && require(f, result == 0 && text[0] == '\0'
        && observed.reads == 0 && observed.writes == 0, "expired receipt sampled text");
}
typedef struct { JSTIAtspiSelection *lease; gint result, finished; char text[32769]; } HeldRead;
static gpointer held_read(gpointer data) {
    HeldRead *read = data;
    read->result = jsti_atspi_selection_read(read->lease, read->text, sizeof(read->text));
    g_atomic_int_set(&read->finished, TRUE); return NULL;
}
static gboolean revoked_read(Fixture *f) {
    if (!focus(f, "hold", 7)) return FALSE;
    HeldRead read = {0}; read.lease = capture(f);
    if (read.lease == NULL) return FALSE;
    GThread *thread = g_thread_new("fixture-held-selection", held_read, &read);
    const gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
    Counts observed = {0};
    gboolean ok = TRUE;
    do {
        if (!counts(f, &observed)) { ok = FALSE; break; }
        if (observed.reads != 0 || g_atomic_int_get(&read.finished)) break;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    ok = ok && require(f, observed.reads == 1 && !g_atomic_int_get(&read.finished),
        "the controlled read was not held before revocation");
    jsti_atspi_selection_consent(0, 0);
    ok = control(f, "Release", NULL) && ok;
    g_thread_join(thread);
    ok = ok && require(f, read.result == 0 && read.text[0] == '\0', "revoked read returned selected text");
    if (ok) ok = allow_selection(f) && focus(f, "normal", 7);
    JSTIAtspiSelection *extra = ok ? jsti_atspi_selection_capture() : NULL;
    ok = ok && require(f, extra == NULL, "session restart bypassed the pending lease");
    if (extra != NULL) jsti_atspi_selection_release(extra);
    jsti_atspi_selection_release(read.lease);
    if (ok) {
        extra = capture(f);
        ok = extra != NULL;
        if (extra != NULL) jsti_atspi_selection_release(extra);
    }
    return ok;
}

int32_t jsti_atspi_selection_integration_check(char *error, size_t capacity) {
    if (error == NULL || capacity == 0) return -1;
    error[0] = '\0';
    Fixture f = { .error = error, .capacity = capacity, .stage = "fixture setup" };
    const char *address = g_getenv("DBUS_SESSION_BUS_ADDRESS");
    if (!require(&f, g_strcmp0(g_getenv("JSTI_ATSPI_SELECTION_FIXTURE"), "1") == 0
        && address != NULL && g_str_has_prefix(address, "unix:"), "disposable-bus opt-in is missing")) return -1;
    GError *failure = NULL;
    f.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &failure);
    if (f.bus == NULL) {
        jsti_set_error(error, capacity, "Fixture bus connection failed: %s",
            failure != NULL ? failure->message : "no connection");
        g_clear_error(&failure); return -1;
    }
    g_dbus_connection_set_exit_on_close(f.bus, FALSE);
    gboolean ok = peer_is_isolated(&f);
    GVariant *schema = ok ? call(&f, FIXTURE, FIXTURE_PATH, FIXTURE, "Schema", NULL, "(s)") : NULL;
    const char *shape = NULL;
    if (schema != NULL) g_variant_get(schema, "(&s)", &shape);
    if (ok && g_strcmp0(shape, "unsupported") == 0) {
        guint64 token = jsti_atspi_selection_offer();
        ok = jsti_atspi_selection_consent(1, token) == 1;
        const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
        while (jsti_atspi_selection_status() == 1 && g_get_monotonic_time() < deadline) g_usleep(1000);
        Counts observed = {0};
        ok = counts(&f, &observed) && ok && require(&f, jsti_atspi_selection_status() == 5
            && observed.reads == 0 && observed.registrations == 0, "unsupported registry was not refused before access");
    } else if (ok && schema != NULL) {
        ok = independent_consent(&f)
            && read_case(&f, "normal", TRUE, 0, 0)
            && read_case(&f, "unicode", TRUE, 0x1F600, 8192)
            && read_case(&f, "combining", TRUE, 'e', 4096)
            && read_case(&f, "empty", FALSE, 0, 0)
            && read_case(&f, "none", FALSE, 0, 0)
            && read_case(&f, "multiple", FALSE, 0, 0)
            && read_case(&f, "oversized", FALSE, 0, 0)
            && read_case(&f, "negative", FALSE, 0, 0)
            && read_case(&f, "past-end", FALSE, 0, 0)
            && read_case(&f, "short-text", FALSE, 0, 0)
            && privacy_case(&f, "password", 1) && privacy_case(&f, "protected", 3)
            && privacy_case(&f, "readonly", 7)
            && read_case(&f, "mutate", FALSE, 0, 0)
            && read_case(&f, "role-change", FALSE, 0, 0)
            && changed_receipt(&f) && expired_receipt(&f) && revoked_read(&f);
    } else ok = FALSE;
    jsti_atspi_selection_consent(0, 0); jsti_atspi_observational_consent(0, 0);
    if (ok) ok = no_registrations(&f);
    if (schema != NULL) g_variant_unref(schema);
    g_object_unref(f.bus);
    if (!ok && error[0] == '\0') jsti_set_error(error, capacity, "The isolated AT-SPI fixture failed.");
    return ok ? 0 : -1;
}
