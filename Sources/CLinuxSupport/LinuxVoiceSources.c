#include "LinuxVoiceSourcesInternal.h"

typedef struct {
    gchar **names;
    JSTIVoiceSourceCallback callback;
    void *context;
} Configuration;
static Configuration configuration;
MarkupConfiguration markup_configuration;
guint generation_flags;
gboolean generation_working;
gchar *generated_result;
gchar *generated_format;
FormatState format_state;

Dialog *active;
Dialog *retain(Dialog *dialog) { ++dialog->refs; return dialog; }
void release(gpointer data) {
    Dialog *dialog = data;
    if (--dialog->refs != 0) return;
    g_free(dialog->record); g_free(dialog->history); g_free(dialog->typed); g_free(dialog->clipboard);
    g_free(dialog->file); g_free(dialog->import_token);
    g_free(dialog->result_id);
    g_free(dialog->result_format);
    g_clear_object(&dialog->clipboard_cancel);
    g_free(dialog);
}
gchar *text(Dialog *dialog) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
    GtkTextIter start, end; gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}
gboolean can_edit_markup(Dialog *dialog) {
    return markup_configuration.enabled && markup_configuration.wrap != NULL &&
        dialog->window != NULL && dialog->import_token == NULL && (dialog->selected == 1 || dialog->selected == 3);
}
void refresh(Dialog *dialog) {
    gchar *value = text(dialog);
    gboolean ready = !dialog->working && dialog->import_token == NULL && g_strstrip(value)[0] != '\0' &&
        (dialog->selected != 0 || dialog->record[0] != '\0');
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->read), ready);
    guint format_index = dialog->format != NULL ? gtk_drop_down_get_selected(dialog->format) : GTK_INVALID_LIST_POSITION;
    gboolean format_ready = !dialog->format_pending && (format_state.identifiers == NULL ||
        (format_index < g_strv_length(format_state.identifiers) && format_state.identifiers[format_index][0] != '\0'));
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->export_button), ready && format_ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->generate), ready && format_ready);
    gboolean result_ready = !dialog->working && dialog->result_id[0] != '\0';
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->play_result), result_ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->export_result), result_ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->load), dialog->import_token == NULL && dialog->selected >= 2);
    gtk_button_set_label(dialog->load, dialog->selected == 3 ? "Choose file..." : "Load clipboard");
    gtk_text_view_set_editable(dialog->editor, dialog->selected == 1 || dialog->selected == 3);
    gtk_widget_set_sensitive(dialog->helper, can_edit_markup(dialog));
    if (dialog->markup_apply != NULL) gtk_widget_set_sensitive(dialog->markup_apply, can_edit_markup(dialog));
    g_free(value);
}
static void destroyed(gpointer data) {
    Dialog *dialog = data;
    cancel_import(dialog);
    if (active == dialog) active = NULL;
    dialog->window = NULL; ++dialog->revision; release(dialog);
}
static void close_dialog(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    cancel_import(dialog);
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    GtkWindow *window = dialog->window;
    dialog->window = NULL;
    gtk_window_destroy(window);
}
static gboolean close_request(GtkWindow *window, gpointer data) {
    (void)window;
    Dialog *dialog = data; dialog->window = NULL; ++dialog->revision;
    cancel_import(dialog);
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    return FALSE;
}
GtkWidget *label(const char *value) {
    GtkWidget *widget = gtk_label_new(value);
    gtk_label_set_xalign(GTK_LABEL(widget), 0); gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    return widget;
}
Dialog *make_dialog(GtkWindow *owner, const char *record, const char *history) {
    if (configuration.callback == NULL) return NULL;
    Dialog *dialog = g_new0(Dialog, 1);
    dialog->refs = 1; dialog->record = g_strdup(record != NULL ? record : "");
    dialog->history = g_strdup(history != NULL ? history : "");
    dialog->typed = g_strdup(""); dialog->clipboard = g_strdup(""); dialog->file = g_strdup("");
    dialog->result_id = g_strdup(generated_result != NULL ? generated_result : "");
    dialog->result_format = g_strdup(generated_format != NULL ? generated_format : "wav");
    dialog->generation_flags = generation_flags; dialog->working = generation_working;
    dialog->callback = configuration.callback; dialog->context = configuration.context;
    dialog->window = GTK_WINDOW(gtk_window_new());
    g_object_set_data_full(G_OBJECT(dialog->window), "voice-sources", dialog, destroyed);
    gtk_window_set_title(dialog->window, "Voice Output text and export");
    gtk_window_set_transient_for(dialog->window, owner); gtk_window_set_modal(dialog->window, TRUE);
    gtk_window_set_destroy_with_parent(dialog->window, TRUE);
    g_signal_connect(dialog->window, "close-request", G_CALLBACK(close_request), dialog);
    gtk_window_set_default_size(dialog->window, 680, 700);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(dialog->window, box);
    gtk_box_append(GTK_BOX(box), label("Source"));
    dialog->source = GTK_DROP_DOWN(gtk_drop_down_new_from_strings((const char *const *)configuration.names));
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->source), GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice text source", -1);
    GtkWidget *source_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_hexpand(GTK_WIDGET(dialog->source), TRUE);
    gtk_box_append(GTK_BOX(source_row), GTK_WIDGET(dialog->source));
    dialog->load = GTK_BUTTON(gtk_button_new_with_label("Load clipboard"));
    gtk_box_append(GTK_BOX(source_row), GTK_WIDGET(dialog->load));
    gtk_box_append(GTK_BOX(box), source_row);
    GtkWidget *formats = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *format_label = gtk_label_new_with_mnemonic("_File format");
    dialog->format = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));
    gtk_label_set_mnemonic_widget(GTK_LABEL(format_label), GTK_WIDGET(dialog->format));
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->format),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice file format", -1);
    gtk_widget_set_size_request(GTK_WIDGET(dialog->format), -1, 44);
    gtk_widget_set_tooltip_text(GTK_WIDGET(dialog->format),
        "Installed encoder and decoder availability is checked before saving or sending a synthesis request.");
    gtk_box_append(GTK_BOX(formats), format_label); gtk_box_append(GTK_BOX(formats), GTK_WIDGET(dialog->format));
    gtk_box_append(GTK_BOX(box), formats);
    GtkWidget *text_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *text_label = label("Text snapshot"); gtk_widget_set_hexpand(text_label, TRUE);
    dialog->helper = gtk_button_new_with_mnemonic("SSML _Helper...");
    gtk_widget_set_tooltip_text(dialog->helper,
        "Enable Use SSML for a compatible voice, then choose an editable Typed text or File draft.");
    gtk_box_append(GTK_BOX(text_row), text_label); gtk_box_append(GTK_BOX(text_row), dialog->helper);
    gtk_box_append(GTK_BOX(box), text_row);
    dialog->editor = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(dialog->editor, GTK_WRAP_WORD_CHAR);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->editor), GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice text snapshot", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE); gtk_widget_set_size_request(scroll, 320, 180);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(dialog->editor));
    gtk_box_append(GTK_BOX(box), scroll);
    dialog->notice = GTK_LABEL(label("")); gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->notice));
    GtkWidget *usage = gtk_button_new_with_label("Usage and input estimate...");
    gtk_widget_set_size_request(usage, -1, 44);
    GtkWidget *account = gtk_button_new_with_label("Account voices...");
    gtk_widget_set_size_request(account, -1, 44);
    GtkWidget *discovery = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_hexpand(usage, TRUE); gtk_widget_set_hexpand(account, TRUE);
    gtk_box_append(GTK_BOX(discovery), usage); gtk_box_append(GTK_BOX(discovery), account);
    gtk_box_append(GTK_BOX(box), discovery);
    g_signal_connect(usage, "clicked", G_CALLBACK(usage_report), dialog);
    g_signal_connect(account, "clicked", G_CALLBACK(account_voices), dialog);
    GtkWidget *options = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    dialog->auto_play = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Auto-play generated audio"));
    dialog->save = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Save audio to recordings"));
    gtk_check_button_set_active(dialog->auto_play, generation_flags & 1);
    gtk_check_button_set_active(dialog->save, generation_flags & 2);
    gtk_widget_set_size_request(GTK_WIDGET(dialog->auto_play), -1, 44);
    gtk_widget_set_size_request(GTK_WIDGET(dialog->save), -1, 44);
    gtk_widget_set_hexpand(GTK_WIDGET(dialog->auto_play), TRUE);
    gtk_box_append(GTK_BOX(options), GTK_WIDGET(dialog->auto_play));
    gtk_box_append(GTK_BOX(options), GTK_WIDGET(dialog->save)); gtk_box_append(GTK_BOX(box), options);
    GtkWidget *controls = gtk_button_new_with_label("Voice controls...");
    gtk_box_append(GTK_BOX(options), controls);
    g_signal_connect(controls, "clicked", G_CALLBACK(synthesis_controls), dialog);
    GtkWidget *results = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    dialog->generate = GTK_BUTTON(gtk_button_new_with_label("Generate"));
    dialog->play_result = GTK_BUTTON(gtk_button_new_with_label("Play result"));
    dialog->export_result = GTK_BUTTON(gtk_button_new_with_label("Export result..."));
    gtk_widget_add_css_class(GTK_WIDGET(dialog->generate), "suggested-action");
    gtk_box_append(GTK_BOX(results), GTK_WIDGET(dialog->generate));
    gtk_box_append(GTK_BOX(results), GTK_WIDGET(dialog->play_result));
    gtk_box_append(GTK_BOX(results), GTK_WIDGET(dialog->export_result));
    gtk_box_append(GTK_BOX(box), results);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    dialog->read = GTK_BUTTON(gtk_button_new_with_label("Read aloud"));
    dialog->export_button = GTK_BUTTON(gtk_button_new_with_label("Export text..."));
    GtkWidget *stop_button = gtk_button_new_with_label("Stop");
    GtkWidget *close_button = gtk_button_new_with_label("Close");
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->read));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->export_button));
    gtk_box_append(GTK_BOX(actions), stop_button); gtk_box_append(GTK_BOX(actions), close_button);
    gtk_box_append(GTK_BOX(box), actions);
    g_signal_connect(dialog->source, "notify::selected", G_CALLBACK(select_source), dialog);
    g_signal_connect(dialog->format, "notify::selected", G_CALLBACK(format_changed), dialog);
    g_signal_connect(gtk_text_view_get_buffer(dialog->editor), "changed", G_CALLBACK(changed), dialog);
    g_signal_connect(dialog->load, "clicked", G_CALLBACK(load_clipboard), dialog);
    g_signal_connect(dialog->helper, "clicked", G_CALLBACK(show_markup), dialog);
    g_signal_connect(dialog->read, "clicked", G_CALLBACK(voice_read_aloud), dialog);
    g_signal_connect(dialog->export_button, "clicked", G_CALLBACK(export_audio), dialog);
    g_signal_connect(dialog->generate, "clicked", G_CALLBACK(generate_audio), dialog);
    g_signal_connect(dialog->play_result, "clicked", G_CALLBACK(play_result), dialog);
    g_signal_connect(dialog->export_result, "clicked", G_CALLBACK(export_audio), dialog);
    g_signal_connect(dialog->auto_play, "toggled", G_CALLBACK(preferences_changed), dialog);
    g_signal_connect(dialog->save, "toggled", G_CALLBACK(preferences_changed), dialog);
    g_signal_connect(stop_button, "clicked", G_CALLBACK(stop), dialog);
    g_signal_connect(close_button, "clicked", G_CALLBACK(close_dialog), dialog);
    select_source(NULL, NULL, dialog); show_formats(dialog);
    return dialog;
}
void jsti_show_voice_sources(GtkWindow *owner, const char *record, const char *history) {
    Dialog *dialog = make_dialog(owner, record, history);
    if (dialog != NULL) { active = dialog; gtk_window_present(dialog->window); }
}
void jsti_voice_sources_close(void) {
    if (active != NULL && active->window != NULL) {
        GtkWindow *window = active->window;
        cancel_import(active);
        if (active->clipboard_cancel != NULL) g_cancellable_cancel(active->clipboard_cancel);
        active->window = NULL; ++active->revision;
        gtk_window_destroy(window);
    }
    active = NULL;
    configuration.callback = NULL; configuration.context = NULL;
    clear_markup(&markup_configuration);
}
void jsti_voice_sources_show_fixture(GtkWindow *owner) {
    jsti_show_voice_sources(owner, "", "");
    if (active != NULL) {
        gtk_drop_down_set_selected(active->source, 3);
        active->import_token = g_strdup("synthetic-tour-file");
        apply_import_result(active, "synthetic-tour-file", "Synthetic imported UTF-8 text for voice output.", "");
    }
}
int32_t jsti_voice_sources_save_snapshot(const char *path) {
    return active != NULL && active->window != NULL
        ? jsti_widget_save_snapshot(GTK_WIDGET(active->window), path, TRUE) : -1;
}
typedef struct { gchar **names; JSTIVoiceSourceCallback callback; void *context; } SetSources;
static void apply_sources(gpointer data) {
    SetSources *set = data;
    g_strfreev(configuration.names);
    configuration.names = g_steal_pointer(&set->names);
    configuration.callback = set->callback; configuration.context = set->context;
}
static void free_sources(gpointer data) { SetSources *set = data; g_strfreev(set->names); g_free(set); }
int32_t jsti_window_set_voice_sources(const char *const *names, size_t count,
                                      JSTIVoiceSourceCallback callback, void *context) {
    if (names == NULL || count != 4 || callback == NULL) return -1;
    SetSources *set = g_new0(SetSources, 1);
    set->names = g_new0(gchar *, count + 1); set->callback = callback; set->context = context;
    for (size_t index = 0; index < count; ++index) {
        if (names[index] == NULL || !g_utf8_validate(names[index], -1, NULL)) { free_sources(set); return -1; }
        set->names[index] = g_strdup(names[index]);
    }
    return jsti_window_post(apply_sources, set, free_sources);
}
