#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>
void jsti_show_voice_controls(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_usage(GtkWindow *owner, const char *snapshot, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context);

typedef struct {
    gchar **names;
    JSTIVoiceSourceCallback callback;
    void *context;
} Configuration;
static Configuration configuration;
static guint generation_flags;
static gboolean generation_working;
static gchar *generated_result;

typedef struct {
    gint refs;
    GtkWindow *window;
    GtkDropDown *source;
    GtkTextView *editor;
    GtkLabel *notice;
    GtkButton *read, *export_button, *load;
    GtkButton *generate, *play_result, *export_result;
    GtkCheckButton *auto_play, *save;
    gchar *result_id;
    guint generation_flags;
    gboolean working, applying_options;
    gchar *record, *history, *typed, *clipboard, *file, *import_token;
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
    g_free(dialog->file); g_free(dialog->import_token);
    g_free(dialog->result_id);
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
    gboolean ready = !dialog->working && dialog->import_token == NULL && g_strstrip(value)[0] != '\0' &&
        (dialog->selected != 0 || dialog->record[0] != '\0');
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->read), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->export_button), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->generate), ready);
    gboolean result_ready = !dialog->working && dialog->result_id[0] != '\0';
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->play_result), result_ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->export_result), result_ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->load), dialog->import_token == NULL && dialog->selected >= 2);
    gtk_button_set_label(dialog->load, dialog->selected == 3 ? "Choose file..." : "Load clipboard");
    gtk_text_view_set_editable(dialog->editor, dialog->selected == 1 || dialog->selected == 3);
    g_free(value);
}
static void cancel_import(Dialog *dialog) {
    if (dialog->import_token == NULL) return;
    gchar *token = g_steal_pointer(&dialog->import_token);
    dialog->callback(114, 4, "", token, "", dialog->context);
    g_free(token);
}
static void changed(GtkTextBuffer *buffer, gpointer data) {
    (void)buffer;
    Dialog *dialog = data;
    gboolean importing = dialog->import_token != NULL;
    ++dialog->revision; cancel_import(dialog); refresh(dialog);
    if (importing) gtk_label_set_text(dialog->notice, "Text import discarded. Your edits are preserved.");
}
static void select_source(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    Dialog *dialog = data;
    cancel_import(dialog);
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    if (dialog->selected == 1) { g_free(dialog->typed); dialog->typed = text(dialog); }
    if (dialog->selected == 3) { g_free(dialog->file); dialog->file = text(dialog); }
    dialog->selected = gtk_drop_down_get_selected(dialog->source);
    ++dialog->revision;
    const gchar *value = dialog->selected == 0 ? dialog->history :
        dialog->selected == 1 ? dialog->typed : dialog->selected == 2 ? dialog->clipboard : dialog->file;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), value, -1);
    gtk_label_set_text(dialog->notice, dialog->selected == 0 && dialog->record[0] == '\0'
        ? "Choose a recording in History, then reopen this editor. History is captured when the editor opens."
        : "Read, Generate and Export text send this snapshot to the selected voice provider with your saved key. "
          "Generate retains a 24 kHz mono PCM16 WAV; Play/Export result reuse it without a provider request. "
          "Voice controls show the selected route's actual capabilities. Stop cancels active voice work.");
    refresh(dialog);
}
typedef struct { Dialog *dialog; guint64 revision; } ImportChoice;
static void import_response(GtkNativeDialog *chooser, int response, gpointer data) {
    ImportChoice *choice = data;
    Dialog *dialog = choice->dialog;
    if (response == GTK_RESPONSE_ACCEPT && dialog->window != NULL &&
        dialog->selected == 3 && dialog->revision == choice->revision) {
        GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(chooser));
        gchar *path = file != NULL ? g_file_get_path(file) : NULL;
        if (path != NULL && g_utf8_validate(path, -1, NULL)) {
            cancel_import(dialog);
            dialog->import_token = g_uuid_string_random();
            gtk_label_set_text(dialog->notice,
                "Reading UTF-8 text... Stop cancels. Editing or changing source discards the result.");
            refresh(dialog);
            dialog->callback(113, 4, "", dialog->import_token, path, dialog->context);
        } else gtk_label_set_text(dialog->notice, "Choose a local text file with a UTF-8 path.");
        g_free(path); g_clear_object(&file);
    }
    gtk_native_dialog_destroy(chooser); g_object_unref(chooser);
    release(dialog); g_free(choice);
}
static void import_file(Dialog *dialog) {
    ImportChoice *choice = g_new0(ImportChoice, 1);
    choice->dialog = retain(dialog); choice->revision = ++dialog->revision;
    GtkFileChooserNative *chooser = gtk_file_chooser_native_new(
        "Import UTF-8 text", dialog->window, GTK_FILE_CHOOSER_ACTION_OPEN, "Import", "Cancel");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Text files");
    gtk_file_filter_add_mime_type(filter, "text/plain");
    gtk_file_filter_add_pattern(filter, "*.txt"); gtk_file_filter_add_pattern(filter, "*.md");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter); g_object_unref(filter);
    filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "All files"); gtk_file_filter_add_pattern(filter, "*");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter); g_object_unref(filter);
    g_signal_connect(chooser, "response", G_CALLBACK(import_response), choice);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
}
static gboolean apply_import_result(Dialog *dialog, const char *token, const char *value, const char *error) {
    if (dialog == NULL || dialog->window == NULL || dialog->selected != 3 ||
        g_strcmp0(dialog->import_token, token) != 0) return FALSE;
    g_clear_pointer(&dialog->import_token, g_free);
    if (error[0] == '\0') {
        g_free(dialog->file); dialog->file = g_strdup(value);
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), value, -1);
        gtk_label_set_text(dialog->notice,
            "Text file captured. You can edit it; later file changes do not change this snapshot.");
    } else {
        gchar *notice = g_strdup_printf("%s Existing text is unchanged.", error);
        gtk_label_set_text(dialog->notice, notice); g_free(notice);
    }
    refresh(dialog);
    return TRUE;
}
typedef struct { gchar *token, *text, *error; } ImportResult;
static void apply_import(gpointer data) {
    ImportResult *result = data;
    apply_import_result(active, result->token, result->text, result->error);
}
static void free_import(gpointer data) {
    ImportResult *result = data;
    g_free(result->token); g_free(result->text); g_free(result->error); g_free(result);
}
int32_t jsti_window_set_voice_text_import(const char *token, const char *value, const char *error) {
    if (token == NULL || token[0] == '\0' || strlen(token) > 64 ||
        !g_utf8_validate(value != NULL ? value : "", -1, NULL) ||
        !g_utf8_validate(error != NULL ? error : "", -1, NULL)) return -1;
    ImportResult *result = g_new0(ImportResult, 1);
    result->token = g_strdup(token); result->text = g_strdup(value != NULL ? value : "");
    result->error = g_strdup(error != NULL ? error : "");
    return jsti_window_post(apply_import, result, free_import);
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
    if (dialog->selected == 3) { import_file(dialog); return; }
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
    dialog->callback(110, dialog->selected == 3 ? 4 : (gint32)dialog->selected,
                     snapshot, dialog->selected == 0 ? dialog->record : "",
                     "", dialog->context);
    g_free(snapshot);
}
static void stop(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    ++dialog->revision; cancel_import(dialog); refresh(dialog);
    gtk_label_set_text(dialog->notice, "Stopped. The captured text is unchanged.");
    dialog->callback(112, 0, "", "", "", dialog->context);
}
typedef struct { Dialog *dialog; gchar *text, *record; guint source; gboolean retained; } Export;
static void export_response(GtkNativeDialog *chooser, int response, gpointer data) {
    Export *job = data;
    if (response == GTK_RESPONSE_ACCEPT && job->dialog->window != NULL) {
        GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(chooser));
        gchar *path = file != NULL ? g_file_get_path(file) : NULL;
        if (path != NULL) {
            cancel_import(job->dialog);
            job->dialog->callback(job->retained ? 117 : 111, (gint32)job->source,
                                  job->text, job->record, path, job->dialog->context);
            gtk_label_set_text(job->dialog->notice,
                "Export started. Check the main window status for its result. Stop cancels it.");
        } else gtk_label_set_text(job->dialog->notice, "Choose a local WAV file for export.");
        g_free(path); g_clear_object(&file);
    }
    gtk_native_dialog_destroy(chooser); g_object_unref(chooser);
    g_free(job->text); g_free(job->record); release(job->dialog); g_free(job);
}
static void export_audio(GtkButton *button, gpointer data) {
    Dialog *dialog = data;
    Export *job = g_new0(Export, 1);
    job->dialog = retain(dialog); job->text = text(dialog);
    job->retained = button == dialog->export_result;
    job->source = dialog->selected == 3 ? 4 : dialog->selected;
    job->record = g_strdup(job->retained ? dialog->result_id : dialog->selected == 0 ? dialog->record : "");
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
static void generate_audio(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    gchar *snapshot = text(dialog);
    gchar *flags = g_strdup_printf("%u", dialog->generation_flags);
    dialog->callback(115, dialog->selected == 3 ? 4 : (gint32)dialog->selected,
                     snapshot, dialog->selected == 0 ? dialog->record : "", flags, dialog->context);
    g_free(snapshot); g_free(flags);
}
static void play_result(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data; cancel_import(dialog);
    dialog->callback(116, 0, "", dialog->result_id, "", dialog->context);
}
static void preferences_changed(GtkCheckButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->applying_options) return;
    dialog->generation_flags = (gtk_check_button_get_active(dialog->auto_play) ? 1 : 0) |
        (gtk_check_button_get_active(dialog->save) ? 2 : 0);
    dialog->callback(118, (gint32)dialog->generation_flags, "", "", "", dialog->context);
}
static void synthesis_controls(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    jsti_show_voice_controls(dialog->window, dialog->callback, dialog->context);
}
static void usage_report(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    gchar *snapshot = text(dialog);
    if (g_utf8_strlen(snapshot, -1) > 100000) gtk_label_set_text(dialog->notice,
        "Text exceeds 100,000 input characters. Shorten it before opening the usage estimate.");
    else jsti_show_voice_usage(dialog->window, snapshot, dialog->callback, dialog->context);
    g_free(snapshot);
}
static void account_voices(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    jsti_show_voice_discovery(dialog->window, dialog->callback, dialog->context);
}
static void apply_generation_options(gpointer data) {
    generation_flags = *(guint *)data;
    if (active == NULL || active->window == NULL) return;
    active->generation_flags = generation_flags; active->applying_options = TRUE;
    gtk_check_button_set_active(active->auto_play, generation_flags & 1);
    gtk_check_button_set_active(active->save, generation_flags & 2);
    active->applying_options = FALSE;
}
int32_t jsti_window_set_voice_generation_options(int32_t flags) {
    if (flags < 0 || flags > 3) return -1;
    guint *value = g_new(guint, 1); *value = (guint)flags;
    return jsti_window_post(apply_generation_options, value, g_free);
}
typedef struct { gchar *result_id, *message; gboolean working; } GeneratedResult;
static void apply_generated_result(gpointer data) {
    GeneratedResult *result = data;
    g_free(generated_result); generated_result = g_strdup(result->result_id);
    generation_working = result->working;
    if (active == NULL || active->window == NULL) return;
    g_free(active->result_id); active->result_id = g_strdup(result->result_id);
    active->working = result->working;
    gtk_label_set_text(active->notice, result->message); refresh(active);
}
static void free_generated_result(gpointer data) {
    GeneratedResult *result = data;
    g_free(result->result_id); g_free(result->message); g_free(result);
}
int32_t jsti_window_set_voice_generated_result(const char *identifier, int32_t working, const char *message) {
    if (identifier == NULL || strlen(identifier) > 64 || (working != 0 && working != 1) ||
        !g_utf8_validate(identifier, -1, NULL) || !g_utf8_validate(message != NULL ? message : "", -1, NULL)) return -1;
    GeneratedResult *result = g_new0(GeneratedResult, 1);
    result->result_id = g_strdup(identifier); result->message = g_strdup(message != NULL ? message : "");
    result->working = working != 0;
    return jsti_window_post(apply_generated_result, result, free_generated_result);
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
    dialog->typed = g_strdup(""); dialog->clipboard = g_strdup(""); dialog->file = g_strdup("");
    dialog->result_id = g_strdup(generated_result != NULL ? generated_result : "");
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
    gtk_box_append(GTK_BOX(box), label("Text snapshot"));
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
    GtkWidget *account = gtk_button_new_with_label("xAI account voices...");
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
    dialog->export_button = GTK_BUTTON(gtk_button_new_with_label("Export text WAV..."));
    GtkWidget *stop_button = gtk_button_new_with_label("Stop");
    GtkWidget *close_button = gtk_button_new_with_label("Close");
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->read));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dialog->export_button));
    gtk_box_append(GTK_BOX(actions), stop_button); gtk_box_append(GTK_BOX(actions), close_button);
    gtk_box_append(GTK_BOX(box), actions);
    g_signal_connect(dialog->source, "notify::selected", G_CALLBACK(select_source), dialog);
    g_signal_connect(gtk_text_view_get_buffer(dialog->editor), "changed", G_CALLBACK(changed), dialog);
    g_signal_connect(dialog->load, "clicked", G_CALLBACK(load_clipboard), dialog);
    g_signal_connect(dialog->read, "clicked", G_CALLBACK(read_aloud), dialog);
    g_signal_connect(dialog->export_button, "clicked", G_CALLBACK(export_audio), dialog);
    g_signal_connect(dialog->generate, "clicked", G_CALLBACK(generate_audio), dialog);
    g_signal_connect(dialog->play_result, "clicked", G_CALLBACK(play_result), dialog);
    g_signal_connect(dialog->export_result, "clicked", G_CALLBACK(export_audio), dialog);
    g_signal_connect(dialog->auto_play, "toggled", G_CALLBACK(preferences_changed), dialog);
    g_signal_connect(dialog->save, "toggled", G_CALLBACK(preferences_changed), dialog);
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
        cancel_import(active);
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
typedef struct {
    gint calls, source, generated, flags;
    gchar *text, *record, *generate_flags, *played_result;
} Received;
static void receive_fixture(int32_t action, int32_t source, const char *value,
                             const char *record, const char *path, void *context) {
    Received *received = context;
    if (action == 115) { ++received->generated; g_free(received->generate_flags); received->generate_flags = g_strdup(path); }
    if (action == 116) { g_free(received->played_result); received->played_result = g_strdup(record); }
    if (action == 118) received->flags = source;
    if (action != 110) return;
    ++received->calls; received->source = source;
    g_free(received->text); g_free(received->record);
    received->text = g_strdup(value); received->record = g_strdup(record);
}
int32_t jsti_voice_controls_self_test(GtkWindow *owner, char *error, size_t capacity);
int32_t jsti_voice_usage_self_test(GtkWindow *owner, char *error, size_t capacity);
int32_t jsti_voice_discovery_self_test(GtkWindow *owner, char *error, size_t capacity);
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
        g_list_model_get_n_items(gtk_drop_down_get_model(dialog->source)) == 4;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic clipboard snapshot", -1);
    read_aloud(NULL, dialog);
    gboolean clipboard_snapshot = received.calls == 3 && received.source == 2 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic clipboard snapshot") == 0;
    gtk_drop_down_set_selected(dialog->source, 3);
    dialog->import_token = g_strdup("synthetic-import");
    gboolean imported = apply_import_result(dialog, "synthetic-import", "Synthetic file text", "");
    read_aloud(NULL, dialog);
    gboolean file_snapshot = imported && received.calls == 4 && received.source == 4 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic file text") == 0 &&
        gtk_text_view_get_editable(dialog->editor);
    gboolean stale_import = !apply_import_result(dialog, "synthetic-import", "Stale text", "");
    dialog->import_token = g_strdup("synthetic-failure");
    apply_import_result(dialog, "synthetic-failure", "", "Synthetic read error.");
    gchar *unchanged = text(dialog);
    gboolean failed_import = g_strcmp0(unchanged, "Synthetic file text") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->read));
    g_free(unchanged);
    dialog->import_token = g_strdup("synthetic-edit");
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic user edit", -1);
    gboolean edited_import = !apply_import_result(dialog, "synthetic-edit", "Late text", "");
    gtk_check_button_set_active(dialog->auto_play, FALSE);
    gtk_check_button_set_active(dialog->save, TRUE);
    preferences_changed(NULL, dialog);
    generate_audio(NULL, dialog);
    gboolean generated_snapshot = received.generated == 1 && received.flags == 2 &&
        g_strcmp0(received.generate_flags, "2") == 0;
    dialog->working = TRUE; refresh(dialog);
    gboolean busy_result = !gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->play_result));
    dialog->working = FALSE;
    g_free(dialog->result_id); dialog->result_id = g_strdup("synthetic-result"); refresh(dialog);
    play_result(NULL, dialog);
    gboolean retained_result = g_strcmp0(received.played_result, "synthetic-result") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_result));
    gtk_window_destroy(dialog->window);
    g_free(received.text); g_free(received.record);
    g_free(received.generate_flags); g_free(received.played_result);
    gboolean passed = history && typed && unavailable && history_snapshot && typed_snapshot &&
        clipboard_snapshot && file_snapshot && stale_import && failed_import && edited_import &&
        generated_snapshot && busy_result && retained_result;
    if (!passed) jsti_set_error(error, capacity, "Voice sources state/snapshot checks failed.");
    return passed && jsti_voice_controls_self_test(owner, error, capacity) == 0 &&
        jsti_voice_usage_self_test(owner, error, capacity) == 0
        ? jsti_voice_discovery_self_test(owner, error, capacity) : -1;
}
