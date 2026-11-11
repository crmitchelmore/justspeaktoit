#include "LinuxVocabularyInternal.h"
#include <adwaita.h>
#include <string.h>

GtkWidget *jsti_vocabulary_page_new(int kind);

Editor *vocabulary_editors[5];
GtkWidget *jsti_vocabulary_learning_preferences(void) {
    return vocabulary_editors[0] != NULL ? vocabulary_editors[0]->learning_preferences : NULL;
}
static const char *activations[] = { "automatic", "requireContextMatch", "manual", NULL };
static const char *confidences[] = { "high", "medium", "low", NULL };
static gboolean filter(GtkListBoxRow *row, gpointer data);
gboolean vocabulary_hidden_selection(Editor *e) {
    if ((e->kind != 1 && e->kind != 4) || e->selected < 0) return FALSE;
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(e->list, e->selected);
    return row == NULL || !filter(row, e);
}
static void selection_controls(Editor *e) {
    if (e->kind != 1 && e->kind != 4) return;
    const gboolean hidden = vocabulary_hidden_selection(e);
    for (guint i = 0; i < e->buttons->len; ++i) {
        GtkWidget *button = g_ptr_array_index(e->buttons, i);
        const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
        if (g_strcmp0(action, "save") == 0 || g_strcmp0(action, "delete") == 0
            || g_strcmp0(action, "up") == 0 || g_strcmp0(action, "down") == 0)
            gtk_widget_set_sensitive(button, !e->busy && !hidden);
    }
}
static void apply_filters(Editor *e) {
    const gint selected = e->selected;
    e->filling = TRUE;
    gtk_list_box_invalidate_filter(e->list);
    GtkListBoxRow *row = selected >= 0 ? gtk_list_box_get_row_at_index(e->list, selected) : NULL;
    if (row != NULL && filter(row, e)) gtk_list_box_select_row(e->list, row);
    else gtk_list_box_unselect_all(e->list);
    e->selected = selected; e->filling = FALSE;
    selection_controls(e);
}

static gchar *escape(const char *text) {
    GString *result = g_string_new(NULL);
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        switch (*p) {
        case '%': g_string_append(result, "%25"); break;
        case '\t': g_string_append(result, "%09"); break;
        case '\r': g_string_append(result, "%0D"); break;
        case '\n': g_string_append(result, "%0A"); break;
        default: g_string_append_c(result, (char)*p); break;
        }
    }
    return g_string_free(result, FALSE);
}
gchar *vocabulary_text(GtkWidget *widget) {
    if (GTK_IS_TEXT_VIEW(widget)) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
        GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
        return gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    }
    return g_strdup(gtk_editable_get_text(GTK_EDITABLE(widget)));
}
void vocabulary_set_text(GtkWidget *widget, const char *value) {
    if (GTK_IS_TEXT_VIEW(widget)) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget)), value, -1);
    else gtk_editable_set_text(GTK_EDITABLE(widget), value);
}
static gboolean combo(Editor *e, int i) { return e->kind == 0 && (i == 4 || i == 6); }
static gboolean check(Editor *e, int i) { return e->kind == 1 && (i == 5 || i == 6); }
void vocabulary_fill(Editor *e, gchar **row) {
    if (e->kind == 3) {
        gchar *details = row == NULL ? g_strdup(
            "Select a stored candidate. Learning requires separate local session consent.")
            : g_strdup_printf("%s -> %s\nSeen: %s\nSource apps: %s\nFirst seen: %s\nLast seen: %s\nState: %s",
                row[1], row[2], row[3], row[4], row[5], row[6], row[7]);
        gtk_label_set_text(GTK_LABEL(e->fields[1]), details); g_free(details); return;
    }
    for (int i = 1; i < (e->kind == 4 ? 3 : 8); ++i) {
        if (e->kind == 1 && i == 7) continue;
        const char *value = row != NULL ? row[i] : "";
        if (combo(e, i)) {
            const char **choices = i == 4 ? activations : confidences;
            guint selected = 0;
            for (guint j = 0; j < 3; ++j) if (g_strcmp0(value, choices[j]) == 0) selected = j;
            gtk_drop_down_set_selected(GTK_DROP_DOWN(e->fields[i]), selected);
        } else if (check(e, i)) {
            gtk_check_button_set_active(GTK_CHECK_BUTTON(e->fields[i]), g_strcmp0(value, "true") == 0);
        } else vocabulary_set_text(e->fields[i], value);
    }
}
static gboolean action_available(const char *action, gboolean busy) {
    return !busy || g_strcmp0(action, "stopLearning") == 0;
}
int32_t jsti_vocabulary_learning_controls_contract_self_test(void) {
    /* The same predicate drives the actual GTK buttons while a Host queue
     * is held; this fixture creates no widgets and performs no UI actions. */
    return action_available("stopLearning", TRUE) && action_available("stopLearning", FALSE)
        && !action_available("allowObservationalLearning", TRUE) && !action_available("save", TRUE)
        && action_available("allowObservationalLearning", FALSE) ? 0 : -1;
}
void vocabulary_pending(Editor *e, gboolean busy) {
    e->busy = busy;
    for (guint i = 0; i < e->buttons->len; ++i) {
        GtkWidget *button = g_ptr_array_index(e->buttons, i);
        const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
        gtk_widget_set_sensitive(button, action_available(action, busy));
    }
    gtk_widget_set_sensitive(GTK_WIDGET(e->list), !busy);
    if (e->kind == 4) {
        gtk_widget_set_sensitive(e->fields[1], !busy);
        gtk_widget_set_sensitive(e->fields[2], !busy);
        gtk_widget_set_sensitive(e->search, !busy);
    }
    selection_controls(e);
}
static void append_field(GString *payload, const char *value) {
    gchar *escaped = escape(value);
    g_string_append_c(payload, '\t'); g_string_append(payload, escaped); g_free(escaped);
}
static void selected(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list;
    Editor *e = data;
    if (e->filling) return;
    e->selected = row != NULL ? gtk_list_box_row_get_index(row) : -1;
    if (e->selected >= 0) vocabulary_fill(e, g_ptr_array_index(e->rows, (guint)e->selected));
    selection_controls(e);
}
gchar *vocabulary_action_payload(Editor *e, const char *action) {
    GString *payload = g_string_new(action);
    if (e->kind == 4) {
        gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
        append_field(payload, row != NULL ? row[0] : "");
        for (int i = 1; i <= 2; ++i) {
            gchar *value = vocabulary_text(e->fields[i]); append_field(payload, value); g_free(value);
        }
    } else if (e->kind == 3) {
        if (g_strcmp0(action, "clear") != 0) {
            gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
            append_field(payload, row != NULL ? row[0] : "");
        }
    } else if (g_strcmp0(action, "preview") == 0) {
        gchar *sample = vocabulary_text(e->preview), *tags = vocabulary_text(e->preview_tags);
        append_field(payload, sample); append_field(payload, tags); g_free(sample); g_free(tags);
    } else if (g_strcmp0(action, "preferences") == 0) {
        append_field(payload, gtk_check_button_get_active(e->include_rules) ? "true" : "false");
        append_field(payload, gtk_check_button_get_active(e->include_tags) ? "true" : "false");
        append_field(payload, gtk_editable_get_text(GTK_EDITABLE(e->tags)));
    } else if (g_strcmp0(action, "defaults") != 0) {
        gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
        append_field(payload, row != NULL ? row[0] : "");
        for (int i = 1; i < 8; ++i) {
            if (e->kind == 1 && i == 7) { append_field(payload, ""); continue; }
            if (combo(e, i)) {
                guint choice = gtk_drop_down_get_selected(GTK_DROP_DOWN(e->fields[i]));
                append_field(payload, choice < 3 ? (i == 4 ? activations : confidences)[choice] : "");
            } else if (check(e, i)) {
                append_field(payload, gtk_check_button_get_active(GTK_CHECK_BUTTON(e->fields[i])) ? "true" : "false");
            } else {
                gchar *value = vocabulary_text(e->fields[i]); append_field(payload, value); g_free(value);
            }
        }
    }
    return g_string_free(payload, FALSE);
}
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
    GString *payload = g_string_new(actions[action]); append_field(payload, path); g_free(path);
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
        if (vocabulary_editors[kind] != NULL) {
            GtkRoot *existing = gtk_widget_get_root(vocabulary_editors[kind]->root);
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
        e->selected = -1; gtk_list_box_unselect_all(e->list); vocabulary_fill(e, NULL); selection_controls(e); return;
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
static GtkWidget *button(Editor *e, const char *title, const char *action) {
    GtkWidget *widget = gtk_button_new_with_mnemonic(title);
    g_object_set_data(G_OBJECT(widget), "vocabulary-action", (gpointer)action);
    g_signal_connect(widget, "clicked", G_CALLBACK(clicked), e);
    g_ptr_array_add(e->buttons, widget); return widget;
}
static gboolean filter(GtkListBoxRow *row, gpointer data) {
    Editor *e = data;
    const char *query = gtk_editable_get_text(GTK_EDITABLE(e->search));
    if (e->kind == 1) {
        const gint index = gtk_list_box_row_get_index(row);
        if (index < 0 || (guint)index >= e->rows->len) return FALSE;
        gchar **fields = g_ptr_array_index(e->rows, (guint)index);
        if (e->category[0] != '\0' && g_strcmp0(fields[4], e->category) != 0) return FALSE;
        gchar *needle = g_utf8_casefold(query, -1);
        gboolean match = FALSE;
        for (guint i = 1; i <= 3; ++i) {
            gchar *haystack = g_utf8_casefold(fields[i], -1);
            match = match || strstr(haystack, needle) != NULL;
            g_free(haystack);
        }
        g_free(needle); return match;
    }
    GtkWidget *label = gtk_list_box_row_get_child(row);
    gchar *haystack = g_utf8_casefold(gtk_label_get_text(GTK_LABEL(label)), -1), *needle = g_utf8_casefold(query, -1);
    gboolean match = strstr(haystack, needle) != NULL;
    g_free(haystack); g_free(needle); return match;
}
static void search_changed(GtkSearchEntry *search, gpointer data) {
    (void)search; Editor *e = data;
    if (e->kind == 1 || e->kind == 4) apply_filters(e);
    else gtk_list_box_invalidate_filter(e->list);
}
static void category_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; Editor *e = data;
    if (e->filling) return;
    const guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(e->category_filter));
    if (selected >= e->categories->len) return;
    Category *category = g_ptr_array_index(e->categories, selected);
    g_free(e->category); e->category = g_strdup(category->value);
    apply_filters(e);
}
static void category_free(gpointer data) {
    Category *category = data; g_free(category->value); g_free(category);
}
static GPtrArray *category_options(gchar **header, GPtrArray *rows) {
    const guint length = g_strv_length(header);
    GPtrArray *options = g_ptr_array_new_with_free_func(category_free);
    Category *all = g_new0(Category, 1); all->value = g_strdup(""); all->count = rows->len;
    g_ptr_array_add(options, all);
    if (length == 4) return options;
    gchar *total = g_strdup_printf("%u", rows->len);
    const gboolean modern = length >= 6 && g_strcmp0(header[4], "pronunciationCategories.v1") == 0
        && (length - 6) % 2 == 0 && g_strcmp0(header[5], total) == 0;
    g_free(total);
    if (!modern) { g_ptr_array_unref(options); return NULL; }
    for (guint i = 6; i < length; i += 2) {
        gchar *name = g_uri_unescape_string(header[i], NULL);
        if (name == NULL || name[0] == '\0') { g_free(name); g_ptr_array_unref(options); return NULL; }
        guint count = 0;
        for (guint j = 0; j < rows->len; ++j)
            if (g_strcmp0(((gchar **)g_ptr_array_index(rows, j))[4], name) == 0) ++count;
        gchar *expected = g_strdup_printf("%u", count);
        gboolean valid = count > 0 && g_strcmp0(header[i + 1], expected) == 0;
        g_free(expected);
        for (guint j = 0; j < options->len; ++j)
            if (g_strcmp0(((Category *)g_ptr_array_index(options, j))->value, name) == 0) valid = FALSE;
        if (!valid) { g_free(name); g_ptr_array_unref(options); return NULL; }
        Category *category = g_new0(Category, 1); category->value = name; category->count = count;
        g_ptr_array_add(options, category);
    }
    return options;
}
static void update_categories(Editor *e, GPtrArray *options) {
    g_ptr_array_unref(e->categories); e->categories = options;
    GtkStringList *model = gtk_string_list_new(NULL);
    guint selected = 0;
    for (guint i = 0; i < options->len; ++i) {
        Category *category = g_ptr_array_index(options, i);
        gchar *label = g_strdup_printf("%s (%u)", i == 0 ? "All" : category->value, category->count);
        gtk_string_list_append(model, label); g_free(label);
        if (g_strcmp0(e->category, category->value) == 0) selected = i;
    }
    gtk_drop_down_set_model(GTK_DROP_DOWN(e->category_filter), G_LIST_MODEL(model)); g_object_unref(model);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(e->category_filter), selected);
    g_free(e->category);
    e->category = g_strdup(((Category *)g_ptr_array_index(options, selected))->value);
}
static GtkWidget *multiline(GtkWidget **view) {
    *view = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(*view), GTK_WRAP_WORD_CHAR);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 80);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), *view);
    return scroll;
}
static void destroy_editor(gpointer data) {
    Editor *e = data;
    if (e->kind == 0 && e->consent_token != 0)
        jsti_atspi_observational_consent(0, e->consent_token);
    if (vocabulary_editors[e->kind] == e) vocabulary_editors[e->kind] = NULL;
    g_ptr_array_unref(e->rows); g_ptr_array_unref(e->categories); g_ptr_array_unref(e->buttons);
    g_free(e->category); g_free(e);
}
GtkWidget *jsti_vocabulary_page_new(int kind) {
    Editor *e = g_new0(Editor, 1); e->kind = kind; e->selected = -1;
    e->rows = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    e->categories = g_ptr_array_new_with_free_func(category_free); e->category = g_strdup("");
    e->buttons = g_ptr_array_new();
    GtkWidget *column, *page = jsti_page_new(&column); e->root = page; vocabulary_editors[kind] = e;
    g_object_set_data_full(G_OBJECT(page), "vocabulary-editor", e, destroy_editor);
    GtkWidget *hero = jsti_hero_new("settings", kind == 0 ? "Corrections" : kind == 4 ? "Legacy word dictionary"
        : kind == 3 ? "Stored correction candidates" : "Pronunciation Dictionary",
        kind == 0 ? "Preferred spellings before post-processing. The original provider transcript stays in History."
        : kind == 4 ? "Mac word-to-pronunciation settings. Words can seed AssemblyAI; modern Read aloud entries stay separate."
        : kind == 3 ? "Review stored candidates. Optional session-consented AT-SPI observation is not acknowledged insertion."
        : "Your Read aloud dictionary. Deepgram uses text replacements, not IPA phoneme tags.", NULL, NULL);
    gtk_box_append(GTK_BOX(column), hero);
    if (kind == 0) {
        e->learning_preferences = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_box_append(GTK_BOX(column), e->learning_preferences);
    }
    e->search = gtk_search_entry_new();
    gtk_widget_set_tooltip_text(e->search, "Search saved entries");
    g_signal_connect(e->search, "search-changed", G_CALLBACK(search_changed), e);
    gtk_box_append(GTK_BOX(column), e->search);
    if (kind == 1) {
        GtkWidget *label = gtk_label_new_with_mnemonic("Category _filter");
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_box_append(GTK_BOX(column), label);
        const char *initial[] = {"All (0)", NULL};
        e->category_filter = gtk_drop_down_new_from_strings(initial);
        gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->category_filter);
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->category_filter), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Category filter", -1);
        g_signal_connect(e->category_filter, "notify::selected", G_CALLBACK(category_changed), e);
        gtk_box_append(GTK_BOX(column), e->category_filter);
    }
    e->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(e->list), "boxed-list");
    gtk_list_box_set_filter_func(e->list, filter, e, NULL);
    g_signal_connect(e->list, "row-selected", G_CALLBACK(selected), e);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 160);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 260);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(e->list));
    gtk_box_append(GTK_BOX(column), scroll);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    if (kind == 3) {
        const char *titles[] = {"_Approve", "_Dismiss", "_Remove", "_Clear all", "Re_load"};
        const char *commands[] = {"promote", "dismiss", "remove", "clear", "refresh"};
        for (int i = 0; i < 5; ++i) gtk_box_append(GTK_BOX(actions), button(e, titles[i], commands[i]));
        gtk_box_append(GTK_BOX(column), actions);
        e->fields[1] = gtk_label_new("");
        gtk_label_set_xalign(GTK_LABEL(e->fields[1]), 0);
        gtk_label_set_wrap(GTK_LABEL(e->fields[1]), TRUE);
        gtk_label_set_selectable(GTK_LABEL(e->fields[1]), TRUE);
        gtk_box_append(GTK_BOX(column), e->fields[1]);
        e->status = gtk_label_new("Reload to inspect stored candidates.");
        gtk_label_set_wrap(GTK_LABEL(e->status), TRUE);
        gtk_label_set_xalign(GTK_LABEL(e->status), 0);
        gtk_box_append(GTK_BOX(column), e->status);
        vocabulary_fill(e, NULL); vocabulary_pending(e, TRUE); return page;
    }
    const char *names[] = {"_New", "_Delete", "Move _up", "Move _down", "_Reload"};
    const char *values[] = {"new", "delete", "up", "down", "refresh"};
    for (int i = 0; i < 5; ++i)
        if (kind != 4 || (i != 2 && i != 3)) gtk_box_append(GTK_BOX(actions), button(e, names[i], values[i]));
    gtk_box_append(GTK_BOX(column), actions);
    const char *rules[] = {"Display name", "Canonical spelling", "Spoken variants (one per line)", "Activation",
        "Context tags (comma-separated)", "Confidence", "Notes"};
    const char *speech[] = {"Word or pattern", "Pronunciation", "Text replacement", "Category",
        "Regular expression", "Case sensitive", "Notes (not stored)"};
    for (int i = 1; i < (kind == 4 ? 3 : 8); ++i) {
        if (kind == 1 && i == 7) continue;
        const char *title = kind == 4 ? (i == 1 ? "Word" : "Pronunciation") : (kind == 0 ? rules : speech)[i - 1];
        GtkWidget *label = gtk_label_new(title);
        gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_box_append(GTK_BOX(column), label);
        GtkWidget *widget;
        if (combo(e, i)) {
            const char *a[] = {"Automatic", "Require context match", "Manual confirmation", NULL};
            const char *c[] = {"High", "Medium", "Low", NULL};
            widget = gtk_drop_down_new_from_strings(i == 4 ? a : c); e->fields[i] = widget;
        } else if (check(e, i)) {
            widget = gtk_check_button_new_with_label(speech[i - 1]); e->fields[i] = widget;
        } else if ((kind == 0 && i == 3) || kind == 4) widget = multiline(&e->fields[i]);
        else { widget = gtk_entry_new(); e->fields[i] = widget; }
        gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->fields[i]);
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->fields[i]), GTK_ACCESSIBLE_PROPERTY_LABEL,
            title, -1);
        gtk_box_append(GTK_BOX(column), widget);
    }
    gtk_box_append(GTK_BOX(column), button(e, "_Save entry", "save"));
    if (kind == 4) {
        e->status = gtk_label_new("Loading legacy word dictionary...");
        gtk_label_set_wrap(GTK_LABEL(e->status), TRUE); gtk_label_set_selectable(GTK_LABEL(e->status), TRUE);
        gtk_label_set_xalign(GTK_LABEL(e->status), 0); gtk_box_append(GTK_BOX(column), e->status);
        vocabulary_fill(e, NULL); vocabulary_pending(e, TRUE); return page;
    }
    if (kind == 1) {
        gtk_box_append(GTK_BOX(column), button(e, "Add default _entries", "defaults"));
        GtkWidget *transfers = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_box_append(GTK_BOX(transfers), button(e, "_Import JSON (merge)", "importMerge"));
        gtk_box_append(GTK_BOX(transfers), button(e, "Import JSON (replace)", "importReplace"));
        gtk_box_append(GTK_BOX(transfers), button(e, "_Export JSON", "export"));
        gtk_box_append(GTK_BOX(column), transfers);
        gtk_box_append(GTK_BOX(column), button(e, "Legacy _word dictionary", "legacyDictionary"));
    }
    GtkWidget *label = gtk_label_new("Preview text (saved entries are used)");
    gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_box_append(GTK_BOX(column), label);
    gtk_box_append(GTK_BOX(column), multiline(&e->preview));
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->preview), GTK_ACCESSIBLE_PROPERTY_LABEL, "Preview text", -1);
    e->preview_tags = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(e->preview_tags), "Preview context tags, comma-separated");
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->preview_tags), GTK_ACCESSIBLE_PROPERTY_LABEL,
        "Preview context tags, comma-separated", -1);
    gtk_box_append(GTK_BOX(column), e->preview_tags);
    gtk_box_append(GTK_BOX(column), button(e, "_Preview", "preview"));
    if (kind == 0) {
        e->include_rules = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Include rules in post-processing"));
        e->include_tags = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Include context tags in post-processing"));
        e->tags = GTK_ENTRY(gtk_entry_new());
        gtk_entry_set_placeholder_text(e->tags, "Recording context tags, comma-separated");
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->tags), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Recording context tags, comma-separated", -1);
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->include_rules));
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->include_tags));
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->tags));
        gtk_box_append(GTK_BOX(column), button(e, "Save _context settings", "preferences"));
        gtk_box_append(GTK_BOX(column), button(e, "Review stored _candidates", "candidates"));
        label = gtk_label_new("Observational learning is off until you explicitly allow it for this session. "
            "App-origin changes can also be learned. Only supported AT-SPI fields qualify; paste never does. "
            "Enable and apply Correction learning above first. Accessibility availability depends on the desktop and toolkit, "
            "including on Wayland; no OS accessibility setting is changed.");
        gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_box_append(GTK_BOX(column), label);
        gtk_box_append(GTK_BOX(column), button(e, "_Allow observational learning...", "allowObservationalLearning"));
        gtk_box_append(GTK_BOX(column), button(e, "_Stop learning", "stopLearning"));
    }
    e->status = gtk_label_new("Select Reload to load saved entries.");
    gtk_label_set_wrap(GTK_LABEL(e->status), TRUE); gtk_label_set_selectable(GTK_LABEL(e->status), TRUE);
    gtk_label_set_xalign(GTK_LABEL(e->status), 0); gtk_box_append(GTK_BOX(column), e->status);
    vocabulary_fill(e, NULL); return page;
}
static void presentation_free(gpointer data) {
    Presentation *p = data; g_free(p->payload); g_free(p);
}
void vocabulary_present(gpointer data) {
    Presentation *p = data;
    if (p->kind == 2) {
        Editor *source = vocabulary_editors[0];
        if (source == NULL) return;
        GtkRoot *root = gtk_widget_get_root(source->root);
        if (!GTK_IS_WINDOW(root)) return;
        GtkWidget *dialog = adw_message_dialog_new(GTK_WINDOW(root), "Recording corrections",
            "Retained applied corrections and suggestions; the provider transcript is unchanged.");
        GtkWidget *view, *scroll = multiline(&view);
        gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 360);
        vocabulary_set_text(view, p->payload);
        gtk_accessible_update_property(GTK_ACCESSIBLE(view), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Retained recording correction results", -1);
        adw_message_dialog_set_extra_child(ADW_MESSAGE_DIALOG(dialog), scroll);
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "close", "Close", NULL);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "close");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "close");
        gtk_window_present(GTK_WINDOW(dialog));
        return;
    }
    Editor *e = vocabulary_editors[p->kind];
    if (e == NULL) return;
    if (!p->refresh) { gtk_label_set_text(GTK_LABEL(e->status), p->payload); vocabulary_pending(e, FALSE); return; }
    gchar **lines = g_strsplit(p->payload, "\n", -1);
    gchar **header = g_strsplit(lines[0], "\t", -1);
    gchar *notice = g_uri_unescape_string(header[0], NULL);
    gtk_label_set_text(GTK_LABEL(e->status), notice != NULL ? notice : "Invalid editor response");
    g_free(notice);
    if (e->kind == 0 && g_strv_length(header) == 4) {
        gtk_check_button_set_active(e->include_rules, g_strcmp0(header[1], "true") == 0);
        gtk_check_button_set_active(e->include_tags, g_strcmp0(header[2], "true") == 0);
        gchar *tags = g_uri_unescape_string(header[3], NULL);
        gtk_editable_set_text(GTK_EDITABLE(e->tags), tags != NULL ? tags : ""); g_free(tags);
    }
    GPtrArray *rows = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    for (guint i = 1; lines[i] != NULL; ++i) {
        gchar **row = g_strsplit(lines[i], "\t", -1);
        if (g_strv_length(row) != 8) { g_strfreev(row); continue; }
        gboolean valid = TRUE;
        for (int j = 0; j < 8; ++j) {
            gchar *value = g_uri_unescape_string(row[j], NULL);
            if (value == NULL) { valid = FALSE; break; }
            g_free(row[j]); row[j] = value;
        }
        if (valid) g_ptr_array_add(rows, row);
        else g_strfreev(row);
    }
    GPtrArray *categories = e->kind == 1 ? category_options(header, rows) : NULL;
    g_strfreev(header); g_strfreev(lines);
    if (e->kind == 1 && categories == NULL) {
        g_ptr_array_unref(rows); vocabulary_pending(e, TRUE);
        for (guint i = 0; i < e->buttons->len; ++i) {
            GtkWidget *button = g_ptr_array_index(e->buttons, i);
            if (g_strcmp0(g_object_get_data(G_OBJECT(button), "vocabulary-action"), "refresh") == 0)
                gtk_widget_set_sensitive(button, TRUE);
        }
        gtk_label_set_text(GTK_LABEL(e->status),
            "Invalid pronunciation category metadata. Reload the editor before making changes.");
        return;
    }
    gchar *selected_id = e->selected >= 0
        ? g_strdup(((gchar **)g_ptr_array_index(e->rows, (guint)e->selected))[0]) : NULL;
    e->filling = TRUE; e->selected = -1;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(e->list))) != NULL) gtk_list_box_remove(e->list, child);
    g_ptr_array_unref(e->rows); e->rows = rows;
    if (e->kind == 1) update_categories(e, categories);
    for (guint i = 0; i < e->rows->len; ++i) {
        gchar **row = g_ptr_array_index(e->rows, i);
        if (g_strcmp0(row[0], selected_id) == 0) e->selected = (gint)i;
        gchar *title = e->kind == 3 ? g_strdup_printf("%s -> %s (seen %s; %s)", row[1], row[2], row[3], row[7])
            : e->kind == 1 ? g_strdup_printf("%s -> %s [%s]", row[1], row[2], row[4])
            : g_strdup_printf("%s -> %s", row[1], row[2]);
        GtkWidget *label = gtk_label_new(title); gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_list_box_append(e->list, label);
        gtk_accessible_update_property(GTK_ACCESSIBLE(gtk_widget_get_parent(label)), GTK_ACCESSIBLE_PROPERTY_LABEL,
            title, -1);
        g_free(title);
    }
    e->filling = FALSE;
    if (e->selected >= 0) {
        vocabulary_fill(e, g_ptr_array_index(e->rows, (guint)e->selected));
    } else if (selected_id != NULL && (e->kind == 1 || e->kind == 4)) vocabulary_fill(e, NULL);
    g_free(selected_id);
    if (e->kind == 1 || e->kind == 4) apply_filters(e);
    else if (e->selected >= 0) gtk_list_box_select_row(e->list, gtk_list_box_get_row_at_index(e->list, e->selected));
    vocabulary_pending(e, FALSE);
    if (e->kind == 3 && vocabulary_editors[0] != NULL) jsti_window_emit(71, "", 0);
}
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh) {
    if (kind < 0 || kind > 4 || payload == NULL || strlen(payload) > 4 * 1024 * 1024
        || !g_utf8_validate(payload, -1, NULL)) return -1;
    Presentation *p = g_new0(Presentation, 1);
    p->kind = kind; p->payload = g_strdup(payload); p->refresh = refresh != 0;
    return jsti_window_post(vocabulary_present, p, presentation_free);
}

