/* History rows, History management, audio cleanup and migration restore confirmations. */
#include "LinuxWindowInternal.h"

static void history_entry_clear(gpointer pointer) {
    HistoryEntry *entry = pointer;
    g_free(entry->id);
    g_free(entry->created);
    g_free(entry->audio_length);
    g_free(entry->cost);
    g_free(entry->preview);
    g_free(entry->models);
    g_free(entry->context);
}

void history_free(gpointer pointer) {
    History *history = pointer;
    g_array_unref(history->entries);
    g_free(history->selected);
    g_free(history);
}

/* One History card: badges, the transcript preview and the models line. */
static GtkWidget *history_card(const HistoryEntry *entry) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_add_css_class(card, "jsti-history-row");
    if (entry->tone == 1) gtk_widget_add_css_class(card, "failed");
    /* A row of badges whose values shorten before the card would widen. */
    GtkWidget *badges = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(badges), jsti_badge_new("created", "x-office-calendar-symbolic", "Created",
                                                             entry->created));
    if (entry->audio_length[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("audio", "audio-input-microphone-symbolic", "Audio",
                                                                 entry->audio_length));
    }
    if (entry->cost[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("cost", "emblem-ok-symbolic", "Cost", entry->cost));
    }
    if (entry->context[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("context", "avatar-default-symbolic", "Context",
                                                                 entry->context));
    }
    if (entry->tone == 1) {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("error", "dialog-warning-symbolic", "Error",
                                                                 "Needs attention"));
    } else if (entry->tone == 2) {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("error", "document-open-recent-symbolic", "Status",
                                                                 "Not transcribed"));
    }
    gtk_box_append(GTK_BOX(card), badges);
    GtkWidget *preview = gtk_label_new(entry->preview);
    gtk_label_set_xalign(GTK_LABEL(preview), 0);
    gtk_label_set_wrap(GTK_LABEL(preview), TRUE);
    gtk_label_set_lines(GTK_LABEL(preview), 2);
    gtk_label_set_ellipsize(GTK_LABEL(preview), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(preview, "jsti-history-preview");
    gtk_box_append(GTK_BOX(card), preview);
    GtkWidget *models = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *icon = gtk_image_new_from_icon_name("emblem-system-symbolic");
    gtk_widget_add_css_class(icon, "jsti-history-models");
    gtk_box_append(GTK_BOX(models), icon);
    GtkWidget *names = gtk_label_new(entry->models);
    gtk_label_set_xalign(GTK_LABEL(names), 0);
    gtk_label_set_ellipsize(GTK_LABEL(names), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(names, "jsti-history-models");
    gtk_box_append(GTK_BOX(models), names);
    gtk_box_append(GTK_BOX(card), models);
    return card;
}

void history_apply(gpointer pointer) {
    History *history = pointer;
    ui.suppress = TRUE;
    detach_detail();
    gtk_list_box_remove_all(ui.history_page.history);
    g_ptr_array_set_size(ui.history_page.history_ids, 0);
    const char *keep = history->select ? history->selected : ui.history_page.selected_id;
    GtkListBoxRow *selected = NULL;
    for (guint index = 0; index < history->entries->len; index++) {
        const HistoryEntry *entry = &g_array_index(history->entries, HistoryEntry, index);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), history_card(entry));
        gtk_list_box_append(ui.history_page.history, row);
        g_ptr_array_add(ui.history_page.history_ids, g_strdup(entry->id));
        if (g_strcmp0(keep, entry->id) == 0) selected = GTK_LIST_BOX_ROW(row);
    }
    gtk_widget_set_visible(ui.history_page.history_empty, history->entries->len == 0);
    const char *query = gtk_editable_get_text(GTK_EDITABLE(ui.history_page.search));
    gtk_label_set_text(GTK_LABEL(ui.history_page.history_empty), query[0] || jsti_history_filters_active()
        ? "No saved recordings match this search or filter."
        : "No history yet. Press Record to capture your first session.");
    if (history->select) {
        g_free(ui.history_page.selected_id);
        ui.history_page.selected_id = g_strdup(history->selected != NULL && history->selected[0] != '\0' ? history->selected : NULL);
    }
    if (selected != NULL) {
        gtk_list_box_select_row(ui.history_page.history, selected);
        attach_detail(selected);
    } else {
        g_clear_pointer(&ui.history_page.selected_id, g_free);
        g_clear_pointer(&ui.history_page.presented_id, g_free);
    }
    ui.suppress = FALSE;
    refresh_actions();
}

History *history_copy(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    History *history = g_new0(History, 1);
    history->entries = g_array_sized_new(FALSE, TRUE, sizeof(HistoryEntry), (guint)count);
    g_array_set_clear_func(history->entries, history_entry_clear);
    for (size_t index = 0; index < count; index++) {
        const JSTIHistoryRow *row = &rows[index];
        HistoryEntry entry = {
            .id = g_strdup(row->id), .created = g_strdup(row->created ? row->created : ""),
            .audio_length = g_strdup(row->audio_length ? row->audio_length : ""),
            .cost = g_strdup(row->cost ? row->cost : ""), .preview = g_strdup(row->preview ? row->preview : ""),
            .models = g_strdup(row->models ? row->models : ""),
            .context = g_strdup(row->context ? row->context : ""), .tone = row->tone,
        };
        g_array_append_val(history->entries, entry);
    }
    history->select = selected_id != NULL;
    history->selected = g_strdup(selected_id);
    return history;
}

int32_t jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    return post(history_apply, history_copy(rows, count, selected_id), history_free);
}

void history_management_apply(gpointer pointer) {
    g_free(ui.history_page.all_history_ids);
    ui.history_page.all_history_ids = g_strdup(pointer);
    refresh_actions();
}

int32_t jsti_window_set_history_management(const char *identifiers) {
    if (identifiers == NULL || !g_utf8_validate(identifiers, -1, NULL)) return -1;
    return post(history_management_apply, g_strdup(identifiers), g_free);
}

typedef struct AudioCleanupConfirmation {
    gchar *token;
    size_t count;
} AudioCleanupConfirmation;

static void audio_cleanup_confirmation_free(gpointer pointer) {
    AudioCleanupConfirmation *confirmation = pointer;
    g_free(confirmation->token);
    g_free(confirmation);
}

static void audio_cleanup_confirmation_apply(gpointer pointer) {
    AudioCleanupConfirmation *confirmation = pointer;
    if (ui.window == NULL) return;
    if (!gtk_widget_get_sensitive(GTK_WIDGET(ui.history_page.audio_cleanup))) {
        emit(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE, confirmation->token, 0);
        return;
    }
    gtk_window_present(GTK_WINDOW(audio_cleanup_dialog(confirmation->token, confirmation->count)));
}

int32_t jsti_window_confirm_audio_cleanup(const char *token, size_t count) {
    if (token == NULL || !g_uuid_string_is_valid(token) || count == 0) return -1;
    AudioCleanupConfirmation *confirmation = g_new0(AudioCleanupConfirmation, 1);
    confirmation->token = g_strdup(token);
    confirmation->count = count;
    return post(audio_cleanup_confirmation_apply, confirmation, audio_cleanup_confirmation_free);
}

GtkWidget *migration_report_dialog(const char *text) {
    GtkWidget *dialog = adw_message_dialog_new(ui.window, "Backup inspection (read only)", text);
    adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "close", "Close");
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "close");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "close");
    g_signal_connect_swapped(dialog, "response", G_CALLBACK(gtk_window_destroy), dialog);
    return dialog;
}

static void migration_report_apply(gpointer pointer) {
    if (ui.window != NULL && !ui.closing) gtk_window_present(GTK_WINDOW(migration_report_dialog(pointer)));
}

int32_t jsti_window_show_migration_report(const char *text) {
    if (text == NULL || text[0] == '\0' || !g_utf8_validate(text, -1, NULL)) return -1;
    return post(migration_report_apply, g_strdup(text), g_free);
}

static GtkWidget *migration_restore_dialog_new(
    const char *token, const char *text, gboolean offers_replace, gboolean confirming
) {
    GtkWidget *dialog = adw_message_dialog_new(ui.window,
        confirming ? "Replace app profiles?" : "Restore backup: review before anything is written",
        confirming ? "Replace your app profiles with the profiles in this backup?\n\n"
            "Profiles absent from the backup will be removed. History is still only merged. "
            "Settings, audio and credentials stay unchanged. Changes are rolled back if anything fails."
            : text);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    adw_message_dialog_set_body_use_markup(ADW_MESSAGE_DIALOG(dialog), FALSE);
    adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel");
    if (!confirming) adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "merge", "Merge backup");
    if (offers_replace) {
        adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "replace",
            confirming ? "Replace profiles" : "Replace profiles...");
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
    GtkWidget *dialog = ui.storage.restore_dialog;
    ui.storage.restore_dialog = NULL;
    if (dialog == NULL) return;
    gtk_window_destroy(GTK_WINDOW(dialog));
    g_object_unref(dialog);
}

void refresh_migration_restore(void) {
    if (ui.storage.restore_dialog == NULL) return;
    AdwMessageDialog *dialog = ADW_MESSAGE_DIALOG(ui.storage.restore_dialog);
    gboolean idle = ui.state == JSTI_STATE_IDLE && !ui.closing;
    if (adw_message_dialog_has_response(dialog, "merge"))
        adw_message_dialog_set_response_enabled(dialog, "merge", idle);
    if (adw_message_dialog_has_response(dialog, "replace"))
        adw_message_dialog_set_response_enabled(dialog, "replace", idle);
}

void migration_restore_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    if (ui.storage.restore_dialog != GTK_WIDGET(dialog)) return;
    gchar *token = g_strdup(g_object_get_data(G_OBJECT(dialog), "jsti-restore-token"));
    gboolean offers_replace = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(dialog), "jsti-restore-replace"));
    gboolean confirming = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(dialog), "jsti-restore-confirming"));
    gboolean available = !ui.closing && ui.state == JSTI_STATE_IDLE;
    gboolean replace = available && offers_replace && g_strcmp0(response, "replace") == 0;
    if (replace && !confirming) {
        retire_migration_restore();
        ui.storage.restore_dialog = migration_restore_dialog_new(token, "", TRUE, TRUE);
        refresh_actions();
        gtk_window_present(GTK_WINDOW(ui.storage.restore_dialog));
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
    if (ui.storage.restore_dialog != NULL &&
        g_strcmp0(g_object_get_data(G_OBJECT(ui.storage.restore_dialog), "jsti-restore-token"), confirmation->token) == 0) {
        return FALSE;
    }
    if (ui.window == NULL || ui.closing || ui.storage.restore_dialog != NULL) {
        emit(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE, confirmation->token, 0);
        return FALSE;
    }
    ui.storage.restore_dialog = migration_restore_dialog_new(
        confirmation->token, confirmation->text, confirmation->offers_replace, FALSE);
    refresh_actions();
    return TRUE;
}

static void migration_restore_confirmation_apply(gpointer pointer) {
    if (migration_restore_stage(pointer)) gtk_window_present(GTK_WINDOW(ui.storage.restore_dialog));
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
