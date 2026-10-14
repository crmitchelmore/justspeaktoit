#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

typedef struct {
    GtkWindow *window;
    GtkTextView *report;
    GtkCheckButton *tracking;
    gchar *token;
    gboolean applying;
    JSTIVoiceSourceCallback callback;
    void *context;
} Usage;
static Usage *active;
static void destroy_usage(gpointer data) {
    Usage *usage = data;
    if (active == usage) active = NULL;
    g_free(usage->token); g_free(usage);
}
static void close_usage(GtkButton *button, gpointer data) {
    (void)button;
    gtk_window_destroy(((Usage *)data)->window);
}
static void tracking_changed(GtkCheckButton *button, gpointer data) {
    Usage *usage = data;
    if (usage->applying || !gtk_widget_get_sensitive(GTK_WIDGET(button))) return;
    g_free(usage->token); usage->token = g_uuid_string_random();
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    usage->callback(118, gtk_check_button_get_active(button) ? 1 : 0, "", usage->token, "usage-tracking", usage->context);
}
static void apply(Usage *usage, const char *text, gboolean tracking) {
    usage->applying = TRUE;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(usage->report), text, -1);
    gtk_check_button_set_active(usage->tracking, tracking);
    gtk_widget_set_sensitive(GTK_WIDGET(usage->tracking), TRUE);
    usage->applying = FALSE;
}
typedef struct { gchar *token, *text; gboolean tracking; } Report;
static void apply_report(gpointer data) {
    Report *report = data;
    if (active != NULL && g_strcmp0(active->token, report->token) == 0)
        apply(active, report->text, report->tracking);
}
static void free_report(gpointer data) {
    Report *report = data;
    g_free(report->token); g_free(report->text); g_free(report);
}
int32_t jsti_window_set_voice_usage(const char *token, const char *text, int32_t tracking) {
    if (token == NULL || token[0] == '\0' || strlen(token) > 64 || text == NULL || strlen(text) > 32768 ||
        !g_utf8_validate(text, -1, NULL) || (tracking != 0 && tracking != 1)) return -1;
    Report *report = g_new0(Report, 1);
    report->token = g_strdup(token); report->text = g_strdup(text); report->tracking = tracking;
    return jsti_window_post(apply_report, report, free_report);
}
static Usage *make_usage(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    Usage *usage = g_new0(Usage, 1);
    usage->token = g_uuid_string_random(); usage->callback = callback; usage->context = context;
    usage->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(usage->window, "Voice usage and input estimate");
    gtk_window_set_transient_for(usage->window, owner);
    gtk_window_set_modal(usage->window, TRUE);
    gtk_window_set_destroy_with_parent(usage->window, TRUE);
    gtk_window_set_default_size(usage->window, 660, 560);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(usage->window, box);
    GtkWidget *heading = gtk_label_new("Usage report (estimates, not charges)");
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_box_append(GTK_BOX(box), heading);
    usage->report = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(usage->report, FALSE);
    gtk_text_view_set_accepts_tab(usage->report, FALSE);
    gtk_text_view_set_cursor_visible(usage->report, FALSE);
    gtk_text_view_set_wrap_mode(usage->report, GTK_WRAP_WORD_CHAR);
    gtk_accessible_update_property(GTK_ACCESSIBLE(usage->report), GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice usage report", -1);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(usage->report),
        "Loading local usage... No synthesis request is sent.", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE); gtk_widget_set_size_request(scroll, 360, 260);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(usage->report));
    gtk_box_append(GTK_BOX(box), scroll);
    usage->tracking = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Keep local synthesis usage"));
    gtk_widget_set_size_request(GTK_WIDGET(usage->tracking), -1, 44);
    gtk_widget_set_sensitive(GTK_WIDGET(usage->tracking), FALSE);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(usage->tracking));
    GtkWidget *close = gtk_button_new_with_label("Close");
    gtk_widget_set_halign(close, GTK_ALIGN_END);
    gtk_widget_set_size_request(close, 120, 44);
    gtk_box_append(GTK_BOX(box), close);
    g_object_set_data_full(G_OBJECT(usage->window), "voice-usage", usage, destroy_usage);
    g_signal_connect(usage->tracking, "toggled", G_CALLBACK(tracking_changed), usage);
    g_signal_connect(close, "clicked", G_CALLBACK(close_usage), usage);
    active = usage;
    return usage;
}
void jsti_show_voice_usage(GtkWindow *owner, const char *snapshot, JSTIVoiceSourceCallback callback, void *context) {
    if (callback == NULL) return;
    Usage *usage = make_usage(owner, callback, context);
    callback(118, -1, snapshot, usage->token, "usage-report", context);
    gtk_window_present(usage->window);
}
static void fixture_callback(int32_t action, int32_t flag, const char *text, const char *token,
                             const char *path, void *context) {
    (void)text; (void)token;
    if (context != NULL && action == 118 && flag == 0 && g_strcmp0(path, "usage-tracking") == 0) ++*(int *)context;
}
static const char *fixture_text = "Synthetic fixture: no provider calls.\n\n"
    "Captured text: 100 input characters (Unicode scalars).\n"
    "Voice: Harper - MAI-Voice-2.1\nInput estimate: USD 0.0022.\n\n"
    "Estimates are not charges. No provider billing receipts or token counts are available.\n\n"
    "Local requests retained: 2 (latest 1000).\nValidated audio: 1 request; cancelled: 1.\n"
    "Validated audio: 1.25 seconds; 100 input characters.\n"
    "Known-price estimate: USD 0.0022. Unpriced requests excluded: 0.\n\n"
    "Transport attempts do not prove server receipt. Failed/cancelled requests may still be billed.\n"
    "Tracking on: only text-free local metadata is kept.";
int32_t jsti_voice_usage_self_test(GtkWindow *owner, char *error, size_t capacity) {
    int calls = 0;
    Usage *usage = make_usage(owner, fixture_callback, &calls);
    gboolean passed = !gtk_widget_get_sensitive(GTK_WIDGET(usage->tracking));
    apply(usage, fixture_text, TRUE);
    gchar *previous = g_strdup(usage->token);
    gtk_check_button_set_active(usage->tracking, FALSE);
    passed = passed && calls == 1 && !gtk_widget_get_sensitive(GTK_WIDGET(usage->tracking));
    Report stale = {previous, "stale report", TRUE};
    apply_report(&stale);
    passed = passed && !gtk_widget_get_sensitive(GTK_WIDGET(usage->tracking));
    g_free(previous);
    apply(usage, fixture_text, TRUE);
    passed = passed && calls == 1 && gtk_widget_get_sensitive(GTK_WIDGET(usage->tracking));
    Report obsolete = {"obsolete", "wrong", FALSE};
    apply_report(&obsolete);
    passed = passed && gtk_check_button_get_active(usage->tracking);
    gtk_window_destroy(usage->window);
    if (!passed) jsti_set_error(error, capacity, "Voice usage fixture failed opt-out acknowledgement or stale ownership.");
    return passed ? 0 : -1;
}
void jsti_voice_usage_show_fixture(GtkWindow *owner) {
    Usage *usage = make_usage(owner, fixture_callback, NULL);
    apply(usage, fixture_text, TRUE);
    gtk_window_present(usage->window);
}
int32_t jsti_voice_usage_save_snapshot(const char *path) {
    if (active == NULL) return -1;
    int32_t result = jsti_window_save_widget_png(GTK_WIDGET(active->window), path, TRUE);
    gtk_window_destroy(active->window);
    return result;
}
