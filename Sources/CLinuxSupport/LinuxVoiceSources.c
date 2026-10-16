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
typedef struct {
    gboolean enabled;
    gchar **texts, **descriptions;
    JSTIVoiceMarkupWrapCallback wrap;
} MarkupConfiguration;
static MarkupConfiguration markup_configuration;
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
    GtkWidget *helper, *markup_apply;
    GtkWindow *markup_window;
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
static gboolean can_edit_markup(Dialog *dialog) {
    return markup_configuration.enabled && markup_configuration.wrap != NULL &&
        dialog->window != NULL && dialog->import_token == NULL && (dialog->selected == 1 || dialog->selected == 3);
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
    gtk_widget_set_sensitive(dialog->helper, can_edit_markup(dialog));
    if (dialog->markup_apply != NULL) gtk_widget_set_sensitive(dialog->markup_apply, can_edit_markup(dialog));
    g_free(value);
}
static GtkWidget *label(const char *value);
static void clear_markup(MarkupConfiguration *config) {
    g_strfreev(config->texts); g_strfreev(config->descriptions);
    *config = (MarkupConfiguration){0};
}
typedef struct {
    Dialog *source;
    GtkWindow *window;
    GtkDropDown *examples;
    GtkTextView *example;
    GtkLabel *notice;
    GtkWidget *copy_button;
    MarkupConfiguration config;
    gboolean (*copy)(GtkWidget *, const char *, gpointer);
    gpointer copy_context;
} MarkupHelper;
static gboolean copy_markup(GtkWidget *widget, const char *value, gpointer data) {
    (void)data;
    GdkClipboard *clipboard = gtk_widget_get_clipboard(widget);
    if (clipboard == NULL) return FALSE;
    gdk_clipboard_set_text(clipboard, value);
    return TRUE;
}
static void markup_destroyed(gpointer data) {
    MarkupHelper *helper = data;
    if (helper->source->markup_window == helper->window) {
        helper->source->markup_window = NULL; helper->source->markup_apply = NULL;
    }
    clear_markup(&helper->config); release(helper->source); g_free(helper);
}
static void close_markup(GtkButton *button, gpointer data) {
    (void)button;
    MarkupHelper *helper = data;
    if (helper->source->markup_window == helper->window) {
        helper->source->markup_window = NULL; helper->source->markup_apply = NULL;
    }
    if (helper->source->window != NULL) gtk_widget_grab_focus(GTK_WIDGET(helper->source->editor));
    gtk_window_destroy(helper->window);
}
static gboolean markup_close_request(GtkWindow *window, gpointer data) {
    (void)window; close_markup(NULL, data); return TRUE;
}
static gboolean markup_key(GtkEventControllerKey *controller, guint key, guint code,
                            GdkModifierType state, gpointer data) {
    (void)controller; (void)code; (void)state;
    if (key != GDK_KEY_Escape) return FALSE;
    close_markup(NULL, data); return TRUE;
}
static void select_markup_example(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    MarkupHelper *helper = data;
    guint index = gtk_drop_down_get_selected(helper->examples);
    if (index >= g_strv_length(helper->config.texts)) return;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(helper->example), helper->config.texts[index], -1);
}
static void copy_markup_example(GtkButton *button, gpointer data) {
    MarkupHelper *helper = data;
    guint index = gtk_drop_down_get_selected(helper->examples);
    gboolean copied = index < g_strv_length(helper->config.texts) && helper->copy != NULL &&
        helper->copy(GTK_WIDGET(button), helper->config.texts[index], helper->copy_context);
    gtk_label_set_text(helper->notice, copied ? "Example copied. The draft is unchanged."
        : "The example could not be copied. Try again.");
}
static gboolean apply_markup(MarkupHelper *helper) {
    Dialog *dialog = helper->source;
    if (!can_edit_markup(dialog)) {
        gtk_label_set_text(helper->notice, "Choose an editable draft and enable SSML for a compatible voice.");
        return FALSE;
    }
    gchar *original = text(dialog);
    gsize bytes = strlen(original);
    if (bytes > 1000000) {
        gtk_label_set_text(helper->notice, "The draft is too large to wrap. Its text and selection are unchanged.");
        g_free(original); return FALSE;
    }
    gchar *wrapped = g_malloc0(bytes + 1024);
    int32_t leading_utf16 = 0, leading_scalars = 0;
    gboolean valid = helper->config.wrap != NULL &&
        helper->config.wrap(original, wrapped, bytes + 1024, &leading_utf16, &leading_scalars) == 0 &&
        memchr(wrapped, 0, bytes + 1024) != NULL && g_utf8_validate(wrapped, -1, NULL) &&
        leading_scalars >= 0 && leading_scalars <= g_utf8_strlen(wrapped, -1);
    if (!valid) {
        gtk_label_set_text(helper->notice, "The draft could not be wrapped. Its text and selection are unchanged.");
        g_free(original); g_free(wrapped); return FALSE;
    }
    if (strcmp(original, wrapped) != 0) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
        GtkTextIter insert, bound, start, end;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        gint insert_offset = gtk_text_iter_get_offset(&insert) + leading_scalars;
        gint bound_offset = gtk_text_iter_get_offset(&bound) + leading_scalars;
        gtk_text_buffer_begin_user_action(buffer);
        gtk_text_buffer_get_bounds(buffer, &start, &end); gtk_text_buffer_delete(buffer, &start, &end);
        gtk_text_buffer_get_start_iter(buffer, &start); gtk_text_buffer_insert(buffer, &start, wrapped, -1);
        gtk_text_buffer_end_user_action(buffer);
        gtk_text_buffer_get_iter_at_offset(buffer, &insert, insert_offset);
        gtk_text_buffer_get_iter_at_offset(buffer, &bound, bound_offset);
        gtk_text_buffer_select_range(buffer, &insert, &bound);
    }
    gtk_label_set_text(dialog->notice, "SSML draft updated. No speech was generated or settings saved.");
    g_free(original); g_free(wrapped); return TRUE;
}
static void wrap_markup(GtkButton *button, gpointer data) {
    if (apply_markup(data)) close_markup(button, data);
}
static MarkupHelper *make_markup_helper(Dialog *dialog) {
    if (!can_edit_markup(dialog)) return NULL;
    MarkupHelper *helper = g_new0(MarkupHelper, 1);
    helper->source = retain(dialog); helper->copy = copy_markup;
    helper->config = markup_configuration;
    helper->config.texts = g_strdupv(markup_configuration.texts);
    helper->config.descriptions = g_strdupv(markup_configuration.descriptions);
    helper->window = GTK_WINDOW(gtk_window_new());
    dialog->markup_window = helper->window;
    g_object_set_data_full(G_OBJECT(helper->window), "ssml-helper", helper, markup_destroyed);
    gtk_window_set_title(helper->window, "SSML Helper");
    gtk_window_set_transient_for(helper->window, dialog->window);
    gtk_window_set_modal(helper->window, TRUE); gtk_window_set_destroy_with_parent(helper->window, TRUE);
    gtk_window_set_default_size(helper->window, 510, 425);
    g_signal_connect(helper->window, "close-request", G_CALLBACK(markup_close_request), helper);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(helper->window, box);
    gtk_box_append(GTK_BOX(box), label("Wrap the entire draft with SSML tags. Copy examples to edit manually; "
        "copying does not insert or replace text."));
    gtk_box_append(GTK_BOX(box), label("Common tags"));
    helper->examples = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(
        (const char *const *)helper->config.descriptions));
    gtk_accessible_update_property(GTK_ACCESSIBLE(helper->examples),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Common SSML tags", -1);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(helper->examples));
    helper->example = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(helper->example, FALSE);
    gtk_text_view_set_wrap_mode(helper->example, GTK_WRAP_WORD_CHAR);
    gtk_accessible_update_property(GTK_ACCESSIBLE(helper->example),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "SSML example markup", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(scroll, -1, 90);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(helper->example));
    gtk_box_append(GTK_BOX(box), scroll);
    GtkWidget *copy = gtk_button_new_with_mnemonic("_Copy example");
    helper->copy_button = copy;
    gtk_box_append(GTK_BOX(box), copy);
    helper->notice = GTK_LABEL(label("Closing leaves the draft and its selection unchanged."));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(helper->notice));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *close = gtk_button_new_with_label("Close");
    GtkWidget *wrap = gtk_button_new_with_mnemonic("_Wrap with <speak>");
    dialog->markup_apply = wrap;
    gtk_widget_set_size_request(close, -1, 36); gtk_widget_set_size_request(wrap, -1, 36);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0); gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(actions), close); gtk_box_append(GTK_BOX(actions), spacer);
    gtk_box_append(GTK_BOX(actions), wrap); gtk_box_append(GTK_BOX(box), actions);
    gtk_widget_add_css_class(wrap, "suggested-action"); gtk_window_set_default_widget(helper->window, wrap);
    g_signal_connect(helper->examples, "notify::selected", G_CALLBACK(select_markup_example), helper);
    g_signal_connect(copy, "clicked", G_CALLBACK(copy_markup_example), helper);
    g_signal_connect(close, "clicked", G_CALLBACK(close_markup), helper);
    g_signal_connect(wrap, "clicked", G_CALLBACK(wrap_markup), helper);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(markup_key), helper);
    gtk_widget_add_controller(GTK_WIDGET(helper->window), keys);
    select_markup_example(NULL, NULL, helper);
    return helper;
}
static void show_markup(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->markup_window != NULL) { gtk_window_present(dialog->markup_window); return; }
    MarkupHelper *helper = make_markup_helper(dialog);
    if (helper != NULL) gtk_window_present(helper->window);
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
          "Generate retains the provider's mono PCM16 WAV; Play/Export result reuse it without a provider request. "
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
    g_signal_connect(dialog->helper, "clicked", G_CALLBACK(show_markup), dialog);
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
static void apply_markup_configuration(gpointer data) {
    MarkupConfiguration *changed = data;
    clear_markup(&markup_configuration);
    markup_configuration = *changed;
    changed->texts = NULL; changed->descriptions = NULL;
    if (active != NULL && active->window != NULL) refresh(active);
}
static void free_markup_configuration(gpointer data) {
    MarkupConfiguration *config = data; clear_markup(config); g_free(config);
}
int32_t jsti_window_set_voice_markup_helper(int32_t enabled, const JSTIVoiceMarkupExample *examples,
                                           size_t count, JSTIVoiceMarkupWrapCallback wrap) {
    if ((enabled != 0 && enabled != 1) || examples == NULL || count == 0 || count > 32 || wrap == NULL) return -1;
    MarkupConfiguration *config = g_new0(MarkupConfiguration, 1);
    config->enabled = enabled != 0; config->wrap = wrap;
    config->texts = g_new0(gchar *, count + 1); config->descriptions = g_new0(gchar *, count + 1);
    for (size_t index = 0; index < count; ++index) {
        if (examples[index].text == NULL || examples[index].description == NULL ||
            examples[index].text[0] == '\0' || examples[index].description[0] == '\0' ||
            strlen(examples[index].text) > 8192 || strlen(examples[index].description) > 256 ||
            !g_utf8_validate(examples[index].text, -1, NULL) ||
            !g_utf8_validate(examples[index].description, -1, NULL)) {
            free_markup_configuration(config); return -1;
        }
        config->texts[index] = g_strdup(examples[index].text);
        config->descriptions[index] = g_strdup(examples[index].description);
    }
    return jsti_window_post(apply_markup_configuration, config, free_markup_configuration);
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
static int32_t markup_fixture_wrap(const char *input, char *output, size_t capacity,
                                   int32_t *utf16, int32_t *scalars) {
    if (strcmp(input, "Reject") == 0) return -1;
    gboolean wrapped = strstr(input, "<fixture>") != NULL;
    gchar *result = wrapped ? g_strdup(input) : g_strconcat("<fixture>", input, "</fixture>", NULL);
    if (strlen(result) + 1 > capacity) { g_free(result); return -1; }
    memcpy(output, result, strlen(result) + 1); *utf16 = *scalars = wrapped ? 0 : 9;
    g_free(result); return 0;
}
static gboolean markup_fixture_copy(GtkWidget *widget, const char *value, gpointer data) {
    (void)widget;
    gchar **captured = data; g_free(*captured); *captured = g_strdup(value); return TRUE;
}
static gboolean markup_self_test(Dialog *dialog) {
    MarkupConfiguration original = markup_configuration;
    gchar *original_text = text(dialog);
    guint original_source = dialog->selected;
    const gchar *fixture_texts[] = {"Synthetic & <tag>", "Synthetic \xC9\x99 & <other>", NULL};
    const gchar *fixture_descriptions[] = {"First synthetic example", "Second synthetic example", NULL};
    markup_configuration = (MarkupConfiguration){TRUE, g_strdupv((gchar **)fixture_texts),
        g_strdupv((gchar **)fixture_descriptions), markup_fixture_wrap};
    dialog->selected = 3; refresh(dialog);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
    const gchar *draft = "\xCE\xA9 \xF0\x9F\x98\x80 & <";
    gtk_text_buffer_set_text(buffer, draft, -1);
    GtkTextIter insert, bound;
    gtk_text_buffer_get_iter_at_offset(buffer, &insert, 3);
    gtk_text_buffer_get_iter_at_offset(buffer, &bound, 2);
    gtk_text_buffer_select_range(buffer, &insert, &bound);
    MarkupHelper *helper = make_markup_helper(dialog);
    gboolean passed = helper != NULL;
    gchar *copied = NULL;
    if (helper != NULL) {
        helper->copy = markup_fixture_copy; helper->copy_context = &copied;
        gtk_drop_down_set_selected(helper->examples, 1);
        g_signal_emit_by_name(helper->copy_button, "clicked");
        gchar *unchanged = text(dialog);
        passed = g_strcmp0(copied, fixture_texts[1]) == 0 && strcmp(unchanged, draft) == 0 &&
            gtk_widget_get_focusable(dialog->markup_apply) &&
            gtk_button_get_use_underline(GTK_BUTTON(dialog->markup_apply)) &&
            gtk_window_get_default_widget(helper->window) == dialog->markup_apply && passed;
        g_free(unchanged);
        passed = markup_key(NULL, GDK_KEY_Escape, 0, 0, helper) && passed;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = gtk_text_iter_get_offset(&insert) == 3 && gtk_text_iter_get_offset(&bound) == 2 && passed;
    }
    helper = make_markup_helper(dialog);
    if (helper != NULL) {
        gchar *current = g_strconcat(draft, " newer", NULL);
        gtk_text_buffer_set_text(buffer, current, -1);
        gtk_text_buffer_get_iter_at_offset(buffer, &insert, 3);
        gtk_text_buffer_get_iter_at_offset(buffer, &bound, 2);
        gtk_text_buffer_select_range(buffer, &insert, &bound);
        g_signal_emit_by_name(dialog->markup_apply, "clicked");
        gchar *actual = text(dialog);
        gchar *expected = g_strconcat("<fixture>", current, "</fixture>", NULL);
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = strcmp(actual, expected) == 0 && gtk_text_iter_get_offset(&insert) == 12 &&
            gtk_text_iter_get_offset(&bound) == 11 && passed;
        gtk_text_buffer_undo(buffer);
        gchar *undone = text(dialog);
        passed = strcmp(undone, current) == 0 && passed;
        g_free(actual); g_free(expected); g_free(undone); g_free(current);
    } else passed = FALSE;
    gtk_text_buffer_set_text(buffer, "<fixture>Already wrapped</fixture>", -1);
    gtk_text_buffer_get_iter_at_offset(buffer, &insert, 16);
    gtk_text_buffer_get_iter_at_offset(buffer, &bound, 9);
    gtk_text_buffer_select_range(buffer, &insert, &bound);
    helper = make_markup_helper(dialog);
    if (helper != NULL) {
        passed = apply_markup(helper) && passed;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = gtk_text_iter_get_offset(&insert) == 16 && gtk_text_iter_get_offset(&bound) == 9 && passed;
        gtk_text_buffer_set_text(buffer, "Reject", -1);
        passed = !apply_markup(helper) && passed;
        gchar *unchanged = text(dialog); passed = strcmp(unchanged, "Reject") == 0 && passed; g_free(unchanged);
        markup_configuration.enabled = FALSE; refresh(dialog);
        passed = !gtk_widget_get_sensitive(dialog->helper) &&
            !gtk_widget_get_sensitive(dialog->markup_apply) && !apply_markup(helper) && passed;
        close_markup(NULL, helper);
    } else passed = FALSE;
    markup_configuration.enabled = TRUE;
    for (guint source = 0; source <= 2; source += 2) {
        dialog->selected = source; refresh(dialog);
        passed = !gtk_widget_get_sensitive(dialog->helper) && !can_edit_markup(dialog) && passed;
    }
    dialog->selected = 3; dialog->import_token = g_strdup("synthetic-helper-import"); refresh(dialog);
    passed = !gtk_widget_get_sensitive(dialog->helper) && passed;
    g_clear_pointer(&dialog->import_token, g_free);
    passed = jsti_window_set_voice_markup_helper(2, NULL, 0, NULL) == -1 && passed;
    clear_markup(&markup_configuration); markup_configuration = original;
    dialog->selected = original_source; gtk_text_buffer_set_text(buffer, original_text, -1); refresh(dialog);
    g_free(original_text); g_free(copied);
    return passed;
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
    gboolean markup = markup_self_test(dialog) &&
        received.calls == 4 && received.generated == 1 && received.flags == 2;
    gtk_window_destroy(dialog->window);
    g_free(received.text); g_free(received.record);
    g_free(received.generate_flags); g_free(received.played_result);
    gboolean passed = history && typed && unavailable && history_snapshot && typed_snapshot &&
        clipboard_snapshot && file_snapshot && stale_import && failed_import && edited_import &&
        generated_snapshot && busy_result && retained_result && markup;
    if (!passed) jsti_set_error(error, capacity, "Voice sources state/snapshot checks failed.");
    return passed && jsti_voice_controls_self_test(owner, error, capacity) == 0 &&
        jsti_voice_usage_self_test(owner, error, capacity) == 0
        ? jsti_voice_discovery_self_test(owner, error, capacity) : -1;
}
