#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct { GPtrArray *rows; gchar *summary; guint64 revision; } Report;
static GMutex lock;
static jsti_permissions_fn callback;
static gpointer context;
static guint64 revision;
static struct {
    GtkWindow *window;
    GtkLabel *summary;
    GtkWidget *body, *check, *first_action;
    gboolean pending;
} ui;

uint64_t jsti_permissions_revision(void) {
    g_mutex_lock(&lock);
    guint64 value = revision;
    g_mutex_unlock(&lock);
    return value;
}
int32_t jsti_permissions_configure(jsti_permissions_fn fn, void *data) {
    if (fn == NULL || data == NULL) return -1;
    g_mutex_lock(&lock);
    gboolean available = callback == NULL;
    if (available) { callback = fn; context = data; ++revision; }
    g_mutex_unlock(&lock);
    return available ? 0 : -1;
}
void jsti_permissions_clear(void) {
    g_mutex_lock(&lock);
    callback = NULL; context = NULL; ++revision;
    g_mutex_unlock(&lock);
}
static void invalidate(GtkWindow *window) {
    if (ui.window != window) return;
    memset(&ui, 0, sizeof ui);
    g_mutex_lock(&lock); ++revision; g_mutex_unlock(&lock);
}
static void finalized(gpointer data, GObject *object) { (void)data; invalidate((GtkWindow *)object); }
static gboolean closing(GtkWindow *window, gpointer data) { (void)data; invalidate(window); return FALSE; }
void jsti_permissions_close(void) {
    GtkWindow *window = ui.window;
    if (window != NULL) { invalidate(window); gtk_window_destroy(window); }
}
static void request(void) {
    if (ui.window == NULL || ui.pending) return;
    g_mutex_lock(&lock);
    jsti_permissions_fn fn = callback; gpointer data = context;
    guint64 ticket = ++revision;
    g_mutex_unlock(&lock);
    if (fn == NULL) {
        gtk_label_set_text(ui.summary, "Permissions is unavailable. Close and reopen the app.");
        return;
    }
    ui.pending = TRUE;
    gtk_widget_set_sensitive(ui.check, FALSE);
    gtk_widget_set_sensitive(ui.body, FALSE);
    gtk_label_set_text(ui.summary, "Reading saved app settings and desktop-session guidance...");
    fn(ticket, data);
}
static void check_clicked(GtkButton *button, gpointer data) { (void)button; (void)data; request(); }
static void navigate_clicked(GtkButton *button, gpointer data) {
    (void)button;
    gint page = GPOINTER_TO_INT(data);
    jsti_permissions_close();
    if (jsti_window_show_page(page) != 0)
        (void)jsti_window_update("The requested settings page could not be opened.", NULL, -1);
}
static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code,
                            GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)code; (void)modifiers; (void)data;
    if (key != GDK_KEY_Escape) return FALSE;
    if (ui.window != NULL) gtk_window_close(ui.window);
    return TRUE;
}
static GtkWidget *label(const char *text) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(widget), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(widget), 72);
    gtk_label_set_selectable(GTK_LABEL(widget), TRUE);
    return widget;
}
void jsti_permissions_open(GtkWindow *owner) {
    if (ui.window != NULL) { gtk_window_present(ui.window); return; }
    ui.window = GTK_WINDOW(adw_window_new());
    gtk_window_set_title(ui.window, "Permissions");
    gtk_window_set_default_size(ui.window, 620, 640);
    gtk_window_set_transient_for(ui.window, owner);
    gtk_window_set_destroy_with_parent(ui.window, TRUE);
    gtk_window_set_application(ui.window, gtk_window_get_application(owner));
    g_signal_connect(ui.window, "close-request", G_CALLBACK(closing), NULL);
    g_object_weak_ref(G_OBJECT(ui.window), finalized, NULL);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), NULL);
    gtk_widget_add_controller(GTK_WIDGET(ui.window), keys);
    GtkWidget *toolbar = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), adw_header_bar_new());
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(column, 20); gtk_widget_set_margin_end(column, 20);
    gtk_widget_set_margin_top(column, 16); gtk_widget_set_margin_bottom(column, 20);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    ui.summary = GTK_LABEL(label(""));
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(ui.summary));
    ui.body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_box_append(GTK_BOX(content), ui.body);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), content);
    gtk_box_append(GTK_BOX(column), scroll);
    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.check = gtk_button_new_with_label("Check again");
    gtk_widget_set_size_request(ui.check, -1, 44);
    g_signal_connect(ui.check, "clicked", G_CALLBACK(check_clicked), NULL);
    gtk_box_append(GTK_BOX(footer), ui.check);
    GtkWidget *keyboard = gtk_button_new_with_label("Open Keyboard");
    gtk_widget_set_size_request(keyboard, -1, 44);
    g_signal_connect(keyboard, "clicked", G_CALLBACK(navigate_clicked), GINT_TO_POINTER(JSTI_PAGE_KEYBOARD));
    gtk_box_append(GTK_BOX(footer), keyboard);
    gtk_box_append(GTK_BOX(column), footer);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), column);
    adw_window_set_content(ADW_WINDOW(ui.window), toolbar);
    gtk_window_present(ui.window);
    request();
}
static void row_free(gpointer data) {
    JSTILinuxPermissionRow *row = data;
    g_free((gpointer)row->title); g_free((gpointer)row->status);
    g_free((gpointer)row->detail); g_free((gpointer)row->action); g_free(row);
}
static void report_free(gpointer data) {
    Report *report = data; g_ptr_array_unref(report->rows); g_free(report->summary); g_free(report);
}
static gboolean valid_text(const char *text, gsize maximum) {
    return text != NULL && strlen(text) <= maximum && g_utf8_validate(text, -1, NULL);
}
static Report *report_copy(const JSTILinuxPermissionRow *rows, gsize count, const char *summary, guint64 ticket) {
    if (count > 16 || (count != 0 && rows == NULL) || !valid_text(summary, 8192) || summary[0] == '\0') return NULL;
    Report *report = g_new0(Report, 1);
    report->revision = ticket; report->summary = g_strdup(summary);
    report->rows = g_ptr_array_new_with_free_func(row_free);
    for (gsize index = 0; index < count; ++index) {
        const JSTILinuxPermissionRow *row = rows + index;
        if (!valid_text(row->title, 256) || row->title[0] == '\0' || !valid_text(row->status, 128) ||
            !valid_text(row->detail, 8192) || !valid_text(row->action, 128) ||
            row->page < -1 || row->page >= JSTI_PAGE_COUNT ||
            ((row->page == -1) != (row->action[0] == '\0'))) {
            report_free(report); return NULL;
        }
        JSTILinuxPermissionRow *copy = g_new0(JSTILinuxPermissionRow, 1);
        copy->title = g_strdup(row->title); copy->status = g_strdup(row->status);
        copy->detail = g_strdup(row->detail); copy->action = g_strdup(row->action); copy->page = row->page;
        g_ptr_array_add(report->rows, copy);
    }
    return report;
}
static void report_apply(gpointer data) {
    Report *report = data;
    if (ui.window == NULL || !ui.pending || report->revision != jsti_permissions_revision()) return;
    gtk_label_set_text(ui.summary, report->summary);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(ui.body)) != NULL) gtk_box_remove(GTK_BOX(ui.body), child);
    ui.first_action = NULL;
    for (guint index = 0; index < report->rows->len; ++index) {
        const JSTILinuxPermissionRow *row = g_ptr_array_index(report->rows, index);
        GtkWidget *group = adw_preferences_group_new();
        adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), row->title);
        GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        GtkWidget *status = label(row->status);
        gtk_widget_add_css_class(status, "heading");
        gtk_box_append(GTK_BOX(body), status);
        gtk_box_append(GTK_BOX(body), label(row->detail));
        if (row->page >= 0) {
            GtkWidget *action = gtk_button_new_with_label(row->action);
            gtk_widget_set_size_request(action, -1, 44);
            gtk_widget_set_halign(action, GTK_ALIGN_START);
            g_signal_connect(action, "clicked", G_CALLBACK(navigate_clicked), GINT_TO_POINTER(row->page));
            gtk_box_append(GTK_BOX(body), action);
            if (ui.first_action == NULL) ui.first_action = action;
        }
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), body);
        gtk_box_append(GTK_BOX(ui.body), group);
    }
    ui.pending = FALSE;
    gtk_widget_set_sensitive(ui.body, TRUE);
    gtk_widget_set_sensitive(ui.check, TRUE);
}
int32_t jsti_permissions_set_rows(const JSTILinuxPermissionRow *rows, size_t count,
                                  const char *summary, uint64_t ticket) {
    Report *report = report_copy(rows, count, summary, ticket);
    return report == NULL ? -1 : jsti_window_post(report_apply, report, report_free);
}

typedef struct { guint calls; guint64 ticket; } Fixture;
static void fixture_callback(uint64_t ticket, void *data) {
    Fixture *fixture = data; ++fixture->calls; fixture->ticket = ticket;
}
int32_t jsti_permissions_self_test(GtkWindow *owner, char *error, size_t capacity) {
    Fixture fixture = {0};
    g_mutex_lock(&lock);
    jsti_permissions_fn saved_callback = callback; gpointer saved_context = context;
    callback = fixture_callback; context = &fixture;
    g_mutex_unlock(&lock);
    jsti_permissions_open(owner);
    JSTILinuxPermissionRow row = { "Microphone", "Not detected", "Synthetic read-only guidance.",
        "Open General", JSTI_PAGE_GENERAL };
    Report *report = report_copy(&row, 1, "No access requested.", fixture.ticket);
    report_apply(report); report_free(report);
    gboolean valid = fixture.calls == 1 && !ui.pending && ui.first_action != NULL &&
        !gtk_window_get_modal(ui.window) && gtk_label_get_wrap(ui.summary) &&
        gtk_label_get_selectable(ui.summary);
    guint64 old = fixture.ticket;
    g_signal_emit_by_name(ui.check, "clicked");
    valid = valid && ui.pending && fixture.calls == 2 && !gtk_widget_get_sensitive(ui.check);
    report = report_copy(&row, 1, "Stale report.", old);
    report_apply(report); report_free(report);
    valid = valid && ui.pending;
    jsti_permissions_close();
    jsti_permissions_open(owner);
    report = report_copy(&row, 1, "Closed-window report.", old);
    report_apply(report); report_free(report);
    valid = valid && ui.pending && fixture.calls == 3;
    report = report_copy(&row, 1, "Current report.", fixture.ticket);
    report_apply(report); report_free(report);
    valid = valid && !ui.pending && ui.first_action != NULL;
    row.page = -2;
    valid = valid && jsti_permissions_set_rows(&row, 1, "Invalid", fixture.ticket) == -1;
    row.page = JSTI_PAGE_GENERAL; row.title = "\xff";
    valid = valid && jsti_permissions_set_rows(&row, 1, "Invalid", fixture.ticket) == -1 &&
        jsti_permissions_set_rows(NULL, 17, "Oversize", fixture.ticket) == -1;
    jsti_permissions_close();
    g_mutex_lock(&lock); callback = saved_callback; context = saved_context; g_mutex_unlock(&lock);
    if (!valid) { jsti_set_error(error, capacity, "Permissions guidance lifecycle or revision fence failed."); return -1; }
    return 0;
}
