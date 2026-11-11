/* Post-processing page: cleanup location, model and prompt controls. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowPolishPage.h"

static PolishPage polish_state = { .polish_remote_count = G_MAXUINT };
PolishPage *polish_page(void) { return &polish_state; }

guint polish_remote_boundary(void) {
    guint count = polish_page()->polish_catalog != NULL ? polish_page()->polish_catalog->len : 0;
    guint remote = polish_page()->polish_remote_count == G_MAXUINT
        ? (polish_page()->polish_local_index >= 0 ? (guint)polish_page()->polish_local_index : count) : polish_page()->polish_remote_count;
    return MIN(count, remote);
}

gint32 polish_selected_model(void) {
    guint row = adw_combo_row_get_selected(polish_page()->polish_model_row);
    return polish_page()->polish_slots != NULL && row < polish_page()->polish_slots->len
        ? g_array_index(polish_page()->polish_slots, gint32, row) : -1;
}

gchar *polish_prompt_text(void) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(polish_page()->polish_prompt_row);
    GtkTextIter first, last;
    gtk_text_buffer_get_bounds(buffer, &first, &last);
    return gtk_text_buffer_get_text(buffer, &first, &last, FALSE);
}

static void polish_update_model_controls(void) {
    guint location = adw_combo_row_get_selected(polish_page()->polish_location_row);
    gint32 selected = polish_selected_model();
    gboolean local = location == 0;
    gboolean available = selected >= 0 && polish_page()->polish_catalog != NULL &&
        (guint)selected < polish_page()->polish_catalog->len && ((guint)selected >= polish_remote_boundary()) == local;
    gboolean rules = available && selected == polish_page()->polish_local_index;
    gboolean instructions = available && !rules && location <= 1;
    adw_action_row_set_subtitle(ADW_ACTION_ROW(polish_page()->polish_location_row), location > 1
        ? "The stored model is unavailable. Choose Local or Remote and a supported model before applying."
        : !available ? (local ? "Choose a supported local model before applying."
        : "The remembered remote model is unavailable. Choose a supported remote model before applying.")
        : rules ? polish_page()->polish_local_notice
        : local ? "Runs privately in process. A verified GGUF model and pinned native runtime are required; no cloud or rules fallback."
        : "When enabled, transcript text and custom instructions are sent to OpenRouter. Charges may apply.");
    gtk_widget_set_sensitive(GTK_WIDGET(polish_page()->polish_model_row), location <= 1);
    gtk_widget_set_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row), instructions);
    gtk_widget_set_sensitive(GTK_WIDGET(polish_page()->polish_key_row), available && location == 1);
    gtk_widget_set_sensitive(GTK_WIDGET(polish_page()->polish_directives_row), instructions);
    gtk_widget_set_sensitive(GTK_WIDGET(polish_page()->polish_tags_row), instructions);
    gtk_widget_set_visible(GTK_WIDGET(polish_page()->polish_key_row), location == 1);
    if (polish_page()->polish_local_group != NULL) gtk_widget_set_visible(polish_page()->polish_local_group, local);
    if (location != 1) gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "");
}

void polish_select_location(gint32 desired, gboolean choose_first) {
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    guint location = adw_combo_row_get_selected(polish_page()->polish_location_row);
    gboolean local = location == 0;
    guint count = g_list_model_get_n_items(G_LIST_MODEL(polish_page()->polish_models));
    gtk_string_list_splice(polish_page()->polish_models, 0, count, NULL);
    g_array_set_size(polish_page()->polish_slots, 0);
    guint selected = GTK_INVALID_LIST_POSITION;
    if (location <= 1 && polish_page()->polish_catalog != NULL) {
        for (guint index = 0; index < polish_page()->polish_catalog->len; index++) {
            if ((index >= polish_remote_boundary()) != local) continue;
            gint32 slot = (gint32)index;
            g_array_append_val(polish_page()->polish_slots, slot);
            gtk_string_list_append(polish_page()->polish_models, g_ptr_array_index(polish_page()->polish_catalog, index));
            if (slot == desired || (choose_first && selected == GTK_INVALID_LIST_POSITION)) {
                selected = polish_page()->polish_slots->len - 1;
            }
        }
    }
    /* AdwComboRow auto-selects nonempty models on newer GTK. Keep an unavailable
       saved choice explicit rather than silently selecting a different model. */
    if (location <= 1 && selected == GTK_INVALID_LIST_POSITION) {
        gint32 slot = -1;
        g_array_append_val(polish_page()->polish_slots, slot);
        gtk_string_list_append(polish_page()->polish_models, "Choose a model…");
        selected = polish_page()->polish_slots->len - 1;
    }
    adw_combo_row_set_selected(polish_page()->polish_model_row, selected);
    if (selected < polish_page()->polish_slots->len) {
        gint32 full = g_array_index(polish_page()->polish_slots, gint32, selected);
        if (local) polish_page()->polish_local_selected = full;
        else polish_page()->polish_remote_selected = full;
    }
    polish_update_model_controls();
    ui.suppress = suppressed;
}

void on_polish_location(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (!ui.suppress) polish_select_location(adw_combo_row_get_selected(polish_page()->polish_location_row) == 0
        ? polish_page()->polish_local_selected : polish_page()->polish_remote_selected, FALSE);
}

void on_polish_model(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gint32 selected = polish_selected_model();
    if (selected >= 0) {
        if ((guint)selected >= polish_remote_boundary()) polish_page()->polish_local_selected = selected;
        else polish_page()->polish_remote_selected = selected;
    }
    polish_update_model_controls();
}

void on_polish_apply(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    guint row = adw_combo_row_get_selected(polish_page()->polish_model_row);
    guint location = adw_combo_row_get_selected(polish_page()->polish_location_row);
    if (row >= polish_page()->polish_slots->len || location > 1) {
        adw_action_row_set_subtitle(ADW_ACTION_ROW(polish_page()->polish_location_row),
            "Choose Local or Remote and a supported post-processing model before applying.");
        return;
    }
    gint32 model = g_array_index(polish_page()->polish_slots, gint32, row);
    if (model < 0 || polish_page()->polish_catalog == NULL || (guint)model >= polish_page()->polish_catalog->len ||
        (((guint)model >= polish_remote_boundary()) != (location == 0))) {
        adw_action_row_set_subtitle(ADW_ACTION_ROW(polish_page()->polish_location_row),
            "Choose a supported model in the selected source before applying.");
        return;
    }
    gint32 index = adw_switch_row_get_active(polish_page()->polish_row) ? model : -1 - model;
    gchar *raw_prompt = polish_prompt_text();
    if (strlen(raw_prompt) > 65535) {
        g_free(raw_prompt);
        jsti_window_update("Instructions must be at most 65535 UTF-8 bytes.", NULL, -1);
        return;
    }
    gchar *prompt = g_uri_escape_string(raw_prompt, NULL, TRUE);
    g_free(raw_prompt);
    gchar *key = g_uri_escape_string(location == 1
        ? gtk_editable_get_text(GTK_EDITABLE(polish_page()->polish_key_row)) : "", NULL, TRUE);
    gchar *text = g_strdup_printf("%s\t%s\t%d\t%d", prompt, key,
        adw_switch_row_get_active(polish_page()->polish_directives_row) ? 1 : 0,
        adw_switch_row_get_active(polish_page()->polish_tags_row) ? 1 : 0);
    emit(JSTI_EVENT_POST_PROCESSING, text, index);
    g_free(text);
    g_free(prompt);
    g_free(key);
    gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "");
}
