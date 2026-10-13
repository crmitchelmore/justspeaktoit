#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

GtkWidget *jsti_vocabulary_page_new(int kind);

typedef struct {
    int kind;
    GtkWidget *root, *fields[8], *preview, *preview_tags, *status, *search;
    GtkListBox *list;
    GPtrArray *rows;
    GPtrArray *buttons;
    gint selected;
    gboolean filling;
    GtkCheckButton *include_rules, *include_tags;
    GtkEntry *tags;
} Editor;
static Editor *editors[4];
static const char *activations[] = { "automatic", "requireContextMatch", "manual", NULL };
static const char *confidences[] = { "high", "medium", "low", NULL };

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
static gchar *text(GtkWidget *widget) {
    if (GTK_IS_TEXT_VIEW(widget)) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
        GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
        return gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    }
    return g_strdup(gtk_editable_get_text(GTK_EDITABLE(widget)));
}
static void set_text(GtkWidget *widget, const char *value) {
    if (GTK_IS_TEXT_VIEW(widget)) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget)), value, -1);
    else gtk_editable_set_text(GTK_EDITABLE(widget), value);
}
static gboolean combo(Editor *e, int i) { return e->kind == 0 && (i == 4 || i == 6); }
static gboolean check(Editor *e, int i) { return e->kind == 1 && (i == 5 || i == 6); }
static void fill(Editor *e, gchar **row) {
    if (e->kind == 3) {
        gchar *details = row == NULL ? g_strdup("Select a stored candidate. No edits in other apps are observed.")
            : g_strdup_printf("%s -> %s\nSeen: %s\nSource apps: %s\nFirst seen: %s\nLast seen: %s\nState: %s",
                row[1], row[2], row[3], row[4], row[5], row[6], row[7]);
        gtk_label_set_text(GTK_LABEL(e->fields[1]), details); g_free(details); return;
    }
    for (int i = 1; i < 8; ++i) {
        if (e->kind == 1 && i == 7) continue;
        const char *value = row != NULL ? row[i] : "";
        if (combo(e, i)) {
            const char **choices = i == 4 ? activations : confidences;
            guint selected = 0;
            for (guint j = 0; j < 3; ++j) if (g_strcmp0(value, choices[j]) == 0) selected = j;
            gtk_drop_down_set_selected(GTK_DROP_DOWN(e->fields[i]), selected);
        } else if (check(e, i)) {
            gtk_check_button_set_active(GTK_CHECK_BUTTON(e->fields[i]), g_strcmp0(value, "true") == 0);
        } else set_text(e->fields[i], value);
    }
}
static void pending(Editor *e, gboolean busy) {
    for (guint i = 0; i < e->buttons->len; ++i) gtk_widget_set_sensitive(g_ptr_array_index(e->buttons, i), !busy);
    gtk_widget_set_sensitive(GTK_WIDGET(e->list), !busy);
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
    if (e->selected >= 0) fill(e, g_ptr_array_index(e->rows, (guint)e->selected));
}
static gchar *action_payload(Editor *e, const char *action) {
    GString *payload = g_string_new(action);
    if (e->kind == 3) {
        if (g_strcmp0(action, "clear") != 0) {
            gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
            append_field(payload, row != NULL ? row[0] : "");
        }
    } else if (g_strcmp0(action, "preview") == 0) {
        gchar *sample = text(e->preview), *tags = text(e->preview_tags);
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
                gchar *value = text(e->fields[i]); append_field(payload, value); g_free(value);
            }
        }
    }
    return g_string_free(payload, FALSE);
}
static void send_action(Editor *e, const char *action) {
    gchar *payload = action_payload(e, action);
    pending(e, TRUE); gtk_label_set_text(GTK_LABEL(e->status), "Saving or previewing...");
    jsti_window_emit(70, payload, e->kind); g_free(payload);
}
static void delete_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    Editor *e = g_object_get_data(G_OBJECT(data), "vocabulary-editor");
    if (e != NULL && g_strcmp0(response, "delete") == 0) send_action(e, "delete");
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
    pending(e, TRUE); jsti_window_emit(70, payload->str, e->kind); g_string_free(payload, TRUE);
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
        pending(e, TRUE); jsti_window_emit(70, payload, 3);
    }
}
static void clicked(GtkButton *button, gpointer data) {
    Editor *e = data;
    const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
    if (g_strcmp0(action, "candidates") == 0) {
        if (editors[3] != NULL) {
            GtkRoot *existing = gtk_widget_get_root(editors[3]->root);
            if (GTK_IS_WINDOW(existing)) gtk_window_present(GTK_WINDOW(existing));
            return;
        }
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *window = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(window), "Stored correction candidates");
        gtk_window_set_default_size(GTK_WINDOW(window), 800, 640);
        if (GTK_IS_WINDOW(root)) gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(root));
        gtk_window_set_destroy_with_parent(GTK_WINDOW(window), TRUE);
        gtk_window_set_modal(GTK_WINDOW(window), TRUE);
        gtk_window_set_child(GTK_WINDOW(window), jsti_vocabulary_page_new(3));
        gtk_window_present(GTK_WINDOW(window)); jsti_window_emit(71, "", 3); return;
    }
    if (e->kind == 3 && g_strcmp0(action, "refresh") != 0) {
        if (g_strcmp0(action, "clear") != 0 && e->selected < 0) {
            gtk_label_set_text(GTK_LABEL(e->status), "Select a stored candidate first."); return;
        }
        if (g_strcmp0(action, "promote") == 0) { send_action(e, action); return; }
        GtkRoot *root = gtk_widget_get_root(e->root);
        GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
            "Change stored candidates?", g_strcmp0(action, "clear") == 0
                ? "Clear all stored candidates? Saved correction rules stay unchanged."
                : g_strcmp0(action, "dismiss") == 0 ? "Dismiss this stored candidate?" : "Remove this stored candidate?");
        g_object_set_data_full(G_OBJECT(dialog), "candidate-payload", action_payload(e, action), g_free);
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "apply", "Confirm", NULL);
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "apply", ADW_RESPONSE_DESTRUCTIVE);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_signal_connect_object(dialog, "response", G_CALLBACK(candidate_response), e->root, 0);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    if (g_strcmp0(action, "new") == 0) {
        e->selected = -1; gtk_list_box_unselect_all(e->list); fill(e, NULL); return;
    }
    if (g_strcmp0(action, "refresh") == 0) {
        pending(e, TRUE); jsti_window_emit(71, "", e->kind); return;
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
    send_action(e, action);
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
    GtkWidget *label = gtk_list_box_row_get_child(row);
    gchar *haystack = g_utf8_casefold(gtk_label_get_text(GTK_LABEL(label)), -1), *needle = g_utf8_casefold(query, -1);
    gboolean match = strstr(haystack, needle) != NULL;
    g_free(haystack); g_free(needle); return match;
}
static void search_changed(GtkSearchEntry *search, gpointer data) {
    (void)search; Editor *e = data; gtk_list_box_invalidate_filter(e->list);
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
    if (editors[e->kind] == e) editors[e->kind] = NULL;
    g_ptr_array_unref(e->rows); g_ptr_array_unref(e->buttons); g_free(e);
}
GtkWidget *jsti_vocabulary_page_new(int kind) {
    Editor *e = g_new0(Editor, 1); e->kind = kind; e->selected = -1;
    e->rows = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    e->buttons = g_ptr_array_new();
    GtkWidget *column, *page = jsti_page_new(&column); e->root = page; editors[kind] = e;
    g_object_set_data_full(G_OBJECT(page), "vocabulary-editor", e, destroy_editor);
    GtkWidget *hero = jsti_hero_new("settings", kind == 0 ? "Corrections"
        : kind == 3 ? "Stored correction candidates" : "Pronunciation Dictionary",
        kind == 0 ? "Preferred spellings before post-processing. The original provider transcript stays in History."
        : kind == 3 ? "Review real stored candidates. Automatic observation of edits in other apps is not available."
        : "Your Read aloud dictionary. Deepgram uses text replacements, not IPA phoneme tags.", NULL, NULL);
    gtk_box_append(GTK_BOX(column), hero);
    e->search = gtk_search_entry_new();
    gtk_widget_set_tooltip_text(e->search, "Search saved entries");
    g_signal_connect(e->search, "search-changed", G_CALLBACK(search_changed), e);
    gtk_box_append(GTK_BOX(column), e->search);
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
        fill(e, NULL); pending(e, TRUE); return page;
    }
    const char *names[] = {"_New", "_Delete", "Move _up", "Move _down", "_Reload"};
    const char *values[] = {"new", "delete", "up", "down", "refresh"};
    for (int i = 0; i < 5; ++i) gtk_box_append(GTK_BOX(actions), button(e, names[i], values[i]));
    gtk_box_append(GTK_BOX(column), actions);
    const char *rules[] = {"Display name", "Canonical spelling", "Spoken variants (one per line)", "Activation",
        "Context tags (comma-separated)", "Confidence", "Notes"};
    const char *speech[] = {"Word or pattern", "Pronunciation", "Text replacement", "Category",
        "Regular expression", "Case sensitive", "Notes (not stored)"};
    for (int i = 1; i < 8; ++i) {
        if (kind == 1 && i == 7) continue;
        GtkWidget *label = gtk_label_new((kind == 0 ? rules : speech)[i - 1]);
        gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_box_append(GTK_BOX(column), label);
        GtkWidget *widget;
        if (combo(e, i)) {
            const char *a[] = {"Automatic", "Require context match", "Manual confirmation", NULL};
            const char *c[] = {"High", "Medium", "Low", NULL};
            widget = gtk_drop_down_new_from_strings(i == 4 ? a : c); e->fields[i] = widget;
        } else if (check(e, i)) {
            widget = gtk_check_button_new_with_label(speech[i - 1]); e->fields[i] = widget;
        } else if (kind == 0 && i == 3) widget = multiline(&e->fields[i]);
        else { widget = gtk_entry_new(); e->fields[i] = widget; }
        gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->fields[i]);
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->fields[i]), GTK_ACCESSIBLE_PROPERTY_LABEL,
            (kind == 0 ? rules : speech)[i - 1], -1);
        gtk_box_append(GTK_BOX(column), widget);
    }
    gtk_box_append(GTK_BOX(column), button(e, "_Save entry", "save"));
    if (kind == 1) {
        gtk_box_append(GTK_BOX(column), button(e, "Add default _entries", "defaults"));
        GtkWidget *transfers = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_box_append(GTK_BOX(transfers), button(e, "_Import JSON (merge)", "importMerge"));
        gtk_box_append(GTK_BOX(transfers), button(e, "Import JSON (replace)", "importReplace"));
        gtk_box_append(GTK_BOX(transfers), button(e, "_Export JSON", "export"));
        gtk_box_append(GTK_BOX(column), transfers);
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
        label = gtk_label_new("Automatic observation of edits in other apps is not available on this platform.");
        gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_box_append(GTK_BOX(column), label);
    }
    e->status = gtk_label_new("Select Reload to load saved entries.");
    gtk_label_set_wrap(GTK_LABEL(e->status), TRUE); gtk_label_set_selectable(GTK_LABEL(e->status), TRUE);
    gtk_label_set_xalign(GTK_LABEL(e->status), 0); gtk_box_append(GTK_BOX(column), e->status);
    fill(e, NULL); return page;
}
typedef struct { int kind; gchar *payload; gboolean refresh; } Presentation;
static void presentation_free(gpointer data) {
    Presentation *p = data; g_free(p->payload); g_free(p);
}
static void present(gpointer data) {
    Presentation *p = data;
    if (p->kind == 2) {
        Editor *source = editors[0];
        if (source == NULL) return;
        GtkRoot *root = gtk_widget_get_root(source->root);
        if (!GTK_IS_WINDOW(root)) return;
        GtkWidget *dialog = adw_message_dialog_new(GTK_WINDOW(root), "Recording corrections",
            "Retained applied corrections and suggestions; the provider transcript is unchanged.");
        GtkWidget *view, *scroll = multiline(&view);
        gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 360);
        set_text(view, p->payload);
        gtk_accessible_update_property(GTK_ACCESSIBLE(view), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Retained recording correction results", -1);
        adw_message_dialog_set_extra_child(ADW_MESSAGE_DIALOG(dialog), scroll);
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "close", "Close", NULL);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "close");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "close");
        gtk_window_present(GTK_WINDOW(dialog));
        return;
    }
    Editor *e = editors[p->kind];
    if (e == NULL) return;
    if (!p->refresh) { gtk_label_set_text(GTK_LABEL(e->status), p->payload); pending(e, FALSE); return; }
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
    g_strfreev(header);
    gchar *selected_id = e->selected >= 0
        ? g_strdup(((gchar **)g_ptr_array_index(e->rows, (guint)e->selected))[0]) : NULL;
    e->filling = TRUE; e->selected = -1;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(e->list))) != NULL) gtk_list_box_remove(e->list, child);
    g_ptr_array_set_size(e->rows, 0);
    for (guint i = 1; lines[i] != NULL; ++i) {
        gchar **row = g_strsplit(lines[i], "\t", -1);
        if (g_strv_length(row) != 8) { g_strfreev(row); continue; }
        gboolean valid = TRUE;
        for (int j = 0; j < 8; ++j) {
            gchar *value = g_uri_unescape_string(row[j], NULL);
            if (value == NULL) { valid = FALSE; break; }
            g_free(row[j]); row[j] = value;
        }
        if (!valid) { g_strfreev(row); continue; }
        if (g_strcmp0(row[0], selected_id) == 0) e->selected = (gint)e->rows->len;
        gchar *title = e->kind == 3 ? g_strdup_printf("%s -> %s (seen %s; %s)", row[1], row[2], row[3], row[7])
            : e->kind == 1 ? g_strdup_printf("%s -> %s [%s]", row[1], row[2], row[4])
            : g_strdup_printf("%s -> %s", row[1], row[2]);
        GtkWidget *label = gtk_label_new(title); gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_list_box_append(e->list, label);
        g_free(title); g_ptr_array_add(e->rows, row);
    }
    g_strfreev(lines); g_free(selected_id); e->filling = FALSE;
    if (e->selected >= 0) {
        gtk_list_box_select_row(e->list, gtk_list_box_get_row_at_index(e->list, e->selected));
        fill(e, g_ptr_array_index(e->rows, (guint)e->selected));
    }
    pending(e, FALSE);
    if (e->kind == 3 && editors[0] != NULL) jsti_window_emit(71, "", 0);
}
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh) {
    if (kind < 0 || kind > 3 || payload == NULL || strlen(payload) > 4 * 1024 * 1024
        || !g_utf8_validate(payload, -1, NULL)) return -1;
    Presentation *p = g_new0(Presentation, 1);
    p->kind = kind; p->payload = g_strdup(payload); p->refresh = refresh != 0;
    return jsti_window_post(present, p, presentation_free);
}

int32_t jsti_vocabulary_self_test(char *error, size_t capacity) {
    for (int kind = 0; kind < 2; ++kind) {
        Editor *e = editors[kind];
        if (e == NULL) { jsti_set_error(error, capacity, "Vocabulary editor was not constructed."); return -1; }
        gchar *row[] = {"", "Synthetic", "Canonical", "spoken\nvariant\t%", kind == 0 ? "manual" : "Custom",
            kind == 0 ? "work" : "true", kind == 0 ? "low" : "true", "fixture notes", NULL};
        fill(e, row);
        gchar *payload = action_payload(e, "save");
        gchar **fields = g_strsplit(payload, "\t", -1);
        gchar *variant = g_strv_length(fields) == 9 ? g_uri_unescape_string(fields[4], NULL) : NULL;
        gboolean valid = g_strv_length(fields) == 9 && g_strcmp0(variant, row[3]) == 0
            && g_strcmp0(fields[5], row[4]) == 0 && g_strcmp0(fields[7], row[6]) == 0;
        g_free(variant); g_strfreev(fields); g_free(payload);
        set_text(e->preview, "Synthetic\t%\n"); set_text(e->preview_tags, "work");
        payload = action_payload(e, "preview"); fields = g_strsplit(payload, "\t", -1);
        variant = g_strv_length(fields) == 3 ? g_uri_unescape_string(fields[1], NULL) : NULL;
        valid = valid && g_strcmp0(variant, "Synthetic\t%\n") == 0 && g_strcmp0(fields[2], "work") == 0;
        g_free(variant); g_strfreev(fields); g_free(payload);
        fill(e, NULL); set_text(e->preview, ""); set_text(e->preview_tags, "");
        if (!valid) { jsti_set_error(error, capacity, "Vocabulary field and preview events were not preserved."); return -1; }
    }
    Editor *existing_candidates = editors[3];
    GtkWidget *candidate_page = jsti_vocabulary_page_new(3);
    g_object_ref_sink(candidate_page);
    Editor *candidate = editors[3];
    const gchar *fixture[] = {"synthetic\t%", "Synthetic", "Canonical", "2", "Synthetic", "", "", "Pending", NULL};
    g_ptr_array_add(candidate->rows, g_strdupv((gchar **)fixture)); candidate->selected = 0;
    gchar *candidate_payload = action_payload(candidate, "promote");
    gchar **candidate_fields = g_strsplit(candidate_payload, "\t", -1);
    gchar *candidate_id = g_strv_length(candidate_fields) == 2
        ? g_uri_unescape_string(candidate_fields[1], NULL) : NULL;
    gboolean candidate_valid = g_strcmp0(candidate_id, fixture[0]) == 0
        && g_strcmp0(candidate_fields[0], "promote") == 0;
    g_free(candidate_id); g_strfreev(candidate_fields); g_free(candidate_payload);
    candidate_payload = action_payload(candidate, "clear");
    candidate_valid = candidate_valid && g_strcmp0(candidate_payload, "clear") == 0;
    g_free(candidate_payload); g_object_unref(candidate_page); editors[3] = existing_candidates;
    if (!candidate_valid) { jsti_set_error(error, capacity, "Stored candidate events were not preserved."); return -1; }
    return 0;
}
