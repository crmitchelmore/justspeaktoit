#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    gchar *title, *detail, *status, *navigation_title, *fix_title;
    gint32 page, fix;
} Finding;

typedef struct {
    guint64 revision;
    gchar *summary;
    gsize count;
    Finding *rows;
} Report;

static GMutex lock;
static guint64 revision;
static jsti_troubleshooting_fn callback;
static gpointer context;
/* Widgets and pending state belong exclusively to the GTK thread. */
static struct {
    GtkWindow *window;
    GtkLabel *summary;
    GtkWidget *body, *check, *first_fix;
    gboolean pending;
    guint64 displayed;
} ui;

uint64_t jsti_troubleshooting_revision(void) {
    g_mutex_lock(&lock);
    guint64 value = revision;
    g_mutex_unlock(&lock);
    return value;
}

int32_t jsti_troubleshooting_configure(jsti_troubleshooting_fn fn, void *data) {
    if (fn == NULL || data == NULL) return -1;
    g_mutex_lock(&lock);
    gboolean available = callback == NULL;
    if (available) { callback = fn; context = data; ++revision; }
    g_mutex_unlock(&lock);
    return available ? 0 : -1;
}

void jsti_troubleshooting_clear(void) {
    g_mutex_lock(&lock);
    callback = NULL; context = NULL; ++revision;
    g_mutex_unlock(&lock);
}

static void invalidate(GtkWindow *window) {
    if (ui.window != window) return;
    memset(&ui, 0, sizeof(ui));
    g_mutex_lock(&lock);
    ++revision;
    g_mutex_unlock(&lock);
}

static void finalized(gpointer data, GObject *object) {
    (void)data;
    invalidate((GtkWindow *)object);
}

static gboolean closing(GtkWindow *window, gpointer data) {
    (void)data;
    invalidate(window);
    return FALSE;
}

void jsti_troubleshooting_close(void) {
    GtkWindow *window = ui.window;
    if (window != NULL) {
        invalidate(window);
        gtk_window_destroy(window);
    }
}

static void request(gint32 command) {
    if (ui.window == NULL || ui.pending) return;
    g_mutex_lock(&lock);
    jsti_troubleshooting_fn fn = callback;
    gpointer data = context;
    guint64 ticket = ++revision;
    g_mutex_unlock(&lock);
    if (fn == NULL) {
        gtk_label_set_text(ui.summary, "Troubleshooting is unavailable. Close and reopen the app.");
        return;
    }
    ui.pending = TRUE;
    gtk_widget_set_sensitive(ui.body, FALSE);
    gtk_widget_set_sensitive(ui.check, FALSE);
    gtk_window_set_modal(ui.window, command != JSTI_LINUX_TROUBLESHOOTING_CHECK);
    gtk_label_set_text(ui.summary, command == JSTI_LINUX_TROUBLESHOOTING_CHECK
        ? "Checking saved settings. Your desktop keyring may need to be unlocked."
        : "Applying the requested fix...");
    fn(command, ticket, data);
}

static void command_clicked(GtkButton *button, gpointer data) {
    (void)button;
    request(GPOINTER_TO_INT(data));
}

static void navigate_clicked(GtkButton *button, gpointer data) {
    (void)button;
    gint page = GPOINTER_TO_INT(data);
    jsti_troubleshooting_close();
    int32_t result;
    if (page == JSTI_LINUX_TROUBLESHOOTING_API_KEYS) result = jsti_window_request_api_keys();
    else if (page == JSTI_LINUX_TROUBLESHOOTING_PERMISSIONS) result = jsti_window_request_permissions();
    else result = jsti_window_show_page(page);
    if (result != 0)
        (void)jsti_window_update("The requested settings page could not be opened.", NULL, -1);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code,
                             GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)code; (void)modifiers; (void)data;
    if (key != GDK_KEY_Escape) return FALSE;
    if (ui.window != NULL) gtk_window_close(ui.window);
    return TRUE;
}

static GtkWidget *text_label(const char *text) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 72);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    return label;
}

void jsti_troubleshooting_open(GtkWindow *owner) {
    if (ui.window != NULL) { gtk_window_present(ui.window); return; }
    ui.window = GTK_WINDOW(adw_window_new());
    gtk_window_set_title(ui.window, "Troubleshooting");
    gtk_window_set_default_size(ui.window, 620, 600);
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
    ui.summary = GTK_LABEL(text_label("Checking saved settings..."));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.summary));
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scrolled, TRUE);
    ui.body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), ui.body);
    gtk_box_append(GTK_BOX(column), scrolled);
    ui.check = gtk_button_new_with_mnemonic("_Check again");
    gtk_widget_set_halign(ui.check, GTK_ALIGN_START);
    g_signal_connect(ui.check, "clicked", G_CALLBACK(command_clicked),
                     GINT_TO_POINTER(JSTI_LINUX_TROUBLESHOOTING_CHECK));
    gtk_box_append(GTK_BOX(column), ui.check);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), column);
    adw_window_set_content(ADW_WINDOW(ui.window), toolbar);
    gtk_window_present(ui.window);
    request(JSTI_LINUX_TROUBLESHOOTING_CHECK);
}

static void report_free(gpointer pointer) {
    Report *report = pointer;
    for (gsize i = 0; i < report->count; ++i) {
        Finding *row = &report->rows[i];
        g_free(row->title); g_free(row->detail); g_free(row->status);
        g_free(row->navigation_title); g_free(row->fix_title);
    }
    g_free(report->rows); g_free(report->summary); g_free(report);
}

static void report_apply(gpointer pointer) {
    Report *report = pointer;
    if (ui.window == NULL || report->revision != jsti_troubleshooting_revision() ||
        report->revision <= ui.displayed) return;
    ui.displayed = report->revision;
    ui.pending = FALSE;
    gtk_window_set_modal(ui.window, FALSE);
    gtk_label_set_text(ui.summary, report->summary);
    ui.first_fix = NULL;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(ui.body)) != NULL)
        gtk_box_remove(GTK_BOX(ui.body), child);
    for (gsize i = 0; i < report->count; ++i) {
        Finding *row = &report->rows[i];
        if (i != 0) gtk_box_append(GTK_BOX(ui.body), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
        GtkWidget *finding = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
        GtkWidget *title = text_label(row->title);
        gtk_widget_add_css_class(title, "heading");
        gtk_widget_set_hexpand(title, TRUE);
        gtk_box_append(GTK_BOX(heading), title);
        gtk_box_append(GTK_BOX(heading), gtk_label_new(row->status));
        gtk_box_append(GTK_BOX(finding), heading);
        gtk_box_append(GTK_BOX(finding), text_label(row->detail));
        GtkWidget *actions = gtk_flow_box_new();
        gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(actions), GTK_SELECTION_NONE);
        gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(actions), 1);
        gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(actions), 2);
        gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(actions), 8);
        gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(actions), 8);
        if (row->navigation_title[0] != '\0') {
            GtkWidget *button = gtk_button_new_with_label(row->navigation_title);
            g_signal_connect(button, "clicked", G_CALLBACK(navigate_clicked), GINT_TO_POINTER(row->page));
            gtk_flow_box_insert(GTK_FLOW_BOX(actions), button, -1);
        }
        if (row->fix != 0) {
            GtkWidget *button = gtk_button_new_with_label(row->fix_title);
            g_signal_connect(button, "clicked", G_CALLBACK(command_clicked), GINT_TO_POINTER(row->fix));
            gtk_flow_box_insert(GTK_FLOW_BOX(actions), button, -1);
            if (ui.first_fix == NULL) ui.first_fix = button;
        }
        gtk_box_append(GTK_BOX(finding), actions);
        gtk_box_append(GTK_BOX(ui.body), finding);
    }
    gtk_widget_set_sensitive(ui.body, TRUE);
    gtk_widget_set_sensitive(ui.check, TRUE);
}

static gboolean valid_text(const char *text, gsize maximum) {
    return text != NULL && strlen(text) <= maximum && g_utf8_validate(text, -1, NULL);
}

static Report *report_copy(const JSTILinuxTroubleshootingRow *rows, size_t count,
                            const char *summary, guint64 ticket) {
    if (count > 32 || (count != 0 && rows == NULL) || !valid_text(summary, 8192) || summary[0] == '\0')
        return NULL;
    for (gsize i = 0; i < count; ++i) {
        const JSTILinuxTroubleshootingRow *row = &rows[i];
        if (!valid_text(row->title, 512) || !valid_text(row->detail, 16384) ||
            !valid_text(row->status, 32) || !valid_text(row->navigation_title, 128) ||
            !valid_text(row->fix_title, 128) || row->title[0] == '\0' || row->status[0] == '\0' ||
            (row->navigation_page != JSTI_LINUX_TROUBLESHOOTING_API_KEYS &&
             row->navigation_page != JSTI_LINUX_TROUBLESHOOTING_PERMISSIONS &&
             (row->navigation_page < 0 || row->navigation_page >= JSTI_PAGE_COUNT)) ||
            (row->fix_command != 0 && row->fix_command != JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD &&
             row->fix_command != JSTI_LINUX_TROUBLESHOOTING_DISABLE_PROCESSING) ||
            (row->fix_command != 0 && row->fix_title[0] == '\0')) return NULL;
    }
    Report *report = g_new0(Report, 1);
    report->revision = ticket; report->summary = g_strdup(summary); report->count = count;
    report->rows = g_new0(Finding, count);
    for (gsize i = 0; i < count; ++i) {
        Finding *row = &report->rows[i];
        row->title = g_strdup(rows[i].title); row->detail = g_strdup(rows[i].detail);
        row->status = g_strdup(rows[i].status); row->navigation_title = g_strdup(rows[i].navigation_title);
        row->fix_title = g_strdup(rows[i].fix_title);
        row->page = rows[i].navigation_page; row->fix = rows[i].fix_command;
    }
    return report;
}

int32_t jsti_troubleshooting_set_rows(const JSTILinuxTroubleshootingRow *rows, size_t count,
                                      const char *summary, uint64_t ticket) {
    Report *report = report_copy(rows, count, summary, ticket);
    return report == NULL ? -1 : jsti_window_post(report_apply, report, report_free);
}

typedef struct { gint calls, command; guint64 ticket; } Fixture;

static void fixture_callback(int32_t command, uint64_t ticket, void *data) {
    Fixture *fixture = data;
    ++fixture->calls; fixture->command = command; fixture->ticket = ticket;
}

int32_t jsti_troubleshooting_self_test(GtkWindow *owner, char *error, size_t capacity) {
    Fixture fixture = {0};
    g_mutex_lock(&lock);
    jsti_troubleshooting_fn saved_callback = callback;
    gpointer saved_context = context;
    callback = fixture_callback; context = &fixture;
    g_mutex_unlock(&lock);
    jsti_troubleshooting_open(owner);
    JSTILinuxTroubleshootingRow row = {
        "Clipboard", "Synthetic read-only details.", "Warning", "Open General", "Keep transcript",
        JSTI_PAGE_GENERAL, JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD
    };
    Report *report = report_copy(&row, 1, "Synthetic findings.", fixture.ticket);
    report_apply(report); report_free(report);
    GtkWidget *finding = gtk_widget_get_first_child(ui.body);
    GtkWidget *heading = finding == NULL ? NULL : gtk_widget_get_first_child(finding);
    GtkWidget *details = heading == NULL ? NULL : gtk_widget_get_next_sibling(heading);
    gboolean valid = fixture.calls == 1 && fixture.command == JSTI_LINUX_TROUBLESHOOTING_CHECK &&
        ui.first_fix != NULL && !ui.pending && !gtk_window_get_modal(ui.window) &&
        GTK_IS_LABEL(details) && gtk_label_get_selectable(GTK_LABEL(details)) && gtk_label_get_wrap(GTK_LABEL(details));
    if (valid) {
        guint64 old = fixture.ticket;
        g_signal_emit_by_name(ui.first_fix, "clicked");
        valid = fixture.calls == 2 && fixture.command == JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD &&
            ui.pending && gtk_window_get_modal(ui.window) && !gtk_widget_get_sensitive(ui.body);
        report = report_copy(&row, 1, "Stale findings.", old);
        report_apply(report); report_free(report);
        valid = valid && ui.pending;
        jsti_troubleshooting_close();
        jsti_troubleshooting_open(owner);
        report = report_copy(&row, 1, "Late findings.", fixture.ticket - 2);
        report_apply(report); report_free(report);
        valid = valid && ui.pending && ui.first_fix == NULL;
    }
    row.navigation_page = JSTI_LINUX_TROUBLESHOOTING_API_KEYS;
    report = report_copy(&row, 1, "API Keys destination", fixture.ticket);
    valid = valid && report != NULL;
    if (report != NULL) report_free(report);
    row.navigation_page = JSTI_LINUX_TROUBLESHOOTING_PERMISSIONS;
    report = report_copy(&row, 1, "Permissions destination", fixture.ticket);
    valid = valid && report != NULL;
    if (report != NULL) report_free(report);
    row.fix_command = 999;
    valid = valid && jsti_troubleshooting_set_rows(&row, 1, "Invalid", fixture.ticket) == -1;
    row.fix_command = 0;
    row.title = "\xff";
    valid = valid && jsti_troubleshooting_set_rows(&row, 1, "Invalid UTF-8", fixture.ticket) == -1;
    valid = valid && jsti_troubleshooting_set_rows(NULL, 33, "Oversize", fixture.ticket) == -1;
    jsti_troubleshooting_close();
    g_mutex_lock(&lock);
    callback = saved_callback; context = saved_context;
    g_mutex_unlock(&lock);
    if (!valid) { jsti_set_error(error, capacity, "Troubleshooting lifecycle or action fence failed."); return -1; }
    return 0;
}
