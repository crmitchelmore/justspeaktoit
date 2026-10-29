#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>
#include <string.h>

/* No diagnostic content or GError message is logged by this module. GTK fields
 * are GTK-thread-only; request completion and retirement are thread-safe. */
typedef struct IssueRequest IssueRequest;
typedef struct Presentation Presentation;
struct JSTIIssueReport {
    gint refs;
    GMutex lock;
    gboolean retired;
    GList *requests;
    Presentation *pending_presentation;
    gboolean presentation_posted;
    GtkWindow *window;
    GtkTextBuffer *body, *json;
    GtkWidget *body_view, *json_view;
    GtkLabel *status;
    GtkCheckButton *include;
    GtkWidget *copy, *save, *open;
    gboolean updating, pending_include, requested_include, action_acknowledged, can_open;
    gint pending_action;
    char *ticket;
};
struct IssueRequest {
    gint refs;
    GMutex lock;
    JSTIIssueReport *owner;
    GCancellable *cancel;
    JSTIIssueReportCompletion callback;
    void *context;
    char *url, *token;
    gboolean started, copy;
};
static GMutex registry_lock;
static GList *reports;
static GtkWindow *parent_window;
static gboolean closed = TRUE;
static void presentation_free(gpointer data);

static JSTIIssueReport *report_ref(JSTIIssueReport *r) { g_atomic_int_inc(&r->refs); return r; }
static void report_unref(JSTIIssueReport *r) {
    if (!g_atomic_int_dec_and_test(&r->refs)) return;
    g_free(r->ticket); g_mutex_clear(&r->lock); g_free(r);
}
static IssueRequest *request_ref(IssueRequest *r) { g_atomic_int_inc(&r->refs); return r; }
static void request_unref(IssueRequest *r) {
    if (!g_atomic_int_dec_and_test(&r->refs)) return;
    g_clear_object(&r->cancel); g_free(r->url); g_free(r->token); report_unref(r->owner);
    g_mutex_clear(&r->lock); g_free(r);
}
static gboolean is_retired(JSTIIssueReport *r) {
    g_mutex_lock(&r->lock); gboolean value = r->retired; g_mutex_unlock(&r->lock); return value;
}
/* Steal the callback before invoking it; no lock is held across Swift callbacks.
 * Removal owns a separate reference, so cancellation/native completion may race. */
static void request_complete(IssueRequest *r, gint result, const char *path) {
    g_mutex_lock(&r->lock);
    JSTIIssueReportCompletion callback = r->callback;
    void *context = r->context;
    r->callback = NULL; r->context = NULL;
    g_mutex_unlock(&r->lock);
    if (callback == NULL) return;
    g_mutex_lock(&r->owner->lock);
    r->owner->requests = g_list_remove(r->owner->requests, r);
    g_mutex_unlock(&r->owner->lock);
    callback(result, path, context);
    request_unref(r); /* list reference */
}
void jsti_issue_report_cancel_operations(JSTIIssueReport *r) {
    if (r == NULL) return;
    g_mutex_lock(&r->lock);
    GList *pending = g_list_copy(r->requests);
    for (GList *i = pending; i != NULL; i = i->next) request_ref(i->data);
    g_mutex_unlock(&r->lock);
    for (GList *i = pending; i != NULL; i = i->next) {
        IssueRequest *request = i->data;
        g_cancellable_cancel(request->cancel);
        request_complete(request, 0, NULL);
        request_unref(request);
    }
    g_list_free(pending);
}
void jsti_issue_report_cancel_request(JSTIIssueReport *owner, const char *token) {
    if (owner == NULL || token == NULL) return;
    IssueRequest *matching = NULL;
    g_mutex_lock(&owner->lock);
    for (GList *i = owner->requests; i != NULL; i = i->next) {
        IssueRequest *r = i->data;
        if (g_strcmp0(r->token, token) == 0) { matching = request_ref(r); break; }
    }
    g_mutex_unlock(&owner->lock);
    if (matching != NULL) {
        g_cancellable_cancel(matching->cancel); request_complete(matching, 0, NULL); request_unref(matching);
    }
}
static void retire(JSTIIssueReport *r) {
    g_mutex_lock(&r->lock);
    r->retired = TRUE;
    Presentation *pending = r->pending_presentation;
    r->pending_presentation = NULL;
    g_mutex_unlock(&r->lock);
    if (pending != NULL) presentation_free(pending);
    jsti_issue_report_cancel_operations(r);
}
static void destroy_window(JSTIIssueReport *r) {
    GtkWindow *window = r->window;
    r->window = NULL;
    if (window != NULL) gtk_window_destroy(window);
}
static void unregister_report(JSTIIssueReport *r) {
    g_mutex_lock(&registry_lock);
    gboolean registered = g_list_find(reports, r) != NULL;
    if (registered) reports = g_list_remove(reports, r);
    g_mutex_unlock(&registry_lock);
    if (registered) report_unref(r);
}
static void dismiss_apply(gpointer data) { destroy_window(data); unregister_report(data); }
static void release_report(gpointer data) { report_unref(data); }
void jsti_issue_report_dismiss(JSTIIssueReport *r) {
    if (r == NULL) return;
    retire(r);
    /* Destruction callback only unrefs; it cannot post under post_lock. */
    jsti_window_post(dismiss_apply, report_ref(r), release_report);
}
JSTIIssueReport *jsti_issue_report_create(void) {
    JSTIIssueReport *r = g_new0(JSTIIssueReport, 1); r->refs = 1;
    g_mutex_init(&r->lock);
    g_mutex_lock(&registry_lock);
    r->retired = closed;
    /* A closed-loop handle is immediately inert and needs no registry owner. */
    if (!closed) reports = g_list_prepend(reports, report_ref(r));
    g_mutex_unlock(&registry_lock);
    return r;
}
void jsti_issue_report_destroy(JSTIIssueReport *r) {
    if (r == NULL) return;
    jsti_issue_report_dismiss(r);
    report_unref(r);
}
void jsti_issue_reports_bind(void *parent) {
    g_mutex_lock(&registry_lock); closed = FALSE; parent_window = GTK_WINDOW(parent); g_mutex_unlock(&registry_lock);
}
void jsti_issue_reports_close(void) {
    g_mutex_lock(&registry_lock);
    closed = TRUE; parent_window = NULL;
    GList *owned = g_list_copy(reports);
    for (GList *i = owned; i != NULL; i = i->next) report_ref(i->data);
    g_mutex_unlock(&registry_lock);
    for (GList *i = owned; i != NULL; i = i->next) {
        JSTIIssueReport *r = i->data;
        /* Cancel the exact Swift operation/lease before settling native replies. */
        if (r->ticket != NULL) jsti_window_emit(JSTI_EVENT_ISSUE_REPORT_CLOSE, r->ticket, 0);
        retire(r); destroy_window(r); unregister_report(r); report_unref(r);
    }
    g_list_free(owned);
}
static gboolean bounded(const char *s, gsize maximum) {
    if (s == NULL) return FALSE;
    gsize size = strnlen(s, maximum + 1);
    return size <= maximum && g_utf8_validate(s, size, NULL);
}
struct Presentation {
    JSTIIssueReport *owner;
    char *ticket, *title, *body, *json, *status;
    gboolean included, exporting, opening, can_open;
};
static void presentation_free(gpointer data) {
    Presentation *p = data;
    report_unref(p->owner);
    g_free(p->ticket); g_free(p->title); g_free(p->body); g_free(p->json); g_free(p->status); g_free(p);
}
static gboolean window_close(GtkWindow *window, gpointer data) {
    (void)window;
    JSTIIssueReport *r = data;
    if (!is_retired(r)) jsti_window_emit(JSTI_EVENT_ISSUE_REPORT_CLOSE, r->ticket, 0);
    retire(r); destroy_window(r); return TRUE;
}
static void share_controls(JSTIIssueReport *r, gboolean enabled) {
    gtk_widget_set_sensitive(GTK_WIDGET(r->include), enabled);
    gtk_widget_set_sensitive(r->copy, enabled); gtk_widget_set_sensitive(r->save, enabled);
    gtk_widget_set_sensitive(r->open, enabled && r->can_open);
}
static gboolean prepare_include(JSTIIssueReport *r, gboolean included) {
    if (is_retired(r)) return FALSE;
    g_mutex_lock(&r->lock);
    gboolean available = !r->pending_include && r->pending_action == 0;
    if (available) { r->pending_include = TRUE; r->requested_include = included; }
    g_mutex_unlock(&r->lock);
    if (!available) return FALSE;
    /* Never leave the prior full report selectable while removal awaits its
     * canonical shared projection. Do not invent a native removed report. */
    gtk_text_buffer_set_text(r->body, "Updating preview…", -1);
    gtk_text_buffer_set_text(r->json, "Updating preview…", -1);
    gtk_widget_set_sensitive(r->body_view, FALSE); gtk_widget_set_sensitive(r->json_view, FALSE);
    share_controls(r, FALSE);
    return TRUE;
}
static void action(GtkButton *button, gpointer data) {
    JSTIIssueReport *r = data;
    gint event = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "issue-event"));
    if (event == JSTI_EVENT_ISSUE_REPORT_CLOSE) { window_close(r->window, r); return; }
    if (is_retired(r)) return;
    g_mutex_lock(&r->lock);
    gboolean available = !r->pending_include && r->pending_action == 0;
    if (available) { r->pending_action = event; r->action_acknowledged = FALSE; }
    g_mutex_unlock(&r->lock);
    if (available) {
        share_controls(r, FALSE);
        jsti_window_emit(event, r->ticket, 0);
    }
}
static void include_changed(GtkCheckButton *button, gpointer data) {
    JSTIIssueReport *r = data;
    gboolean included = gtk_check_button_get_active(button);
    if (!r->updating && prepare_include(r, included))
        jsti_window_emit(JSTI_EVENT_ISSUE_REPORT_INCLUDE, r->ticket, included);
}
static GtkWidget *report_text(GtkBox *box, GtkTextBuffer **buffer, const char *name) {
    GtkWidget *label = gtk_label_new(name); gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_box_append(box, label);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE); gtk_widget_set_size_request(scroll, -1, 100);
    GtkWidget *view = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), view); gtk_box_append(box, scroll);
    return view;
}
static GtkWidget *report_button(GtkBox *box, const char *label, gint event, JSTIIssueReport *r) {
    GtkWidget *button = gtk_button_new_with_label(label);
    gtk_widget_set_size_request(button, -1, 44);
    g_object_set_data(G_OBJECT(button), "issue-event", GINT_TO_POINTER(event));
    g_signal_connect(button, "clicked", G_CALLBACK(action), r); gtk_box_append(box, button); return button;
}
static void apply_presentation(Presentation *p) {
    JSTIIssueReport *r = p->owner;
    if (is_retired(r) || parent_window == NULL) return;
    if (r->ticket != NULL && g_strcmp0(r->ticket, p->ticket) != 0) return;
    g_mutex_lock(&r->lock);
    gboolean stale = (r->pending_include && p->included != r->requested_include) ||
        (r->pending_action != 0 && !r->action_acknowledged);
    if (!stale) { r->pending_include = FALSE; r->pending_action = 0; r->action_acknowledged = FALSE; }
    g_mutex_unlock(&r->lock);
    if (stale) return;
    if (r->window == NULL) {
        r->ticket = g_strdup(p->ticket);
        r->window = GTK_WINDOW(gtk_window_new());
        /* Signal lifetime is tied to the native window, never LinuxEventContext. */
        g_object_set_data_full(G_OBJECT(r->window), "issue-owner", report_ref(r), release_report);
        gtk_window_set_modal(r->window, TRUE); gtk_window_set_transient_for(r->window, parent_window);
        gtk_window_set_default_size(r->window, 640, 680);
        g_signal_connect(r->window, "close-request", G_CALLBACK(window_close), r);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
        gtk_widget_set_margin_start(box, 16); gtk_widget_set_margin_end(box, 16);
        gtk_widget_set_margin_top(box, 16); gtk_widget_set_margin_bottom(box, 16);
        GtkWidget *outer = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(outer), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(outer), box);
        gtk_window_set_child(r->window, outer);
        GtkWidget *instructions = gtk_label_new("Review before sharing. Save JSON, then attach it manually on GitHub. Nothing is sent automatically.");
        gtk_label_set_wrap(GTK_LABEL(instructions), TRUE); gtk_box_append(GTK_BOX(box), instructions);
        r->include = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Include diagnostics"));
        gtk_widget_set_size_request(GTK_WIDGET(r->include), -1, 44);
        g_signal_connect(r->include, "toggled", G_CALLBACK(include_changed), r);
        gtk_box_append(GTK_BOX(box), GTK_WIDGET(r->include));
        r->body_view = report_text(GTK_BOX(box), &r->body, "Issue draft");
        r->json_view = report_text(GTK_BOX(box), &r->json, "JSON attachment");
        r->status = GTK_LABEL(gtk_label_new("")); gtk_label_set_wrap(r->status, TRUE);
        gtk_box_append(GTK_BOX(box), GTK_WIDGET(r->status));
        /* Vertical controls stay usable in a narrow native window. */
        r->copy = report_button(GTK_BOX(box), "Copy issue draft", JSTI_EVENT_ISSUE_REPORT_COPY, r);
        r->save = report_button(GTK_BOX(box), "Save JSON…", JSTI_EVENT_ISSUE_REPORT_SAVE, r);
        r->open = report_button(GTK_BOX(box), "Open GitHub draft", JSTI_EVENT_ISSUE_REPORT_OPEN, r);
        report_button(GTK_BOX(box), "Cancel", JSTI_EVENT_ISSUE_REPORT_CLOSE, r);
    }
    r->updating = TRUE;
    gtk_window_set_title(r->window, p->title);
    gtk_text_buffer_set_text(r->body, p->body, -1); gtk_text_buffer_set_text(r->json, p->json, -1);
    r->can_open = p->can_open;
    gtk_label_set_text(r->status, p->status[0] == '\0' && !p->can_open
        ? "Browser link unavailable. Copy the issue draft instead." : p->status);
    gtk_check_button_set_active(r->include, p->included);
    gtk_widget_set_sensitive(r->body_view, TRUE); gtk_widget_set_sensitive(r->json_view, TRUE);
    gboolean available = !p->opening && !p->exporting;
    share_controls(r, available);
    r->updating = FALSE; gtk_window_present(r->window);
}
/* A preview retains at most one queued payload. Repeated actor refreshes replace
 * it before GTK consumes it; no report text accumulates in the main-loop FIFO. */
typedef struct { JSTIIssueReport *owner; gboolean applied; } PresentationPost;
static void present_apply(gpointer data) {
    PresentationPost *post = data; JSTIIssueReport *r = post->owner;
    g_mutex_lock(&r->lock);
    Presentation *p = r->pending_presentation;
    r->pending_presentation = NULL; r->presentation_posted = FALSE;
    g_mutex_unlock(&r->lock);
    post->applied = TRUE;
    if (p != NULL) { apply_presentation(p); presentation_free(p); }
}
static void present_post_free(gpointer data) {
    PresentationPost *post = data;
    if (!post->applied) {
        g_mutex_lock(&post->owner->lock);
        Presentation *p = post->owner->pending_presentation;
        post->owner->pending_presentation = NULL; post->owner->presentation_posted = FALSE;
        g_mutex_unlock(&post->owner->lock);
        if (p != NULL) presentation_free(p);
    }
    report_unref(post->owner); g_free(post);
}
int32_t jsti_issue_report_present(JSTIIssueReport *r, const char *ticket,
    const char *title, const char *body, const char *json, int32_t included,
    int32_t exporting, int32_t opening, int32_t can_open, const char *status) {
    if (r == NULL || is_retired(r) || !bounded(ticket, 36) || !g_uuid_string_is_valid(ticket) ||
        !bounded(title, 256) || !bounded(body, 32768) || !bounded(json, 16384) || !bounded(status, 512)) return -1;
    Presentation *p = g_new0(Presentation, 1); p->owner = report_ref(r);
    p->ticket = g_strdup(ticket); p->title = g_strdup(title); p->body = g_strdup(body);
    p->json = g_strdup(json); p->status = g_strdup(status);
    p->included = included != 0; p->exporting = exporting != 0; p->opening = opening != 0; p->can_open = can_open != 0;
    g_mutex_lock(&r->lock);
    if (r->retired) { g_mutex_unlock(&r->lock); presentation_free(p); return -1; }
    if ((r->pending_action == JSTI_EVENT_ISSUE_REPORT_SAVE && p->exporting) ||
        ((r->pending_action == JSTI_EVENT_ISSUE_REPORT_COPY || r->pending_action == JSTI_EVENT_ISSUE_REPORT_OPEN) && p->opening))
        r->action_acknowledged = TRUE;
    Presentation *previous = r->pending_presentation;
    r->pending_presentation = p;
    gboolean schedule = !r->presentation_posted;
    r->presentation_posted = TRUE;
    g_mutex_unlock(&r->lock);
    if (previous != NULL) presentation_free(previous);
    if (schedule) {
        PresentationPost *post = g_new0(PresentationPost, 1); post->owner = report_ref(r);
        return jsti_window_post(present_apply, post, present_post_free);
    }
    return 0;
}
static void chooser_finished(GObject *source, GAsyncResult *result, gpointer data) {
    IssueRequest *r = data; GError *error = NULL;
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    char *path = file != NULL ? g_file_get_path(file) : NULL;
    gint outcome = path != NULL && bounded(path, 4096) ? 1 : -1;
    if (error != NULL && (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) ||
        g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) ||
        g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED))) outcome = 0;
    request_complete(r, outcome, outcome == 1 ? path : NULL);
    g_free(path); g_clear_object(&file); g_clear_error(&error); request_unref(r);
}
static void browser_finished(GObject *source, GAsyncResult *result, gpointer data) {
    IssueRequest *r = data; GError *error = NULL;
    gboolean accepted = gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error);
    request_complete(r, accepted ? 1 : -1, NULL); g_clear_error(&error); request_unref(r);
}
static gboolean clipboard_effect(const char *text) {
    /* Already on GTK: the proven writer executes inline, with no second queue. */
    char fixed_error[1];
    return jsti_clipboard_write(text, fixed_error, sizeof(fixed_error)) == 0;
}
static gboolean apply_copy(IssueRequest *r, gboolean (*effect)(const char *)) {
    g_mutex_lock(&r->owner->lock);
    gboolean unavailable = r->owner->retired || r->owner->pending_include;
    g_mutex_unlock(&r->owner->lock);
    if (unavailable || g_cancellable_is_cancelled(r->cancel) || r->owner->window == NULL) return FALSE;
    /* GTK-thread admission binds Copy to the acknowledged selectable preview,
     * including exact UTF-8 bytes. A late old variant is never substituted. */
    GtkTextIter start, end; gtk_text_buffer_get_bounds(r->owner->body, &start, &end);
    char *displayed = gtk_text_buffer_get_text(r->owner->body, &start, &end, FALSE);
    gboolean matches = g_strcmp0(displayed, r->url) == 0;
    g_free(displayed);
    return matches && effect(r->url);
}
static void request_apply(gpointer data) {
    IssueRequest *r = data;
    if (is_retired(r->owner) || r->owner->window == NULL || g_cancellable_is_cancelled(r->cancel)) return;
    r->started = TRUE;
    if (r->copy) {
        request_complete(r, apply_copy(r, clipboard_effect) ? 1 : -1, NULL);
    } else if (r->url == NULL) {
        GtkFileDialog *dialog = gtk_file_dialog_new();
        gtk_file_dialog_set_title(dialog, "Save diagnostic JSON");
        gtk_file_dialog_set_initial_name(dialog, "justspeaktoit-diagnostics.json");
        GtkFileFilter *filter = gtk_file_filter_new();
        gtk_file_filter_set_name(filter, "JSON diagnostics"); gtk_file_filter_add_pattern(filter, "*.json");
        GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter); gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
        gtk_file_dialog_set_default_filter(dialog, filter);
        g_object_unref(filter); g_object_unref(filters);
        gtk_file_dialog_save(dialog, r->owner->window, r->cancel, chooser_finished, request_ref(r));
        g_object_unref(dialog);
    } else {
        GtkUriLauncher *launcher = gtk_uri_launcher_new(r->url);
        gtk_uri_launcher_launch(launcher, r->owner->window, r->cancel, browser_finished, request_ref(r));
        g_object_unref(launcher);
    }
}
static void request_post_free(gpointer data) {
    IssueRequest *r = data;
    if (!r->started) request_complete(r, -1, NULL);
    request_unref(r);
}
static void begin_request(JSTIIssueReport *owner, const char *token, const char *url, gboolean copy,
    JSTIIssueReportCompletion cb, void *context) {
    if (owner == NULL || !bounded(token, 36) || !g_uuid_string_is_valid(token)) { cb(-1, NULL, context); return; }
    IssueRequest *r = g_new0(IssueRequest, 1); r->refs = 1; g_mutex_init(&r->lock);
    r->owner = report_ref(owner); r->cancel = g_cancellable_new();
    r->callback = cb; r->context = context; r->url = g_strdup(url); r->token = g_strdup(token); r->copy = copy;
    g_mutex_lock(&owner->lock);
    gboolean available = !owner->retired && owner->requests == NULL;
    if (available) owner->requests = g_list_prepend(owner->requests, request_ref(r));
    g_mutex_unlock(&owner->lock);
    if (!available) { cb(-1, NULL, context); r->callback = NULL; request_unref(r); return; }
    /* Drop callbacks only complete/free; they never post or touch GTK. */
    jsti_window_post(request_apply, r, request_post_free);
}
void jsti_issue_report_choose(JSTIIssueReport *r, const char *token, JSTIIssueReportCompletion cb, void *context) {
    if (cb != NULL) begin_request(r, token, NULL, FALSE, cb, context);
}
void jsti_issue_report_copy(JSTIIssueReport *r, const char *token, const char *text,
    JSTIIssueReportCompletion cb, void *context) {
    if (cb == NULL) return;
    if (!bounded(text, 32768)) { cb(-1, NULL, context); return; }
    begin_request(r, token, text, TRUE, cb, context);
}
static gboolean allowed_url(const char *url) {
    if (!bounded(url, 7500)) return FALSE;
    GError *error = NULL; GUri *uri = g_uri_parse(url, G_URI_FLAGS_NONE, &error);
    gboolean allowed = uri != NULL && g_strcmp0(g_uri_get_scheme(uri), "https") == 0 &&
        g_strcmp0(g_uri_get_host(uri), "github.com") == 0 && g_uri_get_userinfo(uri) == NULL &&
        g_uri_get_port(uri) == -1 && g_uri_get_fragment(uri) == NULL &&
        g_strcmp0(g_uri_get_path(uri), "/crmitchelmore/justspeaktoit/issues/new") == 0;
    g_clear_pointer(&uri, g_uri_unref); g_clear_error(&error);
    return allowed;
}
void jsti_issue_report_open(JSTIIssueReport *r, const char *token, const char *url,
    JSTIIssueReportCompletion cb, void *context) {
    if (cb == NULL) return;
    if (!allowed_url(url)) { cb(-1, NULL, context); return; }
    begin_request(r, token, url, FALSE, cb, context);
}
typedef struct { gint calls, result; } TestReply;
static gint synthetic_copies;
static gboolean synthetic_copy(const char *text) {
    ++synthetic_copies; return g_strcmp0(text, "Fixed safe draft") == 0;
}
static gboolean displayed_equals(GtkTextBuffer *buffer, const char *expected) {
    GtkTextIter start, end; gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *shown = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    gboolean equal = g_strcmp0(shown, expected) == 0; g_free(shown); return equal;
}
static void test_completed(int32_t result, const char *path, void *context) {
    (void)path; TestReply *reply = context; ++reply->calls; reply->result = result;
}
int32_t jsti_issue_report_self_test(char *error, size_t capacity) {
    TestReply cancelled = {0}, dropped = {0}, refused = {0};
    gboolean ui_okay = TRUE;
    synthetic_copies = 0;
    JSTIIssueReport *owner = jsti_issue_report_create();
    Presentation p = { .owner = owner, .ticket = "00000000-0000-0000-0000-000000000001",
        .title = "Issue preview self-test", .body = "Fixed safe draft", .json = "{\"safe\":true}",
        .status = "", .included = TRUE, .can_open = TRUE };
    apply_presentation(&p);
    if (owner->window != NULL) {
        ui_okay = displayed_equals(owner->json, p.json) && prepare_include(owner, FALSE);
        IssueRequest pending_copy = { .owner = owner, .cancel = g_cancellable_new(), .url = "Fixed safe draft" };
        ui_okay = ui_okay && !apply_copy(&pending_copy, synthetic_copy) && synthetic_copies == 0;
        g_object_unref(pending_copy.cancel);
        /* An old queued full projection cannot restore selectable diagnostics
         * or enable Copy while removal awaits the canonical acknowledgement. */
        apply_presentation(&p);
        ui_okay = ui_okay && displayed_equals(owner->body, "Updating preview…") &&
            displayed_equals(owner->json, "Updating preview…") && !gtk_widget_get_sensitive(owner->body_view) &&
            !gtk_widget_get_sensitive(owner->json_view) && !gtk_widget_get_sensitive(owner->copy);
        p.included = FALSE; p.body = "User removed diagnostics"; p.json = "{}"; p.can_open = FALSE;
        apply_presentation(&p);
        ui_okay = ui_okay && displayed_equals(owner->body, p.body) && displayed_equals(owner->json, p.json) &&
            gtk_widget_get_sensitive(owner->body_view) && gtk_widget_get_sensitive(owner->copy) &&
            !gtk_widget_get_sensitive(owner->open);
        p.opening = TRUE; apply_presentation(&p);
        ui_okay = ui_okay && !gtk_widget_get_sensitive(owner->save) &&
            !gtk_widget_get_sensitive(owner->copy) && !gtk_widget_get_sensitive(GTK_WIDGET(owner->include));
        p.opening = FALSE; p.exporting = TRUE; apply_presentation(&p);
        ui_okay = ui_okay && !gtk_widget_get_sensitive(owner->open);
    } else { ui_okay = FALSE; }
    IssueRequest *request = g_new0(IssueRequest, 1); request->refs = 1; g_mutex_init(&request->lock);
    request->owner = report_ref(owner); request->cancel = g_cancellable_new();
    request->callback = test_completed; request->context = &cancelled; request->token = g_strdup(p.ticket);
    g_mutex_lock(&owner->lock); owner->requests = g_list_prepend(NULL, request_ref(request)); g_mutex_unlock(&owner->lock);
    jsti_issue_report_cancel_request(owner, "00000000-0000-0000-0000-000000000002");
    gboolean token_okay = cancelled.calls == 0 && !g_cancellable_is_cancelled(request->cancel);
    jsti_issue_report_cancel_request(owner, p.ticket);
    retire(owner); request_complete(request, 1, NULL);
    synthetic_copies = 0;
    gboolean retired_copy_refused = !apply_copy(request, synthetic_copy) && synthetic_copies == 0;
    /* Use the production dropped-post destructor without GTK/portal effects.
     * Its failure completes once; a later cancelled callback is inert. */
    JSTIIssueReport *other = jsti_issue_report_create();
    Presentation other_preview = p;
    other_preview.owner = other; other_preview.body = "Fixed safe draft";
    other_preview.opening = FALSE; other_preview.exporting = FALSE;
    apply_presentation(&other_preview);
    IssueRequest *drop = g_new0(IssueRequest, 1); drop->refs = 1; g_mutex_init(&drop->lock);
    drop->owner = report_ref(other); drop->cancel = g_cancellable_new();
    drop->callback = test_completed; drop->context = &dropped; drop->url = g_strdup("Different safe draft");
    gboolean mismatched_copy_refused = !apply_copy(drop, synthetic_copy) && synthetic_copies == 0;
    g_free(drop->url); drop->url = g_strdup("Fixed safe draft");
    gboolean active_copy_admitted = other->window != NULL && displayed_equals(other->body, drop->url) &&
        apply_copy(drop, synthetic_copy) && synthetic_copies == 1;
    g_mutex_lock(&other->lock); other->requests = g_list_prepend(NULL, request_ref(drop)); g_mutex_unlock(&other->lock);
    request_ref(drop); request_post_free(drop); request_complete(drop, 0, NULL);
    jsti_issue_report_open(other, p.ticket, "https://invalid.test", test_completed, &refused);
    gboolean okay = ui_okay && token_okay && retired_copy_refused && mismatched_copy_refused && active_copy_admitted && cancelled.calls == 1 && cancelled.result == 0 &&
        dropped.calls == 1 && dropped.result == -1 && refused.calls == 1 && refused.result == -1 &&
        other->requests == NULL && g_cancellable_is_cancelled(request->cancel) && owner->requests == NULL &&
        !bounded("\xff", 10) && !bounded("toolong", 3) && bounded("{}", 2) &&
        allowed_url("https://github.com/crmitchelmore/justspeaktoit/issues/new?labels=bug") &&
        !allowed_url("https://github.com.evil.test/crmitchelmore/justspeaktoit/issues/new") &&
        !allowed_url("https://user@github.com/crmitchelmore/justspeaktoit/issues/new") &&
        !allowed_url("file:///tmp/report.json") &&
        jsti_issue_report_present(owner, "bad", "", "", "{}", 0, 0, 0, 0, "") == -1;
    request_unref(drop); destroy_window(other); unregister_report(other); jsti_issue_report_destroy(other);
    request_unref(request); destroy_window(owner); unregister_report(owner); jsti_issue_report_destroy(owner);
    if (okay) return 0;
    if (error != NULL && capacity > 0) g_strlcpy(error, "Issue preview retirement or input bounds failed", capacity);
    return -1;
}
