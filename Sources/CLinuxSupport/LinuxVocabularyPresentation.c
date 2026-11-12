/* Host payloads for the vocabulary editors: rows, notices and the Pronunciation
 * category metadata, applied on the GTK main thread, plus the retained
 * recording-corrections dialog. */
#include "LinuxVocabularyInternal.h"
#include <adwaita.h>
#include <string.h>

void vocabulary_category_free(gpointer data) {
    Category *category = data; g_free(category->value); g_free(category);
}
static GPtrArray *category_options(gchar **header, GPtrArray *rows) {
    const guint length = g_strv_length(header);
    GPtrArray *options = g_ptr_array_new_with_free_func(vocabulary_category_free);
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
static void presentation_free(gpointer data) {
    Presentation *p = data; g_free(p->payload); g_free(p);
}
void vocabulary_present(gpointer data) {
    Presentation *p = data;
    if (p->kind == 2) {
        Editor *source = vocabulary_editor(0);
        if (source == NULL) return;
        GtkRoot *root = gtk_widget_get_root(source->root);
        if (!GTK_IS_WINDOW(root)) return;
        GtkWidget *dialog = adw_message_dialog_new(GTK_WINDOW(root), "Recording corrections",
            "Retained applied corrections and suggestions; the provider transcript is unchanged.");
        GtkWidget *view, *scroll = vocabulary_multiline(&view);
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
    Editor *e = vocabulary_editor(p->kind);
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
    if (e->kind == 1 || e->kind == 4) vocabulary_apply_filters(e);
    else if (e->selected >= 0) gtk_list_box_select_row(e->list, gtk_list_box_get_row_at_index(e->list, e->selected));
    vocabulary_pending(e, FALSE);
    if (e->kind == 3 && vocabulary_editor(0) != NULL) jsti_window_emit(71, "", 0);
}
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh) {
    if (kind < 0 || kind > 4 || payload == NULL || strlen(payload) > 4 * 1024 * 1024
        || !g_utf8_validate(payload, -1, NULL)) return -1;
    Presentation *p = g_new0(Presentation, 1);
    p->kind = kind; p->payload = g_strdup(payload); p->refresh = refresh != 0;
    return jsti_window_post(vocabulary_present, p, presentation_free);
}
