/* General > Recordings and backup: folder choice, migration backup and restore,
 * audio cleanup, export and import. Owns StoragePage (LinuxWindowStorageState.h). */
#include "LinuxWindowStorageState.h"
#include "LinuxWindowHistoryPage.h"

static StoragePage storage_state;
StoragePage *storage_page(void) { return &storage_state; }

_Static_assert(JSTI_EVENT_RECORDINGS_LOCATION != JSTI_EVENT_MIGRATION_RESTORE,
               "the recordings location choice must not decode as Migration restore");

static void on_recordings_folder(GtkButton *button, gpointer data) {
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

static void on_recordings_choose(GtkButton *button, gpointer data) {
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
    gint32 flags = 0;
    if (choice->action == 0) {
        flags = choice->include_audio | choice->include_profiles | choice->include_settings | choice->include_api_keys;
    } else if (choice->action == 2) {
        flags = choice->include_api_keys;
    }
    emit(events[choice->action], path, flags);
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

static void on_backup(GtkButton *button, gpointer data) {
    (void)button;
    if (ui.closing || ui.state != 0 || storage_page()->backup_chooser != NULL || storage_page()->restore_dialog != NULL) return;
    BackupChoice *choice = g_new0(BackupChoice, 1);
    g_weak_ref_init(&choice->parent, G_OBJECT(ui.window));
    choice->cancelled = g_cancellable_new();
    choice->include_audio = adw_switch_row_get_active(storage_page()->backup_audio) ? 1 : 0;
    choice->include_profiles = adw_switch_row_get_active(storage_page()->backup_profiles) ? 2 : 0;
    choice->include_settings = 4;
    choice->include_api_keys = adw_switch_row_get_active(storage_page()->backup_api_keys) ? 8 : 0;
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

static GtkWidget *migration_restore_dialog_new(
    const char *token, const char *text, gboolean offers_replace, gboolean confirming
) {
    GtkWidget *dialog = adw_message_dialog_new(ui.window,
        confirming ? "Replace with the backup's version?" : "Restore backup: review before anything is written",
        confirming ? "Use the backup's version of everything that conflicts?\n\n"
            "Conflicting settings, vocabulary and API keys take the backup's values, and app profiles absent "
            "from the backup are removed. History is still only merged. Changes are rolled back if anything fails."
            : text);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    adw_message_dialog_set_body_use_markup(ADW_MESSAGE_DIALOG(dialog), FALSE);
    adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel");
    if (!confirming) adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "merge", "Merge backup");
    if (offers_replace) {
        adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "replace",
            confirming ? "Replace" : "Replace...");
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "replace", ADW_RESPONSE_DESTRUCTIVE);
    }
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    g_object_set_data_full(G_OBJECT(dialog), "jsti-restore-token", g_strdup(token), g_free);
    g_object_set_data(G_OBJECT(dialog), "jsti-restore-replace", GINT_TO_POINTER(offers_replace));
    g_object_set_data(G_OBJECT(dialog), "jsti-restore-confirming", GINT_TO_POINTER(confirming));
    g_signal_connect(dialog, "response", G_CALLBACK(migration_restore_response), NULL);
    return g_object_ref_sink(dialog);
}

void retire_migration_restore(void) {
    GtkWidget *dialog = storage_page()->restore_dialog;
    storage_page()->restore_dialog = NULL;
    if (dialog == NULL) return;
    gtk_window_destroy(GTK_WINDOW(dialog));
    g_object_unref(dialog);
}

void refresh_migration_restore(void) {
    if (storage_page()->restore_dialog == NULL) return;
    AdwMessageDialog *dialog = ADW_MESSAGE_DIALOG(storage_page()->restore_dialog);
    gboolean idle = ui.state == JSTI_STATE_IDLE && !ui.closing;
    if (adw_message_dialog_has_response(dialog, "merge"))
        adw_message_dialog_set_response_enabled(dialog, "merge", idle);
    if (adw_message_dialog_has_response(dialog, "replace"))
        adw_message_dialog_set_response_enabled(dialog, "replace", idle);
}

void migration_restore_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    if (storage_page()->restore_dialog != GTK_WIDGET(dialog)) return;
    gchar *token = g_strdup(g_object_get_data(G_OBJECT(dialog), "jsti-restore-token"));
    gboolean offers_replace = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(dialog), "jsti-restore-replace"));
    gboolean confirming = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(dialog), "jsti-restore-confirming"));
    gboolean available = !ui.closing && ui.state == JSTI_STATE_IDLE;
    gboolean replace = available && offers_replace && g_strcmp0(response, "replace") == 0;
    if (replace && !confirming) {
        retire_migration_restore();
        storage_page()->restore_dialog = migration_restore_dialog_new(token, "", TRUE, TRUE);
        refresh_actions();
        gtk_window_present(GTK_WINDOW(storage_page()->restore_dialog));
    } else {
        gint choice = replace && confirming ? 2 : available && !confirming && g_strcmp0(response, "merge") == 0 ? 1 : 0;
        retire_migration_restore();
        refresh_actions();
        emit(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE, token, choice);
    }
    g_free(token);
}

static void migration_restore_confirmation_free(gpointer pointer) {
    MigrationRestoreConfirmation *confirmation = pointer;
    g_free(confirmation->token);
    g_free(confirmation->text);
    g_free(confirmation);
}

gboolean migration_restore_stage(const MigrationRestoreConfirmation *confirmation) {
    if (storage_page()->restore_dialog != NULL &&
        g_strcmp0(g_object_get_data(G_OBJECT(storage_page()->restore_dialog), "jsti-restore-token"), confirmation->token) == 0) {
        return FALSE;
    }
    if (ui.window == NULL || ui.closing || storage_page()->restore_dialog != NULL) {
        emit(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE, confirmation->token, 0);
        return FALSE;
    }
    storage_page()->restore_dialog = migration_restore_dialog_new(
        confirmation->token, confirmation->text, confirmation->offers_replace, FALSE);
    refresh_actions();
    return TRUE;
}

static void migration_restore_confirmation_apply(gpointer pointer) {
    if (migration_restore_stage(pointer)) gtk_window_present(GTK_WINDOW(storage_page()->restore_dialog));
}

int32_t jsti_window_confirm_migration_restore(const char *token, const char *text, int32_t offers_replace) {
    if (token == NULL || !g_uuid_string_is_valid(token) || text == NULL || text[0] == '\0' ||
        !g_utf8_validate(text, -1, NULL) || (offers_replace != 0 && offers_replace != 1)) return -1;
    MigrationRestoreConfirmation *confirmation = g_new0(MigrationRestoreConfirmation, 1);
    confirmation->token = g_strdup(token);
    confirmation->text = g_strdup(text);
    confirmation->offers_replace = offers_replace != 0;
    return post(migration_restore_confirmation_apply, confirmation, migration_restore_confirmation_free);
}

/* General's Housekeeping and Data backup groups. */
void storage_groups_add(GtkWidget *column) {
    GtkWidget *housekeeping = group("Housekeeping");
    GtkWidget *folder = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(folder), "Recording storage");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(folder), "Open the folder containing saved audio and History data.");
    storage_page()->recordings_folder = GTK_BUTTON(gtk_button_new_with_mnemonic("_Open folder"));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->recordings_folder), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->recordings_folder, "clicked", G_CALLBACK(on_recordings_folder), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(folder), GTK_WIDGET(storage_page()->recordings_folder));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), folder);
    GtkWidget *location = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(location), "New recordings folder");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(location),
        "Save new audio in a local folder you choose. Existing recordings are never moved or deleted.");
    storage_page()->recordings_choose = GTK_BUTTON(gtk_button_new_with_mnemonic("_Choose…"));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->recordings_choose), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->recordings_choose, "clicked", G_CALLBACK(on_recordings_choose), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(storage_page()->recordings_choose));
    storage_page()->recordings_default = GTK_BUTTON(gtk_button_new_with_mnemonic("Use _default"));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->recordings_default), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->recordings_default, "clicked", G_CALLBACK(on_recordings_default), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(storage_page()->recordings_default));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), location);
    GtkWidget *cleanup = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cleanup), "Saved recordings");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(cleanup), "Delete saved audio without removing History entries.");
    adw_action_row_add_suffix(ADW_ACTION_ROW(cleanup), history_audio_cleanup_button());
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), cleanup);
    gtk_box_append(GTK_BOX(column), housekeeping);
    GtkWidget *backup = group("Data backup");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(backup),
        "Save History text, settings and vocabulary in a ZIP backup, with optional saved audio, app profiles "
        "and API keys. ZIPs are not encrypted; existing files are never replaced.");
    storage_page()->backup_audio = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(storage_page()->backup_audio), "Include saved recording audio");
    adw_switch_row_set_active(storage_page()->backup_audio, TRUE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(storage_page()->backup_audio));
    storage_page()->backup_profiles = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(storage_page()->backup_profiles), "Include app profiles");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(storage_page()->backup_profiles), "Includes per-app overrides and prompts.");
    adw_switch_row_set_active(storage_page()->backup_profiles, FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(storage_page()->backup_profiles));
    storage_page()->backup_api_keys = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(storage_page()->backup_api_keys), "Include API keys");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(storage_page()->backup_api_keys),
        "Saves API keys unencrypted in the ZIP, and restores them from a backup. Off by default.");
    adw_switch_row_set_active(storage_page()->backup_api_keys, FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(storage_page()->backup_api_keys));
    GtkWidget *backup_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(backup_row), "Save a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(backup_row),
        "Settings, vocabulary and History text are always included.");
    storage_page()->backup_export = GTK_BUTTON(gtk_button_new_with_mnemonic("Save _backup…"));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->backup_export), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->backup_export, "clicked", G_CALLBACK(on_backup), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(backup_row), GTK_WIDGET(storage_page()->backup_export));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), backup_row);
    GtkWidget *inspect_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(inspect_row), "Inspect a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(inspect_row),
        "Review categories and archive notices without importing any data.");
    storage_page()->backup_inspect = GTK_BUTTON(gtk_button_new_with_mnemonic("_Inspect…"));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->backup_inspect), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->backup_inspect, "clicked", G_CALLBACK(on_backup), GINT_TO_POINTER(1));
    adw_action_row_add_suffix(ADW_ACTION_ROW(inspect_row), GTK_WIDGET(storage_page()->backup_inspect));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), inspect_row);
    GtkWidget *restore_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(restore_row), "Restore a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(restore_row),
        "Preview, then merge or replace. API keys are restored only with Include API keys on.");
    storage_page()->backup_restore = GTK_BUTTON(gtk_button_new_with_mnemonic("_Restore..."));
    gtk_widget_set_valign(GTK_WIDGET(storage_page()->backup_restore), GTK_ALIGN_CENTER);
    g_signal_connect(storage_page()->backup_restore, "clicked", G_CALLBACK(on_backup), GINT_TO_POINTER(2));
    adw_action_row_add_suffix(ADW_ACTION_ROW(restore_row), GTK_WIDGET(storage_page()->backup_restore));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), restore_row);
    gtk_box_append(GTK_BOX(column), backup);
}

void storage_refresh_actions(gboolean idle) {
    if (storage_page()->recordings_choose != NULL) {
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->recordings_choose), idle && storage_page()->location_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->recordings_default), idle && storage_page()->location_chooser == NULL);
    }
    if (storage_page()->backup_audio != NULL) {
        gboolean backup_idle = idle && storage_page()->backup_chooser == NULL && storage_page()->restore_dialog == NULL;
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_audio), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_profiles), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_api_keys), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_export), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_inspect), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(storage_page()->backup_restore), backup_idle);
    }
}

void storage_page_close(void) {
    if (storage_page()->backup_chooser != NULL) g_cancellable_cancel(storage_page()->backup_chooser);
    g_clear_object(&storage_page()->backup_chooser);
    if (storage_page()->location_chooser != NULL) g_cancellable_cancel(storage_page()->location_chooser);
    g_clear_object(&storage_page()->location_chooser);
}
