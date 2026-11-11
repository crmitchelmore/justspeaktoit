/* Voice text in and audio out: file and clipboard import, Read aloud, export,
 * audio formats and generated results. */
#include "LinuxVoiceSourcesInternal.h"

void cancel_import(Dialog *dialog) {
    if (dialog->import_token == NULL) return;
    gchar *token = g_steal_pointer(&dialog->import_token);
    dialog->callback(114, 4, "", token, "", dialog->context);
    g_free(token);
}
void changed(GtkTextBuffer *buffer, gpointer data) {
    (void)buffer;
    Dialog *dialog = data;
    gboolean importing = dialog->import_token != NULL;
    ++dialog->revision; cancel_import(dialog); refresh(dialog);
    if (importing) gtk_label_set_text(dialog->notice, "Text import discarded. Your edits are preserved.");
}
void select_source(GObject *object, GParamSpec *spec, gpointer data) {
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
          "Generate retains the chosen audio container and decoded playback; Play/Export result send no new request. "
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
gboolean apply_import_result(Dialog *dialog, const char *token, const char *value, const char *error) {
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
void load_clipboard(GtkButton *button, gpointer data) {
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
void voice_read_aloud(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->clipboard_cancel != NULL) g_cancellable_cancel(dialog->clipboard_cancel);
    gchar *snapshot = text(dialog);
    dialog->callback(110, dialog->selected == 3 ? 4 : (gint32)dialog->selected,
                     snapshot, dialog->selected == 0 ? dialog->record : "",
                     "", dialog->context);
    g_free(snapshot);
}
void stop(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    ++dialog->revision; cancel_import(dialog); refresh(dialog);
    gtk_label_set_text(dialog->notice, "Stopped. The captured text is unchanged.");
    dialog->callback(112, 0, "", "", "", dialog->context);
}
static void export_response(GtkNativeDialog *chooser, int response, gpointer data) {
    Export *job = data;
    if (response == GTK_RESPONSE_ACCEPT && job->dialog->window != NULL) {
        GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(chooser));
        gchar *path = file != NULL ? g_file_get_path(file) : NULL;
        gchar *lower = path != NULL ? g_ascii_strdown(path, -1) : NULL;
        gchar *suffix = g_strconcat(".", job->format, NULL);
        if (path != NULL && g_str_has_suffix(lower, suffix)) {
            cancel_import(job->dialog);
            job->dialog->callback(job->retained ? 117 : 111, (gint32)job->source,
                                  job->text, job->record, path, job->dialog->context);
            gtk_label_set_text(job->dialog->notice,
                "Export started. Check the main window status for its result. Stop cancels it.");
        } else gtk_label_set_text(job->dialog->notice, "Choose a local file with the selected format's extension.");
        g_free(lower); g_free(suffix); g_free(path); g_clear_object(&file);
    }
    gtk_native_dialog_destroy(chooser); g_object_unref(chooser);
    g_free(job->text); g_free(job->record); g_free(job->format); release(job->dialog); g_free(job);
}
const char *selected_format(Dialog *dialog) {
    guint selected = gtk_drop_down_get_selected(dialog->format);
    if (format_state.identifiers == NULL || selected >= g_strv_length(format_state.identifiers)) return "";
    return format_state.identifiers[selected];
}
void export_audio(GtkButton *button, gpointer data) {
    Dialog *dialog = data;
    Export *job = g_new0(Export, 1);
    job->dialog = retain(dialog); job->text = text(dialog);
    job->retained = button == dialog->export_result;
    job->source = dialog->selected == 3 ? 4 : dialog->selected;
    job->record = g_strdup(job->retained ? dialog->result_id : dialog->selected == 0 ? dialog->record : "");
    job->format = g_strdup(job->retained ? dialog->result_format
        : format_state.identifiers == NULL ? "wav" : selected_format(dialog));
    if (job->format == NULL || job->format[0] == '\0') {
        gtk_label_set_text(dialog->notice, "Choose an available file format first.");
        g_free(job->text); g_free(job->record); g_free(job->format); release(job->dialog); g_free(job); return;
    }
    GtkFileChooserNative *chooser = gtk_file_chooser_native_new(
        "Export voice audio", dialog->window, GTK_FILE_CHOOSER_ACTION_SAVE, "Export", "Cancel");
    gchar *filename = g_strconcat("voice-output.", job->format, NULL);
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(chooser), filename); g_free(filename);
    GtkFileFilter *filter = gtk_file_filter_new();
    gchar *pattern = g_strconcat("*.", job->format, NULL);
    gtk_file_filter_set_name(filter, job->format); gtk_file_filter_add_pattern(filter, pattern); g_free(pattern);
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter);
    g_object_unref(filter);
    g_signal_connect(chooser, "response", G_CALLBACK(export_response), job);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
}
void generate_audio(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    gchar *snapshot = text(dialog);
    const char *format = selected_format(dialog);
    gchar *flags = format[0] != '\0' ? g_strdup_printf("%u|%s", dialog->generation_flags, format)
        : g_strdup_printf("%u", dialog->generation_flags);
    dialog->callback(115, dialog->selected == 3 ? 4 : (gint32)dialog->selected,
                     snapshot, dialog->selected == 0 ? dialog->record : "", flags, dialog->context);
    g_free(snapshot); g_free(flags);
}
void format_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    Dialog *dialog = data;
    if (dialog->applying_options) return;
    const char *identifier = selected_format(dialog);
    if (identifier[0] == '\0') return;
    dialog->format_pending = TRUE; refresh(dialog);
    gtk_label_set_text(dialog->notice, "Checking installed codecs before saving...");
    dialog->callback(118, -1, identifier, "format", "audio-format", dialog->context);
}
void show_formats(Dialog *dialog) {
    dialog->applying_options = TRUE;
    GtkStringList *labels = gtk_string_list_new((const char *const *)format_state.labels);
    gtk_drop_down_set_model(dialog->format, G_LIST_MODEL(labels)); g_object_unref(labels);
    gtk_drop_down_set_selected(dialog->format, format_state.selected);
    dialog->applying_options = FALSE; dialog->format_pending = FALSE;
    if (format_state.status != NULL && format_state.status[0] != '\0')
        gtk_label_set_text(dialog->notice, format_state.status);
    refresh(dialog);
}
void clear_formats(FormatState *value) {
    g_strfreev(value->labels); g_strfreev(value->identifiers); g_free(value->status);
    *value = (FormatState){0};
}
static void free_formats(gpointer data) { clear_formats(data); g_free(data); }
static void apply_formats(gpointer data) {
    FormatState *value = data;
    clear_formats(&format_state); format_state = *value; *value = (FormatState){0};
    if (active != NULL && active->window != NULL) show_formats(active);
}
int32_t jsti_window_set_voice_audio_formats(const char *rows, const char *selected, const char *status) {
    if (rows == NULL || selected == NULL || strlen(rows) > 8192 || strlen(selected) > 256 ||
        !g_utf8_validate(rows, -1, NULL) || !g_utf8_validate(selected, -1, NULL) ||
        !g_utf8_validate(status != NULL ? status : "", -1, NULL)) return -1;
    gchar **lines = g_strsplit(rows, "\n", -1);
    guint count = g_strv_length(lines);
    if (count == 0 || count > 64) { g_strfreev(lines); return -1; }
    FormatState *value = g_new0(FormatState, 1); value->selected = GTK_INVALID_LIST_POSITION;
    value->labels = g_new0(gchar *, count + 2); value->identifiers = g_new0(gchar *, count + 2);
    value->status = g_strdup(status != NULL ? status : "");
    for (guint index = 0; index < count; ++index) {
        gchar *tab = strchr(lines[index], '\t');
        if (tab == NULL || tab == lines[index] || tab - lines[index] > 12) {
            g_strfreev(lines); free_formats(value); return -1;
        }
        *tab = '\0';
        if (strspn(lines[index], "abcdefghijklmnopqrstuvwxyz0123456789") != strlen(lines[index])) {
            g_strfreev(lines); free_formats(value); return -1;
        }
        value->identifiers[index] = g_strdup(lines[index]); value->labels[index] = g_strdup(tab + 1);
        if (strcmp(lines[index], selected) == 0) value->selected = index;
    }
    if (value->selected == GTK_INVALID_LIST_POSITION) {
        value->selected = count; value->identifiers[count] = g_strdup("");
        value->labels[count] = g_strdup("Unavailable stored format");
    }
    g_strfreev(lines); return jsti_window_post(apply_formats, value, free_formats);
}
void play_result(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data; cancel_import(dialog);
    dialog->callback(116, 0, "", dialog->result_id, "", dialog->context);
}
void preferences_changed(GtkCheckButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->applying_options) return;
    dialog->generation_flags = (gtk_check_button_get_active(dialog->auto_play) ? 1 : 0) |
        (gtk_check_button_get_active(dialog->save) ? 2 : 0);
    dialog->callback(118, (gint32)dialog->generation_flags, "", "", "", dialog->context);
}
void synthesis_controls(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    jsti_show_voice_controls(dialog->window, dialog->callback, dialog->context);
}
void usage_report(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    gchar *snapshot = text(dialog);
    if (g_utf8_strlen(snapshot, -1) > 100000) gtk_label_set_text(dialog->notice,
        "Text exceeds 100,000 input characters. Shorten it before opening the usage estimate.");
    else jsti_show_voice_usage(dialog->window, snapshot, dialog->callback, dialog->context);
    g_free(snapshot);
}
void account_voices(GtkButton *button, gpointer data) {
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
typedef struct { gchar *result_id, *message, *format; gboolean working; } GeneratedResult;
static void apply_generated_result(gpointer data) {
    GeneratedResult *result = data;
    g_free(generated_result); generated_result = g_strdup(result->result_id);
    g_free(generated_format); generated_format = g_strdup(result->format);
    generation_working = result->working;
    if (active == NULL || active->window == NULL) return;
    g_free(active->result_id); active->result_id = g_strdup(result->result_id);
    g_free(active->result_format); active->result_format = g_strdup(result->format);
    active->working = result->working;
    gtk_label_set_text(active->notice, result->message); refresh(active);
}
static void free_generated_result(gpointer data) {
    GeneratedResult *result = data;
    g_free(result->result_id); g_free(result->message); g_free(result->format); g_free(result);
}
int32_t jsti_window_set_voice_generated_result(const char *identifier, int32_t working, const char *message) {
    return jsti_window_set_voice_generated_result_with_format(identifier, working, message, "wav");
}
int32_t jsti_window_set_voice_generated_result_with_format(
    const char *identifier, int32_t working, const char *message, const char *format) {
    if (identifier == NULL || strlen(identifier) > 64 || (working != 0 && working != 1) ||
        format == NULL || strlen(format) == 0 || strlen(format) > 12 ||
        strspn(format, "abcdefghijklmnopqrstuvwxyz0123456789") != strlen(format) ||
        !g_utf8_validate(identifier, -1, NULL) || !g_utf8_validate(message != NULL ? message : "", -1, NULL)) return -1;
    GeneratedResult *result = g_new0(GeneratedResult, 1);
    result->result_id = g_strdup(identifier); result->message = g_strdup(message != NULL ? message : "");
    result->format = g_strdup(format);
    result->working = working != 0;
    return jsti_window_post(apply_generated_result, result, free_generated_result);
}
