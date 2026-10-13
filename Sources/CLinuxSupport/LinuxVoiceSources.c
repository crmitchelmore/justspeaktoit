#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

typedef struct {
    gchar **names;
    JSTIVoiceSourceCallback callback;
    void *context;
} Configuration;
static Configuration configuration;

typedef struct {
    gint refs;
    GtkWindow *window;
    GtkDropDown *source;
    GtkTextView *editor;
    GtkLabel *notice;
    GtkButton *read, *export_button, *load;
    gchar *record, *history, *typed, *clipboard;
    guint selected;
    guint64 revision;
    GCancellable *clipboard_cancel;
    JSTIVoiceSourceCallback callback;
    void *context;
} Dialog;
static Dialog *active;
static Dialog *retain(Dialog *dialog) { ++dialog->refs; return dialog; }
static void release(gpointer data) {
    Dialog *dialog = data;
    if (--dialog->refs != 0) return;
    g_free(dialog->record); g_free(dialog->history); g_free(dialog->typed); g_free(dialog->clipboard);
    g_clear_object(&dialog->clipboard_cancel);
    g_free(dialog);
}
static gchar *text(Dialog *dialog) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
    GtkTextIter start, end; gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}
static void refresh(Dialog *dialog) {
    gchar *value = text(dialog);
    gboolean ready = dialog->selected != 3 && g_strstrip(value)[0] != '\0' &&
        (dialog->selected != 0 || dialog->record[0] != '\0');
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->read), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->export_button), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->load), dialog->selected == 2);
    gtk_text_view_set_editable(dialog->editor, dialog->selected == 1);
    g_free(value);
}
static void changed(GtkTextBuffer *buffer, gpointer data) { (void)buffer; refresh(data); }
static void select_source(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    Dialog *dialog = data;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    if (dialog->selected == 1) { g_free(dialog->typed); dialog->typed = text(dialog); }
    dialog->selected = gtk_drop_down_get_selected(dialog->source);
    ++dialog->revision;
    const gchar *value = dialog->selected == 0 ? dialog->history :
        dialog->selected == 1 ? dialog->typed : dialog->selected == 2 ? dialog->clipboard : "";
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), value, -1);
    gtk_label_set_text(dialog->notice, dialog->selected == 3
        ? "Unavailable: no external selection target was captured. Wayland does not expose a reliable external "
          "selection; X11 insertion targeting is not selection reading. Clipboard is never substituted. "
          "Copy explicitly, then choose Clipboard snapshot."
        : dialog->selected == 0 && dialog->record[0] == '\0'
        ? "Choose a recording in History, then reopen this editor. History is captured when the editor opens."
        : "Read and Export send this text to Deepgram with your saved key. Export writes a 24 kHz mono PCM16 WAV "
          "without playback. Speed is the engine default. Stop cancels synthesis, playback or export.");
    refresh(dialog);
}
typedef struct { Dialog *dialog; guint64 revision; } ClipboardRead;
static void clipboard_finished(GObject *object, GAsyncResult *result, gpointer data) {
    ClipboardRead *read = data;
    Dialog *dialog = read->dialog;
    GError *error = NULL;
    gchar *value = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(object), result, &error);
    if (dialog->window != NULL && dialog->revision == read->revision && dialog->selected == 2) {
        if (error != NULL || value == NULL) {
            gtk_label_set_text(dialog->notice, error != NULL ? error->message : "The clipboard has no text.");
        } else if (g_utf8_strlen(value, -1) > 100000) {
            gtk_label_set_text(dialog->notice, "Clipboard text exceeds 100,000 characters.");
        } else {
            g_free(dialog->clipboard); dialog->clipboard = g_strdup(value);
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), value, -1);
            gtk_label_set_text(dialog->notice, "Clipboard text captured. Later clipboard changes cannot change this snapshot.");
            refresh(dialog);
        }
    }
    g_free(value); g_clear_error(&error); release(dialog); g_free(read);
}
static void load_clipboard(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    g_clear_object(&dialog->clipboard_cancel);
    dialog->clipboard_cancel = g_cancellable_new();
    ClipboardRead *read = g_new0(ClipboardRead, 1);
    g_free(dialog->clipboard); dialog->clipboard = g_strdup("");
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "", -1);
    gtk_label_set_text(dialog->notice, "Reading clipboard text...");
    refresh(dialog);
    read->dialog = retain(dialog); read->revision = ++dialog->revision;
    gdk_clipboard_read_text_async(gtk_widget_get_clipboard(GTK_WIDGET(dialog->window)),
                                  dialog->clipboard_cancel, clipboard_finished, read);
}
static void read_aloud(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    gchar *snapshot = text(dialog);
    dialog->callback(110, (gint32)dialog->selected, snapshot, dialog->selected == 0 ? dialog->record : "",
                     "", dialog->context);
    g_free(snapshot);
}
static void stop(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    dialog->callback(112, 0, "", "", "", dialog->context);
}
typedef struct { Dialog *dialog; gchar *text, *record; guint source; } Export;
static void export_response(GtkNativeDialog *chooser, int response, gpointer data) {
    Export *job = data;
    if (response == GTK_RESPONSE_ACCEPT && job->dialog->window != NULL) {
        GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(chooser));
        gchar *path = file != NULL ? g_file_get_path(file) : NULL;
        if (path != NULL) {
            job->dialog->callback(111, (gint32)job->source, job->text, job->record, path, job->dialog->context);
            gtk_label_set_text(job->dialog->notice,
                "Export started. Check the main window status for its result. Stop cancels it.");
        } else gtk_label_set_text(job->dialog->notice, "Choose a local WAV file for export.");
        g_free(path); g_clear_object(&file);
    }
    gtk_native_dialog_destroy(chooser); g_object_unref(chooser);
    g_free(job->text); g_free(job->record); release(job->dialog); g_free(job);
}
static void export_audio(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    Export *job = g_new0(Export, 1);
    job->dialog = retain(dialog); job->text = text(dialog); job->source = dialog->selected;
    job->record = g_strdup(dialog->selected == 0 ? dialog->record : "");
    GtkFileChooserNative *chooser = gtk_file_chooser_native_new(
        "Export voice audio", dialog->window, GTK_FILE_CHOOSER_ACTION_SAVE, "Export", "Cancel");
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(chooser), "voice-output.wav");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "WAV audio"); gtk_file_filter_add_pattern(filter, "*.wav");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter);
    g_object_unref(filter);
    g_signal_connect(chooser, "response", G_CALLBACK(export_response), job);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
}
static void destroyed(gpointer data) {
    Dialog *dialog = data;
    if (active == dialog) active = NULL;
    dialog->window = NULL; ++dialog->revision; release(dialog);
}
static void close_dialog(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    GtkWindow *window = dialog->window;
    dialog->window = NULL;
    gtk_window_destroy(window);
}
static gboolean close_request(GtkWindow *window, gpointer data) {
    (void)window;
    Dialog *dialog = data; dialog->window = NULL; ++dialog->revision;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    return FALSE;
}
static GtkWidget *label(const char *value) {
    GtkWidget *widget = gtk_label_new(value);
    gtk_label_set_xalign(GTK_LABEL(widget), 0); gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    return widget;
}
static Dialog *make_dialog(GtkWindow *owner, const char *record, const char *history) {
    if (configuration.callback == NULL) return NULL;
    Dialog *dialog = g_new0(Dialog, 1);
    dialog->refs = 1; dialog->record = g_strdup(record != NULL ? record : "");
    dialog->history = g_strdup(history != NULL ? history : "");
    dialog->typed = g_strdup(""); dialog->clipboard = g_strdup("");
    dialog->callback = configuration.callback; dialog->context = configuration.context;
    dialog->window = GTK_WINDOW(gtk_window_new());
    g_object_set_data_full(G_OBJECT(dialog->window), "voice-sources", dialog, destroyed);
    gtk_window_set_title(dialog->window, "Voice Output text and export");
    gtk_window_set_transient_for(dialog->window, owner); gtk_window_set_modal(dialog->window, TRUE);
    gtk_window_set_destroy_with_parent(dialog->window, TRUE);
    g_signal_connect(dialog->window, "close-request", G_CALLBACK(close_request), dialog);
    gtk_window_set_default_size(dialog->window, 680, 580);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(dialog->window, box);
    gtk_box_append(GTK_BOX(box), label("Source"));
    dialog->source = GTK_DROP_DOWN(gtk_drop_down_new_from_strings((const char *const *)configuration.names));
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->source), GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice text source", -1);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->source));
    dialog->load = GTK_BUTTON(gtk_button_new_with_label("Load clipboard"));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->load));
    gtk_box_append(GTK_BOX(box), label("Text snapshot"));
    dialog->editor = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(dialog->editor, GTK_WRAP_WORD_CHAR);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->editor), GTK_ACCESSIBLE_PROPERTY_LABEL, "Voice text snapshot", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE); gtk_widget_set_size_request(scroll, 320, 180);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(dialog->editor));
    gtk_box_append(GTK_BOX(box), scroll);
    dialog->notice = GTK_LABEL(label("")); gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->notice));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    dialog->read = GTK_BUTTON(gtk_button_new_with_label("Read aloud"));
    dialog->export_button = GTK_BUTTON(gtk_button_new_with_label("Export WAV..."));
    GtkWidget *stop_button = gtk_button_new_with_label("Stop");
    GtkWidget *close_button = gtk_button_new_with_label("Close");
    gtk_widget_add_css_class(GTK_WIDGET(dialog->read), "suggested-action");
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->read));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->export_button));
    gtk_box_append(GTK_BOX(actions), stop_button); gtk_box_append(GTK_BOX(actions), close_button);
    gtk_box_append(GTK_BOX(box), actions);
    g_signal_connect(dialog->source, "notify::selected", G_CALLBACK(select_source), dialog);
    g_signal_connect(gtk_text_view_get_buffer(dialog->editor), "changed", G_CALLBACK(changed), dialog);
    g_signal_connect(dialog->load, "clicked", G_CALLBACK(load_clipboard), dialog);
    g_signal_connect(dialog->read, "clicked", G_CALLBACK(read_aloud), dialog);
    g_signal_connect(dialog->export_button, "clicked", G_CALLBACK(export_audio), dialog);
    g_signal_connect(stop_button, "clicked", G_CALLBACK(stop), dialog);
    g_signal_connect(close_button, "clicked", G_CALLBACK(close_dialog), dialog);
    select_source(NULL, NULL, dialog);
    return dialog;
}
void jsti_show_voice_sources(GtkWindow *owner, const char *record, const char *history) {
    Dialog *dialog = make_dialog(owner, record, history);
    if (dialog != NULL) { active = dialog; gtk_window_present(dialog->window); }
}
void jsti_voice_sources_close(void) {
    if (active != NULL && active->window != NULL) {
        GtkWindow *window = active->window;
        if (active->clipboard_cancel != NULL) g_cancellable_cancel(active->clipboard_cancel);
        active->window = NULL; ++active->revision;
        gtk_window_destroy(window);
    }
    active = NULL;
    configuration.callback = NULL; configuration.context = NULL;
}
void jsti_voice_sources_show_fixture(GtkWindow *owner) {
    jsti_show_voice_sources(owner, "", "");
    if (active != NULL) {
        gtk_drop_down_set_selected(active->source, 1);
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(active->editor), "Synthetic typed text for voice output.", -1);
    }
}
int32_t jsti_voice_sources_save_snapshot(const char *path) {
    return active != NULL && active->window != NULL
        ? jsti_window_save_widget_png(GTK_WIDGET(active->window), path, TRUE) : -1;
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
    if (names == NULL || count != 3 || callback == NULL) return -1;
    SetSources *set = g_new0(SetSources, 1);
    set->names = g_new0(gchar *, count + 1); set->callback = callback; set->context = context;
    for (size_t index = 0; index < count; ++index) {
        if (names[index] == NULL || !g_utf8_validate(names[index], -1, NULL)) { free_sources(set); return -1; }
        set->names[index] = g_strdup(names[index]);
    }
    return jsti_window_post(apply_sources, set, free_sources);
}
typedef struct { gint calls, source; gchar *text, *record; } Received;
static void receive_fixture(int32_t action, int32_t source, const char *value,
                             const char *record, const char *path, void *context) {
    (void)path;
    Received *received = context;
    if (action != 110) return;
    ++received->calls; received->source = source;
    g_free(received->text); g_free(received->record);
    received->text = g_strdup(value); received->record = g_strdup(record);
}
int32_t jsti_voice_sources_self_test(GtkWindow *owner, char *error, size_t capacity) {
    Dialog *dialog = make_dialog(owner, "synthetic-record", "Synthetic History snapshot");
    if (dialog == NULL) { jsti_set_error(error, capacity, "Voice sources fixture could not open."); return -1; }
    Received received = {0};
    dialog->callback = receive_fixture; dialog->context = &received;
    gchar *snapshot = text(dialog);
    gboolean history = g_strcmp0(snapshot, "Synthetic History snapshot") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->read));
    g_free(snapshot);
    read_aloud(NULL, dialog);
    gboolean history_snapshot = received.calls == 1 && received.source == 0 &&
        g_strcmp0(received.record, "synthetic-record") == 0 &&
        g_strcmp0(received.text, "Synthetic History snapshot") == 0;
    gtk_drop_down_set_selected(dialog->source, 1);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic typed text", -1);
    gboolean typed = gtk_text_view_get_editable(dialog->editor) &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_button));
    read_aloud(NULL, dialog);
    gboolean typed_snapshot = received.calls == 2 && received.source == 1 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic typed text") == 0;
    gtk_drop_down_set_selected(dialog->source, 2);
    gboolean unavailable = !gtk_widget_get_sensitive(GTK_WIDGET(dialog->read)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_button)) &&
        g_list_model_get_n_items(gtk_drop_down_get_model(dialog->source)) == 3;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic clipboard snapshot", -1);
    read_aloud(NULL, dialog);
    gboolean clipboard_snapshot = received.calls == 3 && received.source == 2 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic clipboard snapshot") == 0;
    gtk_window_destroy(dialog->window);
    g_free(received.text); g_free(received.record);
    gboolean passed = history && typed && unavailable && history_snapshot && typed_snapshot && clipboard_snapshot;
    if (!passed) jsti_set_error(error, capacity, "Voice sources state/snapshot checks failed.");
    return passed ? 0 : -1;
}
