/* Compare Models' file pickers and confirmations: choosing samples, exporting,
 * copying and deleting saved rounds. Each picker request holds its window, so
 * a late answer for a closed window is dropped. */
#include "LinuxComparisonState.h"
#include <string.h>

PickerRequest *comparison_picker_request(GString *payload, gboolean markdown) {
    Comparison *ui = comparison_ui();
    PickerRequest *request = g_new0(PickerRequest, 1);
    request->window = g_object_ref(ui->window); request->payload = payload; request->markdown = markdown;
    return request;
}

void comparison_free_request(PickerRequest *request) {
    g_object_unref(request->window);
    if (request->payload != NULL) g_string_free(request->payload, TRUE);
    g_free(request);
}

static void picker_error(GError *error) {
    if (error != NULL && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)
        && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED))
        comparison_error(error->message);
    g_clear_error(&error);
}

static void files_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    Comparison *ui = comparison_ui();
    PickerRequest *request = data;
    GString *payload = request->payload;
    GError *error = NULL;
    GListModel *files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);
    if (files != NULL) {
        gboolean valid = g_list_model_get_n_items(files) > 0;
        for (guint i = 0; valid && i < g_list_model_get_n_items(files); ++i) {
            GFile *file = g_list_model_get_item(files, i);
            gchar *path = g_file_get_path(file);
            valid = path != NULL && strpbrk(path, "\r\n\t") == NULL;
            if (valid) { g_string_append_c(payload, '\n'); g_string_append(payload, path); }
            g_free(path); g_object_unref(file);
        }
        if (valid && ui->window == request->window) comparison_emit(102, payload->str, 0);
        else if (ui->window == request->window) comparison_error("Choose local audio files with single-line names.");
        g_object_unref(files);
    }
    if (ui->window == request->window) picker_error(error); else g_clear_error(&error);
    comparison_free_request(request);
}

void comparison_confirm_deletion(PickerRequest *request, const char *response) {
    Comparison *ui = comparison_ui();
    if (strcmp(response, "delete") == 0 && ui->window == request->window
        && gtk_widget_get_sensitive(GTK_WIDGET(ui->delete_round))
        && g_strcmp0(ui->selected, request->payload->str) == 0)
        comparison_emit(120, request->payload->str, 0);
}

static void deletion_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    comparison_confirm_deletion(data, response);
    gtk_window_destroy(GTK_WINDOW(dialog));
}

static void free_deletion_request(gpointer data, GClosure *closure) {
    (void)closure; comparison_free_request(data);
}

void comparison_delete_clicked(GtkButton *button, gpointer data) {
    Comparison *ui = comparison_ui();
    (void)button; (void)data;
    if (ui->selected == NULL || *ui->selected == '\0') return;
    GtkWidget *dialog = adw_message_dialog_new(ui->window, "Delete comparison?",
        "Delete this saved comparison and its app-owned audio? Original imports are not changed.\n\n"
        "A previously synced comparison is also deleted on its other devices when sync is enabled "
        "for its original iCloud account.");
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    g_signal_connect_data(dialog, "response", G_CALLBACK(deletion_response),
        comparison_picker_request(g_string_new(ui->selected), FALSE), free_deletion_request, 0);
    gtk_window_present(GTK_WINDOW(dialog));
}

void comparison_save_export(PickerRequest *request, const char *path) {
    Comparison *ui = comparison_ui();
    if (ui->window != request->window) return;
    if (request->payload != NULL) {
        gchar *payload = g_strdup_printf("%s\n%s", request->payload->str, path);
        comparison_emit(127, payload, request->markdown ? 1 : 0);
        g_free(payload);
    } else comparison_emit(107, path, request->markdown ? 1 : 0);
}

static void export_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    Comparison *ui = comparison_ui();
    PickerRequest *request = data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL && ui->window == request->window) comparison_save_export(request, path);
        else if (ui->window == request->window) comparison_error("Choose a local destination for the comparison export.");
        g_free(path); g_object_unref(file);
    }
    if (ui->window == request->window) picker_error(error); else g_clear_error(&error);
    comparison_free_request(request);
}

void comparison_export_clicked(GtkButton *button, gpointer data) {
    Comparison *ui = comparison_ui();
    (void)data;
    if (gtk_drop_down_get_selected(ui->export_scope) == 1 && (ui->selected == NULL || *ui->selected == '\0')) {
        comparison_error("Select a saved comparison to export."); return;
    }
    gboolean markdown = button == ui->markdown;
    GtkFileDialog *picker = gtk_file_dialog_new();
    gtk_file_dialog_set_title(picker, "Export transcripts and model identities (no audio)");
    gtk_file_dialog_set_initial_name(picker, markdown ? "Comparisons.md" : "Comparisons.json");
    GString *scope = gtk_drop_down_get_selected(ui->export_scope) == 1 ? g_string_new(ui->selected) : NULL;
    gtk_file_dialog_save(picker, ui->window, NULL, export_chosen, comparison_picker_request(scope, markdown));
    g_object_unref(picker);
}

void comparison_copy_export(GtkButton *button, gpointer data) {
    Comparison *ui = comparison_ui();
    (void)data;
    const char *scope = gtk_drop_down_get_selected(ui->export_scope) == 1 ? ui->selected : "";
    if (scope == NULL || (gtk_drop_down_get_selected(ui->export_scope) == 1 && *scope == '\0')) {
        comparison_error("Select a saved comparison to export."); return;
    }
    comparison_emit(126, scope != NULL ? scope : "", button == ui->copy_markdown ? 1 : 0);
}

void comparison_choose_samples(GString *payload) {
    Comparison *ui = comparison_ui();
    GtkFileDialog *picker = gtk_file_dialog_new();
    gtk_file_dialog_set_title(picker, "Choose one sample, or multiple samples for Batch");
    gtk_file_dialog_open_multiple(picker, ui->window, NULL, files_chosen, comparison_picker_request(payload, FALSE));
    g_object_unref(picker);
}
