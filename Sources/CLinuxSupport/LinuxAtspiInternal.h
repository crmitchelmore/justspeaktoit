/* Private to the LinuxAtspi*.c units: the session and target types shared by
 * the accessibility bus worker, requests and contracts. Never exported. The
 * published sessions, the selection admission gate and the lock that guards
 * them are static in LinuxAtspi.c; other units reach them only through the
 * functions below. */
#ifndef JSTI_LINUX_ATSPI_INTERNAL_H
#define JSTI_LINUX_ATSPI_INTERNAL_H
#include "include/LinuxAtspi.h"
#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

#define ACCESSIBLE "org.a11y.atspi.Accessible"
#define TEXT "org.a11y.atspi.Text"
#define EDITABLE "org.a11y.atspi.EditableText"
#define OBJECT_EVENT "org.a11y.atspi.Event.Object"
#define REGISTRY "org.a11y.atspi.Registry"
#define LIMIT 8192
#define GUARD 32
#define BUDGET_US (2500 * 1000)

typedef struct Session Session;
typedef enum { CORRECTION_SESSION, SELECTION_SESSION } SessionPurpose;
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
    guint metadata_registrations, selection_registrations;
};

struct Session {
    gint refs, stopped, status;
    SessionPurpose purpose;
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

typedef struct { gint pending; } SelectionAdmission;
typedef struct { guint64 generation, offer; gboolean exhausted; } ConsentLedger;

struct JSTIAtspiSelection {
    gint refs, started;
    JSTIAtspiTarget *target;
    SelectionAdmission *admission;
    gint64 deadline;
};

typedef struct {
    gint refs;
    GMutex lock;
    GCond changed;
    gboolean done;
    JSTIAtspiTarget *target;
    JSTIAtspiSelection *selection;
    gint kind, result;
    gchar *input, *output;
} Request;

#pragma GCC visibility push(hidden)

/* LinuxAtspi.c's state lock. It guards session publication, `stopped`,
 * `focus` and `admitted`, and the hand-off of work to a session's context;
 * never hold it across IPC. */
void atspi_lock(void);
void atspi_unlock(void);
/* The published selection session, or NULL. Hold the state lock. */
Session *selection_session_locked(void);
Session *session_ref(Session *s);
void session_unref(Session *s);
JSTIAtspiTarget *target_ref(JSTIAtspiTarget *t);
gboolean current_target(JSTIAtspiTarget *t);
void invalidate(JSTIAtspiTarget *t);
void invalidate_focus(Session *s);
GVariant *rpc(
    Session *s, const char *owner, const char *path, const char *interface,
    const char *method, GVariant *args, const char *reply_type, gint64 deadline
);
GVariant *property(Session *s, const char *owner, const char *path,
    const char *interface, const char *name, gint64 deadline);
gboolean integer_property(JSTIAtspiTarget *t, const char *name, gint *out, gint64 deadline);
gboolean bitmap(GVariant *array, guint64 *bits);
gboolean safe_state(guint64 bits);
gboolean ordinary_role(guint32 role);
gboolean external_pid(guint32 pid);
gboolean identity(JSTIAtspiTarget *t, gboolean admit, gint64 deadline);
gboolean collapsed(JSTIAtspiTarget *t, gint *caret, gint *count, gint64 deadline);
gchar *read_text(JSTIAtspiTarget *t, gint start, gint end, gint64 deadline);
gboolean track(JSTIAtspiTarget *t, const char *detail, gint start, gint length, const char *text);
void queue_target_readmission(JSTIAtspiTarget *t);
void object_event(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data);
CleanupShape registry_schema(const char *xml);
GVariant *cleanup_arguments(CleanupShape shape, const char *event, const char *owner);
void detach(JSTIAtspiTarget *t);
void target_destroy(gpointer data);
void subscribe_target(JSTIAtspiTarget *t, const char *interface, const char *signal, const char *path);
gboolean admission(gpointer data);
void queue_admission(Session *s);
void owner_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
    const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data);
void bus_closed(GDBusConnection *bus, gboolean remote, GError *error, gpointer data);
gpointer worker(gpointer data);
guint64 advance_consent(ConsentLedger *ledger, gboolean offer);
gboolean consent_action_current(const ConsentLedger *ledger, gboolean allowed, guint64 token);
JSTIAtspiSelection *capture_selection(Session *s, SelectionAdmission *admission);
void request_free(gpointer data);
gboolean insertion_observed(JSTIAtspiTarget *t, gboolean accepted, gint caret, gint count);
gint insert(JSTIAtspiTarget *t, const gchar *text, gint64 deadline);
gboolean selection_range_valid(gint selections, gint start, gint end, gint count);
gboolean request_allowed(SessionPurpose purpose, gint kind);

#pragma GCC visibility pop

#endif
