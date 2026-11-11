/* History rows, History management, audio cleanup and the migration report. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowHistoryState.h"

static HistoryPage history_state;
HistoryPage *history_page(void) { return &history_state; }

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
    gtk_list_box_remove_all(history_page()->history);
    g_ptr_array_set_size(history_page()->history_ids, 0);
    const char *keep = history->select ? history->selected : history_page()->selected_id;
    GtkListBoxRow *selected = NULL;
    for (guint index = 0; index < history->entries->len; index++) {
        const HistoryEntry *entry = &g_array_index(history->entries, HistoryEntry, index);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), history_card(entry));
        gtk_list_box_append(history_page()->history, row);
        g_ptr_array_add(history_page()->history_ids, g_strdup(entry->id));
        if (g_strcmp0(keep, entry->id) == 0) selected = GTK_LIST_BOX_ROW(row);
    }
    gtk_widget_set_visible(history_page()->history_empty, history->entries->len == 0);
    const char *query = gtk_editable_get_text(GTK_EDITABLE(history_page()->search));
    gtk_label_set_text(GTK_LABEL(history_page()->history_empty), query[0] || jsti_history_filters_active()
        ? "No saved recordings match this search or filter."
        : "No history yet. Press Record to capture your first session.");
    if (history->select) {
        g_free(history_page()->selected_id);
        history_page()->selected_id = g_strdup(history->selected != NULL && history->selected[0] != '\0' ? history->selected : NULL);
    }
    if (selected != NULL) {
        gtk_list_box_select_row(history_page()->history, selected);
        attach_detail(selected);
    } else {
        g_clear_pointer(&history_page()->selected_id, g_free);
        g_clear_pointer(&history_page()->presented_id, g_free);
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
    g_free(history_page()->all_history_ids);
    history_page()->all_history_ids = g_strdup(pointer);
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
    if (!gtk_widget_get_sensitive(GTK_WIDGET(history_page()->audio_cleanup))) {
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
