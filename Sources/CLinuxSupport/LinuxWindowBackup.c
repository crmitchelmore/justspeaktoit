/* General > Recordings and backup: folder choice, migration backup, audio cleanup, export and import. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowStoragePage.h"

static StoragePage storage_state;
StoragePage *storage_page(void) { return &storage_state; }

_Static_assert(JSTI_EVENT_RECORDINGS_LOCATION != JSTI_EVENT_MIGRATION_RESTORE,
               "the recordings location choice must not decode as Migration restore");

void on_recordings_folder(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_RECORDINGS_FOLDER, "", 0);
}

typedef struct LocationChoice {
    GWeakRef parent;
    GCancellable *cancelled;
} LocationChoice;

static void recordings_location_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    LocationChoice *choice = data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, &error);
    GObject *parent = g_weak_ref_get(&choice->parent);
    gboolean active = parent != NULL && parent == G_OBJECT(ui.window) && !ui.closing &&
        storage_page()->location_chooser == choice->cancelled && !g_cancellable_is_cancelled(choice->cancelled);
    if (storage_page()->location_chooser == choice->cancelled) g_clear_object(&storage_page()->location_chooser);
    if (active) {
        if (file != NULL) {
            gchar *path = g_file_get_path(file);
            if (path != NULL) emit(JSTI_EVENT_RECORDINGS_LOCATION, path, 0);
            else jsti_window_update("Choose a local folder. This portal did not provide a local path.", NULL, -1);
            g_free(path);
        } else if (error != NULL && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED)) {
            gchar *message = g_strdup_printf("Could not choose a recordings folder: %s", error->message);
            jsti_window_update(message, NULL, -1);
            g_free(message);
        }
        refresh_actions();
    }
    g_clear_error(&error);
    g_clear_object(&file);
    g_clear_object(&parent);
    g_weak_ref_clear(&choice->parent);
    g_object_unref(choice->cancelled);
    g_free(choice);
}

void on_recordings_choose(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.closing || ui.state != 0 || storage_page()->location_chooser != NULL) return;
    LocationChoice *choice = g_new0(LocationChoice, 1);
    g_weak_ref_init(&choice->parent, G_OBJECT(ui.window));
    choice->cancelled = g_cancellable_new();
    storage_page()->location_chooser = g_object_ref(choice->cancelled);
    refresh_actions();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose where new recordings are saved (existing audio is not moved)");
    gtk_file_dialog_select_folder(dialog, ui.window, choice->cancelled, recordings_location_chosen, choice);
    g_object_unref(dialog);
}

void on_recordings_default(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.closing || ui.state != 0 || storage_page()->location_chooser != NULL) return;
    emit(JSTI_EVENT_RECORDINGS_LOCATION, "", 0);
}

void on_audio_cleanup(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_AUDIO_CLEANUP, "", 0);
}

gboolean backup_choice_active(const BackupChoice *choice, GObject *parent) {
    return parent != NULL && parent == G_OBJECT(ui.window) && !ui.closing &&
        storage_page()->backup_chooser == choice->cancelled && !g_cancellable_is_cancelled(choice->cancelled);
}

void backup_emit_path(const BackupChoice *choice, const char *path) {
    const gint32 events[] = {JSTI_EVENT_MIGRATION_EXPORT, JSTI_EVENT_MIGRATION_INSPECT, JSTI_EVENT_MIGRATION_RESTORE};
    if (choice->action < 0 || choice->action >= (gint)G_N_ELEMENTS(events)) {
        jsti_window_update("Could not choose backup action: invalid request.", NULL, -1);
        return;
    }
    emit(events[choice->action], path, choice->action != 0 ? 0 : (choice->include_audio | choice->include_profiles));
}

static void backup_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    BackupChoice *choice = data;
    GError *error = NULL;
    GFile *file = choice->action != 0 ? gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error)
                                : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    GObject *parent = g_weak_ref_get(&choice->parent);
    gboolean active = backup_choice_active(choice, parent);
    if (storage_page()->backup_chooser == choice->cancelled) g_clear_object(&storage_page()->backup_chooser);
    if (active) {
        if (file != NULL) {
            gchar *path = g_file_get_path(file);
            if (path != NULL) backup_emit_path(choice, path);
            else jsti_window_update("Choose a local ZIP file. This portal did not provide a local path.", NULL, -1);
            g_free(path);
        } else if (error == NULL) {
            jsti_window_update("The backup picker returned no file or error. Choose a local ZIP path.",
                               NULL, -1);
        } else if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED)) {
            gchar *message = g_strdup_printf("Could not choose backup file: %s", error->message);
            jsti_window_update(message, NULL, -1);
            g_free(message);
        }
        refresh_actions();
    }
    g_clear_error(&error);
    g_clear_object(&file);
    g_clear_object(&parent);
    g_weak_ref_clear(&choice->parent);
    g_object_unref(choice->cancelled);
    g_free(choice);
}

void on_backup(GtkButton *button, gpointer data) {
    (void)button;
    if (ui.closing || ui.state != 0 || storage_page()->backup_chooser != NULL || storage_page()->restore_dialog != NULL) return;
    BackupChoice *choice = g_new0(BackupChoice, 1);
    g_weak_ref_init(&choice->parent, G_OBJECT(ui.window));
    choice->cancelled = g_cancellable_new();
    choice->include_audio = adw_switch_row_get_active(storage_page()->backup_audio) ? 1 : 0;
    choice->include_profiles = adw_switch_row_get_active(storage_page()->backup_profiles) ? 2 : 0;
    choice->action = GPOINTER_TO_INT(data);
    storage_page()->backup_chooser = g_object_ref(choice->cancelled);
    refresh_actions();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, choice->action == 2 ? "Restore backup (preview before changes)"
        : choice->action == 1 ? "Inspect backup (no data will be imported)"
                             : "Save ZIP backup (existing files are never replaced)");
    if (choice->action == 0) gtk_file_dialog_set_initial_name(dialog, "JustSpeakToIt-History.zip");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "ZIP backups");
    gtk_file_filter_add_pattern(filter, "*.zip");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_set_default_filter(dialog, filter);
    if (choice->action != 0) gtk_file_dialog_open(dialog, ui.window, choice->cancelled, backup_chosen, choice);
    else gtk_file_dialog_save(dialog, ui.window, choice->cancelled, backup_chosen, choice);
    g_object_unref(filters);
    g_object_unref(filter);
    g_object_unref(dialog);
}

void audio_cleanup_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    const char *token = g_object_get_data(G_OBJECT(dialog), "jsti-audio-cleanup-token");
    emit(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE, token, g_strcmp0(response, "delete") == 0 ? 1 : 0);
    gtk_window_destroy(GTK_WINDOW(dialog));
}

GtkWidget *audio_cleanup_dialog(const char *token, size_t count) {
    gchar *body = g_strdup_printf(
        "Permanently delete %zu saved audio file(s), including audio kept after deleting History entries? "
        "History entries and transcripts will be kept. Recordings saved after this confirmation "
        "will not be deleted. This cannot be undone.", count);
    GtkWidget *dialog = adw_message_dialog_new(ui.window, "Delete saved recordings?", body);
    g_free(body);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    g_object_set_data_full(G_OBJECT(dialog), "jsti-audio-cleanup-token", g_strdup(token), g_free);
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete audio", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    g_signal_connect(dialog, "response", G_CALLBACK(audio_cleanup_response), NULL);
    return dialog;
}

static void export_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    gint32 variant = GPOINTER_TO_INT(data);
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL) emit(JSTI_EVENT_EXPORT_HISTORY, path, variant);
        g_free(path);
        g_object_unref(file);
    }
    g_clear_pointer(&history_page()->export_text, g_free);
}

void on_issue_report(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.state == JSTI_STATE_IDLE && history_page()->selected_id != NULL &&
        g_strcmp0(history_page()->presented_id, history_page()->selected_id) == 0)
        emit(JSTI_EVENT_HISTORY_ISSUE_REPORT, history_page()->selected_id, 0);
}

void on_export(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id == NULL || history_page()->export_text != NULL) return;
    /* Capture the displayed text and version at the click, before the dialog. */
    history_page()->export_text = displayed_transcript();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Export transcript");
    gchar *name = g_strdup_printf("Transcript-%s.txt", history_page()->selected_id);
    gtk_file_dialog_set_initial_name(dialog, name);
    g_free(name);
    gtk_file_dialog_save(dialog, ui.window, NULL, export_chosen,
                         GINT_TO_POINTER(history_page()->presented_switchable ? history_page()->presented_variant : 1));
    g_object_unref(dialog);
}

static void import_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (file == NULL) return;
    gchar *path = g_file_get_path(file);
    if (path != NULL) emit(JSTI_EVENT_IMPORT, path, selected_model_slot());
    g_free(path);
    g_object_unref(file);
}

void on_import(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Import audio");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Audio");
    const char *patterns[] = { "*.wav", "*.mp3", "*.mp4", "*.m4a", "*.aac", "*.flac", "*.ogg", "*.opus", "*.webm" };
    for (size_t index = 0; index < G_N_ELEMENTS(patterns); index++) gtk_file_filter_add_pattern(filter, patterns[index]);
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_open(dialog, ui.window, NULL, import_chosen, NULL);
    g_object_unref(filters);
    g_object_unref(filter);
    g_object_unref(dialog);
}
