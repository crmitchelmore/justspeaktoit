#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>
#include <math.h>

typedef struct { double speed, pitch; gint ssml, capabilities; gchar *voice; double minimum, maximum; } Options;
static Options saved = {1, 0, 0, 0, NULL, 0.5, 2};
typedef struct {
    GtkWindow *window;
    GtkEntry *speed, *pitch;
    GtkCheckButton *ssml;
    GtkLabel *notice;
    GtkWidget *apply, *reset, *cancel;
    gboolean saving;
    gint capabilities;
    double minimum, maximum;
    gchar *request;
    JSTIVoiceSourceCallback callback;
    void *context;
} Controls;
static Controls *active;
static GtkWidget *label(const char *text) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0); gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    return widget;
}
static void fill(Controls *controls, double speed, double pitch, gboolean ssml) {
    gchar value[G_ASCII_DTOSTR_BUF_SIZE];
    gtk_editable_set_text(GTK_EDITABLE(controls->speed), g_ascii_dtostr(value, sizeof(value), speed));
    gtk_editable_set_text(GTK_EDITABLE(controls->pitch), g_ascii_dtostr(value, sizeof(value), pitch));
    gtk_check_button_set_active(controls->ssml, ssml);
}
static gboolean number(GtkEntry *entry, double *number) {
    const gchar *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    gchar *end = NULL;
    *number = g_ascii_strtod(text, &end);
    while (end != NULL && g_ascii_isspace(*end)) ++end;
    return end != NULL && end != text && *end == '\0' && isfinite(*number);
}
static void normal(GtkButton *button, gpointer data) { (void)button; fill(data, 1, 0, FALSE); }
static void close_controls(GtkButton *button, gpointer data) {
    (void)button; Controls *controls = data;
    if (active == controls) active = NULL;
    gtk_window_destroy(controls->window);
}
static gboolean close_request(GtkWindow *window, gpointer data) {
    (void)window; if (active == data) active = NULL; return FALSE;
}
static gboolean emit(Controls *controls) {
    if (controls->saving) return FALSE;
    double speed = 0, pitch = 0;
    if (!number(controls->speed, &speed) || !number(controls->pitch, &pitch) ||
        speed < controls->minimum || speed > controls->maximum ||
        pitch < -12 || pitch > 12 || round(pitch) != pitch) {
        gtk_label_set_text(controls->notice,
            "Use speed within the displayed limits and a whole-number pitch -12 to 12.");
        return FALSE;
    }
    gchar first[G_ASCII_DTOSTR_BUF_SIZE], second[G_ASCII_DTOSTR_BUF_SIZE];
    gchar *json = g_strdup_printf("{\"speed\":%s,\"pitch\":%s,\"useSSML\":%s}",
        g_ascii_dtostr(first, sizeof(first), speed), g_ascii_dtostr(second, sizeof(second), pitch),
        gtk_check_button_get_active(controls->ssml) ? "true" : "false");
    controls->saving = TRUE;
    controls->request = g_uuid_string_random();
    gtk_widget_set_sensitive(controls->apply, FALSE); gtk_widget_set_sensitive(controls->reset, FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->speed), FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->pitch), FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->ssml), FALSE);
    gtk_label_set_text(controls->notice, "Saving synthesis controls...");
    gtk_button_set_label(GTK_BUTTON(controls->cancel), "Close");
    controls->callback(119, 0, json, controls->request, "", controls->context);
    g_free(json);
    return TRUE;
}
static void save(GtkButton *button, gpointer data) {
    (void)button; Controls *controls = data;
    emit(controls);
}
static void destroyed(gpointer data) {
    if (active == data) active = NULL;
    Controls *controls = data; g_free(controls->request); g_free(controls);
}
static GtkWidget *entry(Controls *controls, GtkWidget *box, const char *name, GtkEntry **target) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *caption = label(name);
    gtk_widget_set_hexpand(caption, TRUE);
    *target = GTK_ENTRY(gtk_entry_new());
    gtk_entry_set_max_length(*target, 63);
    gtk_widget_set_size_request(GTK_WIDGET(*target), 140, 36);
    gtk_accessible_update_property(GTK_ACCESSIBLE(*target), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
    gtk_box_append(GTK_BOX(row), caption); gtk_box_append(GTK_BOX(row), GTK_WIDGET(*target));
    gtk_box_append(GTK_BOX(box), row);
    (void)controls;
    return row;
}
static Controls *make_controls(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    Controls *controls = g_new0(Controls, 1);
    controls->callback = callback; controls->context = context;
    controls->capabilities = saved.capabilities;
    controls->minimum = saved.minimum; controls->maximum = saved.maximum;
    controls->window = GTK_WINDOW(gtk_window_new());
    g_object_set_data_full(G_OBJECT(controls->window), "voice-controls", controls, destroyed);
    gtk_window_set_title(controls->window, "Voice synthesis controls");
    gtk_window_set_transient_for(controls->window, owner); gtk_window_set_modal(controls->window, TRUE);
    gtk_window_set_destroy_with_parent(controls->window, TRUE);
    g_signal_connect(controls->window, "close-request", G_CALLBACK(close_request), controls);
    gtk_window_set_default_size(controls->window, 510, 350);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(controls->window, box);
    gtk_box_append(GTK_BOX(box), label(saved.voice != NULL ? saved.voice : "Deepgram"));
    gchar first[G_ASCII_DTOSTR_BUF_SIZE], second[G_ASCII_DTOSTR_BUF_SIZE];
    gchar *caption = g_strdup_printf("Speed (%s to %s)",
        g_ascii_formatd(first, sizeof(first), "%.15g", saved.minimum),
        g_ascii_formatd(second, sizeof(second), "%.15g", saved.maximum));
    entry(controls, box, caption, &controls->speed); g_free(caption);
    entry(controls, box, "Pitch (-12 to 12 semitones)", &controls->pitch);
    controls->ssml = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Use SSML"));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(controls->ssml));
    controls->notice = GTK_LABEL(label("Unsupported controls stay stored. Normal controls resets them explicitly. "
        "Full SSML documents define their own prosody; use normal sliders or a fragment."));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(controls->notice));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *reset = gtk_button_new_with_label("Normal controls");
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0); gtk_widget_set_hexpand(spacer, TRUE);
    GtkWidget *apply = gtk_button_new_with_label("Save"), *cancel = gtk_button_new_with_label("Cancel");
    controls->apply = apply; controls->reset = reset; controls->cancel = cancel;
    gtk_widget_set_size_request(reset, -1, 36); gtk_widget_set_size_request(apply, -1, 36);
    gtk_widget_set_size_request(cancel, -1, 36); gtk_widget_add_css_class(apply, "suggested-action");
    gtk_box_append(GTK_BOX(actions), reset); gtk_box_append(GTK_BOX(actions), spacer);
    gtk_box_append(GTK_BOX(actions), apply); gtk_box_append(GTK_BOX(actions), cancel);
    gtk_box_append(GTK_BOX(box), actions);
    fill(controls, saved.speed, saved.pitch, saved.ssml);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->speed), saved.capabilities & 1);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->pitch), saved.capabilities & 2);
    gtk_widget_set_sensitive(GTK_WIDGET(controls->ssml), saved.capabilities & 4);
    g_signal_connect(reset, "clicked", G_CALLBACK(normal), controls);
    g_signal_connect(apply, "clicked", G_CALLBACK(save), controls);
    g_signal_connect(cancel, "clicked", G_CALLBACK(close_controls), controls);
    return controls;
}
void jsti_show_voice_controls(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    if (callback != NULL) {
        if (active != NULL) { gtk_window_present(active->window); return; }
        active = make_controls(owner, callback, context); gtk_window_present(active->window);
    }
}
static void apply_options(gpointer data) {
    Options *options = data;
    g_free(saved.voice); saved = *options; options->voice = NULL;
}
static void free_options(gpointer data) { Options *options = data; g_free(options->voice); g_free(options); }
int32_t jsti_window_set_voice_synthesis_options(double speed, double pitch, int32_t ssml,
                                               int32_t capabilities, const char *voice) {
    return jsti_window_set_voice_synthesis_options_with_limits(speed, pitch, ssml, capabilities, voice, 0.5, 2);
}
int32_t jsti_window_set_voice_synthesis_options_with_limits(double speed, double pitch, int32_t ssml,
    int32_t capabilities, const char *voice, double minimum, double maximum) {
    if (!isfinite(speed) || !isfinite(pitch) || ssml < 0 || ssml > 1 || capabilities < 0 || capabilities > 7 ||
        !isfinite(minimum) || !isfinite(maximum) || minimum < 0.5 || minimum > 1 || maximum < 1 || maximum > 2 ||
        !g_utf8_validate(voice != NULL ? voice : "", -1, NULL)) return -1;
    Options *options = g_new0(Options, 1);
    options->speed = speed; options->pitch = pitch; options->ssml = ssml; options->capabilities = capabilities;
    options->voice = g_strdup(voice != NULL ? voice : "");
    options->minimum = minimum; options->maximum = maximum;
    return jsti_window_post(apply_options, options, free_options);
}
typedef struct { gchar *request; gint success; } Completion;
static void finish_options(gpointer data) {
    Completion *completion = data;
    if (active == NULL || !active->saving || g_strcmp0(active->request, completion->request) != 0) return;
    if (completion->success != 0) { GtkWindow *window = active->window; active = NULL; gtk_window_destroy(window); return; }
    active->saving = FALSE;
    g_clear_pointer(&active->request, g_free);
    gtk_widget_set_sensitive(active->apply, TRUE); gtk_widget_set_sensitive(active->reset, TRUE);
    gtk_widget_set_sensitive(GTK_WIDGET(active->speed), active->capabilities & 1);
    gtk_widget_set_sensitive(GTK_WIDGET(active->pitch), active->capabilities & 2);
    gtk_widget_set_sensitive(GTK_WIDGET(active->ssml), active->capabilities & 4);
    gtk_label_set_text(active->notice, "Could not save controls. Previous settings are unchanged. Retry or Cancel.");
    gtk_button_set_label(GTK_BUTTON(active->cancel), "Cancel");
}
static void free_completion(gpointer data) { Completion *completion = data; g_free(completion->request); g_free(completion); }
int32_t jsti_window_finish_voice_synthesis_options(const char *request, int32_t success) {
    if (request == NULL || !g_utf8_validate(request, -1, NULL) || (success != 0 && success != 1)) return -1;
    Completion *value = g_new0(Completion, 1); value->request = g_strdup(request); value->success = success;
    return jsti_window_post(finish_options, value, free_completion);
}

typedef struct { gint calls; gchar *json, *request; } Receipt;
static void receive_fixture(int32_t action, int32_t source, const char *text,
                            const char *request, const char *path, void *context) {
    (void)source; (void)path; Receipt *receipt = context;
    if (action != 119) return;
    ++receipt->calls; g_free(receipt->json); g_free(receipt->request);
    receipt->json = g_strdup(text); receipt->request = g_strdup(request);
}
int32_t jsti_voice_controls_self_test(GtkWindow *owner, char *error, size_t capacity) {
    Options original = saved;
    saved = (Options){1.2345678901234567, -2, 1, 0, g_strdup("Synthetic compatible voice"), 0.5, 2};
    Receipt receipt = {0};
    Controls *controls = make_controls(owner, receive_fixture, &receipt); active = controls;
    double speed = 0;
    gboolean passed = number(controls->speed, &speed) && speed == saved.speed &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->speed)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->pitch)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->ssml));
    normal(NULL, controls);
    passed = emit(controls) && passed && receipt.calls == 1 && receipt.request != NULL &&
        g_strcmp0(receipt.json, "{\"speed\":1,\"pitch\":0,\"useSSML\":false}") == 0 &&
        !gtk_widget_get_sensitive(controls->apply) &&
        g_strcmp0(gtk_button_get_label(GTK_BUTTON(controls->cancel)), "Close") == 0;
    gchar *first = g_strdup(receipt.request);
    Completion obsolete = {"obsolete-request", 1}; finish_options(&obsolete);
    passed = passed && active == controls && controls->saving;
    Completion failed = {first, 0}; finish_options(&failed);
    passed = passed && !controls->saving && gtk_widget_get_sensitive(controls->apply) &&
        g_strcmp0(gtk_button_get_label(GTK_BUTTON(controls->cancel)), "Cancel") == 0;
    gtk_editable_set_text(GTK_EDITABLE(controls->speed), "0.49");
    passed = !emit(controls) && receipt.calls == 1 && passed;
    fill(controls, 1.25, -2, TRUE);
    passed = emit(controls) && passed && g_strcmp0(receipt.request, first) != 0;
    Completion stale = {first, 1}; finish_options(&stale);
    passed = passed && active == controls && controls->saving;
    Completion finished = {receipt.request, 1}; finish_options(&finished);
    passed = passed && active == NULL;
    if (active != NULL) close_controls(NULL, active);
    g_free(first);
    passed = passed &&
        jsti_window_set_voice_synthesis_options_with_limits(1, 0, 0, 1, "Synthetic xAI", NAN, 1.5) == -1 &&
        jsti_window_set_voice_synthesis_options_with_limits(1, 0, 0, 1, "Synthetic xAI", 1.1, 1.5) == -1 &&
        jsti_window_set_voice_synthesis_options_with_limits(1, 0, 0, 1, "Synthetic xAI", 0.7, 0.9) == -1;
    g_free(saved.voice);
    saved = (Options){0.5, 0, 0, 1, g_strdup("Synthetic xAI Eve"), 0.7, 1.5};
    controls = make_controls(owner, receive_fixture, &receipt); active = controls;
    passed = number(controls->speed, &speed) && speed == 0.5 && passed &&
        gtk_widget_get_sensitive(GTK_WIDGET(controls->speed)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->pitch)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->ssml)) && !emit(controls) && receipt.calls == 2;
    fill(controls, 0.7, 0, FALSE);
    passed = emit(controls) && passed && receipt.calls == 3;
    Completion retry = {receipt.request, 0}; finish_options(&retry);
    fill(controls, 1.5, 0, FALSE);
    passed = emit(controls) && passed && receipt.calls == 4;
    Completion upper = {receipt.request, 1}; finish_options(&upper);
    passed = passed && active == NULL;
    if (active != NULL) close_controls(NULL, active);
    g_free(saved.voice);
    saved = (Options){0.5, 0, 0, 1, g_strdup("Synthetic Cartesia Sonic 3.6"), 0.6, 1.5};
    controls = make_controls(owner, receive_fixture, &receipt); active = controls;
    passed = number(controls->speed, &speed) && speed == 0.5 && passed &&
        gtk_widget_get_sensitive(GTK_WIDGET(controls->speed)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->pitch)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(controls->ssml)) && !emit(controls) && receipt.calls == 4;
    fill(controls, 0.6, 0, FALSE);
    passed = emit(controls) && passed && receipt.calls == 5;
    Completion cartesia_retry = {receipt.request, 0}; finish_options(&cartesia_retry);
    fill(controls, 1.5, 0, FALSE);
    passed = emit(controls) && passed && receipt.calls == 6;
    Completion cartesia_upper = {receipt.request, 1}; finish_options(&cartesia_upper);
    passed = passed && active == NULL;
    if (active != NULL) close_controls(NULL, active);
    g_free(receipt.json); g_free(receipt.request);
    g_free(saved.voice); saved = original;
    if (!passed) jsti_set_error(error, capacity, "Voice controls capabilities, precision or save ownership failed.");
    return passed ? 0 : -1;
}
static GtkWindow *snapshot_window;
static void snapshot_callback(int32_t action, int32_t source, const char *text,
                              const char *request, const char *path, void *context) {
    (void)action; (void)source; (void)text; (void)request; (void)path; (void)context;
}
void jsti_voice_controls_show_fixture(GtkWindow *owner) {
    Options original = saved;
    saved = (Options){1.25, 0, 0, 1, g_strdup("Synthetic Cartesia Sonic 3.6"), 0.6, 1.5};
    Controls *controls = make_controls(owner, snapshot_callback, NULL);
    snapshot_window = controls->window;
    g_object_add_weak_pointer(G_OBJECT(snapshot_window), (gpointer *)&snapshot_window);
    gtk_window_present(controls->window);
    g_free(saved.voice); saved = original;
}
int32_t jsti_voice_controls_save_snapshot(const char *path) {
    if (snapshot_window == NULL) return -1;
    const int32_t result = jsti_window_save_widget_png(GTK_WIDGET(snapshot_window), path, TRUE);
    gtk_window_destroy(snapshot_window);
    return result;
}
