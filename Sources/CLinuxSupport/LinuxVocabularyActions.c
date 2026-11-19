/* The vocabulary editors' buttons: each action's confirmation dialog, the
 * pronunciation JSON import/export file request (Transfer), and the payload
 * sent to the host. */
#include "LinuxVocabularyInternal.h"
#include <adwaita.h>

void vocabulary_send_action(Editor *e, const char *action) {
    if (vocabulary_hidden_selection(e) && (g_strcmp0(action, "save") == 0 || g_strcmp0(action, "delete") == 0
        || g_strcmp0(action, "up") == 0 || g_strcmp0(action, "down") == 0)) {
        gtk_label_set_text(GTK_LABEL(e->status),
            "The selected entry is hidden by filters. Clear filters or select a visible entry.");
        return;
    }
    gchar *payload = vocabulary_action_payload(e, action);
    vocabulary_pending(e, TRUE); gtk_label_set_text(GTK_LABEL(e->status), "Saving or previewing...");
    jsti_window_emit(70, payload, e->kind); g_free(payload);
}
static void delete_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    Editor *e = g_object_get_data(G_OBJECT(data), "vocabulary-editor");
    if (e != NULL && g_strcmp0(response, "delete") == 0) vocabulary_send_action(e, "delete");
}
typedef struct { int action; GWeakRef root; } Transfer;
static void transfer_finished(GObject *object, GAsyncResult *result, gpointer data) {
    Transfer *transfer = data;
    const int action = transfer->action;
    g_autoptr(GObject) root = g_weak_ref_get(&transfer->root);
    Editor *e = root != NULL ? g_object_get_data(root, "vocabulary-editor") : NULL;
    g_weak_ref_clear(&transfer->root); g_free(transfer);
    GError *error = NULL;
    GFile *file = action == 2 ? gtk_file_dialog_save_finish(GTK_FILE_DIALOG(object), result, &error)
        : gtk_file_dialog_open_finish(GTK_FILE_DIALOG(object), result, &error);
    if (file == NULL) {
        if (e != NULL && error != NULL && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)
            && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED))
            gtk_label_set_text(GTK_LABEL(e->status), error->message);
        g_clear_error(&error); return;
    }
    gchar *path = g_file_get_path(file); g_object_unref(file);
    if (e == NULL) { g_free(path); return; }
    if (path == NULL) {
        gtk_label_set_text(GTK_LABEL(e->status), "Choose a local JSON file, not a remote URI."); return;
    }
    const char *actions[] = {"importMerge", "importReplace", "export"};
    GString *payload = g_string_new(actions[action]); vocabulary_append_field(payload, path); g_free(path);
    vocabulary_pending(e, TRUE); jsti_window_emit(70, payload->str, e->kind); g_string_free(payload, TRUE);
}
static void transfer(Editor *e, int action) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, action == 2 ? "Export pronunciation dictionary" : "Import pronunciation dictionary");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "JSON dictionaries"); gtk_file_filter_add_pattern(filter, "*.json");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter); gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    g_object_unref(filters); g_object_unref(filter);
    GtkRoot *root = gtk_widget_get_root(e->root);
    GtkWindow *parent = GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL;
    Transfer *request = g_new0(Transfer, 1);
    request->action = action;
    g_weak_ref_init(&request->root, G_OBJECT(e->root));
    if (action == 2) {
        gtk_file_dialog_set_initial_name(dialog, "pronunciation_dictionary.json");
        gtk_file_dialog_save(dialog, parent, NULL, transfer_finished, request);
    } else gtk_file_dialog_open(dialog, parent, NULL, transfer_finished, request);
    g_object_unref(dialog);
}
static void replace_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    Editor *e = g_object_get_data(G_OBJECT(data), "vocabulary-editor");
    if (e != NULL && g_strcmp0(response, "replace") == 0) transfer(e, 1);
}
static void candidate_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    Editor *e = g_object_get_data(G_OBJECT(data), "vocabulary-editor");
    if (e != NULL && g_strcmp0(response, "apply") == 0) {
        const char *payload = g_object_get_data(G_OBJECT(dialog), "candidate-payload");
        vocabulary_pending(e, TRUE); jsti_window_emit(70, payload, 3);
    }
}
static void observation_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    Editor *e = g_object_get_data(G_OBJECT(data), "vocabulary-editor");
    if (e != NULL && g_strcmp0(response, "allow") == 0) {
        const guint64 token = jsti_atspi_offer_local_consent();
        if (token == 0) {
            gtk_label_set_text(GTK_LABEL(e->status), "Local consent is unavailable. Restart the app to try again.");
            return;
        }
        e->consent_token = token;
        gchar *payload = g_strdup_printf("allowObservationalLearning\t%" G_GUINT64_FORMAT, token);
        vocabulary_pending(e, TRUE);
        jsti_window_emit(70, payload, e->kind); g_free(payload);
    }
}
static void clicked(GtkButton *button, gpointer data) {
    Editor *e = data;
    const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
    if (g_strcmp0(action, "stopLearning") == 0) {
        /* Revoke the native capability before a queued Swift action runs. */
        const guint64 token = jsti_atspi_revoke_local_consent();
        e->consent_token = token;
        gchar *payload = g_strdup_printf("stopObservationalLearning\t%" G_GUINT64_FORMAT, token);
        vocabulary_pending(e, TRUE); jsti_window_emit(70, payload, e->kind); g_free(payload); return;
    }
    if (g_strcmp0(action, "allowObservationalLearning") == 0) {
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
            "Allow observational learning for this session?",
            "After you focus a supported ordinary editable field, JustSpeakToIt may insert directly through AT-SPI "
            "and read a bounded span and surrounding guards. This is observation, not proof that our insertion "
            "caused the change: app-origin formatting and changes can also be learned. Password and ambiguous "
            "fields are excluded; clipboard and paste are never observed. Accessibility must already be enabled. "
            "This permission is not saved or imported. Stop learning revokes it immediately.");
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog),
            "cancel", "Keep off", "allow", "Allow for this session", NULL);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_signal_connect_object(dialog, "response", G_CALLBACK(observation_response), e->root, 0);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    if (g_strcmp0(action, "candidates") == 0 || g_strcmp0(action, "legacyDictionary") == 0) {
        const int kind = g_strcmp0(action, "legacyDictionary") == 0 ? 4 : 3;
        if (vocabulary_editor(kind) != NULL) {
            GtkRoot *existing = gtk_widget_get_root(vocabulary_editor(kind)->root);
            if (GTK_IS_WINDOW(existing)) gtk_window_present(GTK_WINDOW(existing));
            return;
        }
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *window = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(window), kind == 4 ? "Legacy word dictionary" : "Stored correction candidates");
        gtk_window_set_default_size(GTK_WINDOW(window), 800, 640);
        if (GTK_IS_WINDOW(root)) gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(root));
        gtk_window_set_destroy_with_parent(GTK_WINDOW(window), TRUE);
        gtk_window_set_modal(GTK_WINDOW(window), TRUE);
        gtk_window_set_child(GTK_WINDOW(window), jsti_vocabulary_page_new(kind));
        gtk_window_present(GTK_WINDOW(window)); jsti_window_emit(71, "", kind); return;
    }
    if (e->kind == 3 && g_strcmp0(action, "refresh") != 0) {
        if (g_strcmp0(action, "clear") != 0 && e->selected < 0) {
            gtk_label_set_text(GTK_LABEL(e->status), "Select a stored candidate first."); return;
        }
        if (g_strcmp0(action, "promote") == 0) { vocabulary_send_action(e, action); return; }
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
            "Change stored candidates?", g_strcmp0(action, "clear") == 0
                ? "Clear all stored candidates? Saved correction rules stay unchanged."
                : g_strcmp0(action, "dismiss") == 0 ? "Dismiss this stored candidate?" : "Remove this stored candidate?");
        g_object_set_data_full(G_OBJECT(dialog), "candidate-payload", vocabulary_action_payload(e, action), g_free);
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "apply", "Confirm", NULL);
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "apply", ADW_RESPONSE_DESTRUCTIVE);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_signal_connect_object(dialog, "response", G_CALLBACK(candidate_response), e->root, 0);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    if (g_strcmp0(action, "new") == 0) {
        e->selected = -1; gtk_list_box_unselect_all(e->list); vocabulary_fill(e, NULL); vocabulary_selection_controls(e); return;
    }
    if (g_strcmp0(action, "refresh") == 0) {
        vocabulary_pending(e, TRUE); jsti_window_emit(71, "", e->kind); return;
    }
    if (g_strcmp0(action, "importMerge") == 0) { transfer(e, 0); return; }
    if (g_strcmp0(action, "export") == 0) { transfer(e, 2); return; }
    if (g_strcmp0(action, "importReplace") == 0) {
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
            "Replace pronunciation dictionary?", "The imported file will replace all saved entries.");
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "replace", "Choose file", NULL);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_signal_connect_object(dialog, "response", G_CALLBACK(replace_response), e->root, 0);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    if ((g_strcmp0(action, "delete") == 0 || g_strcmp0(action, "up") == 0 || g_strcmp0(action, "down") == 0)
        && e->selected < 0) return;
    if (g_strcmp0(action, "delete") == 0) {
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
            "Delete entry?", "This removes the saved entry from this device.");
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete", NULL);
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_signal_connect_object(dialog, "response", G_CALLBACK(delete_response), e->root, 0);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    vocabulary_send_action(e, action);
}
GtkWidget *vocabulary_button(Editor *e, const char *title, const char *action) {
    GtkWidget *widget = gtk_button_new_with_mnemonic(title);
    g_object_set_data(G_OBJECT(widget), "vocabulary-action", (gpointer)action);
    g_signal_connect(widget, "clicked", G_CALLBACK(clicked), e);
    g_ptr_array_add(e->buttons, widget); return widget;
}
