/* The Post-processing page: cleanup location, model and prompt controls, and
 * the host's post-processing setters. Owns PolishPage (LinuxWindowPolishState.h). */
#include "LinuxWindowPolishState.h"

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

GtkWidget *build_post_processing(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[2] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Post-processing", "Clean up transcripts locally or through OpenRouter. The original is always kept."));
    GtkWidget *polish = group("Clean-up");
    polish_page()->polish_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_row), "Enable post-processing");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_row));
    polish_page()->polish_location_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_location_row), "Model source");
    const char *locations[] = {"Local", "Remote", "Choose a source…", NULL};
    GtkStringList *location_names = gtk_string_list_new(locations);
    adw_combo_row_set_model(polish_page()->polish_location_row, G_LIST_MODEL(location_names));
    g_object_unref(location_names);
    adw_combo_row_set_selected(polish_page()->polish_location_row, 2);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_location_row));
    AdwActionRow *mode = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(mode), "Finished-transcript cleanup");
    adw_action_row_set_subtitle(mode,
        "Remote cleanup can stream previews when enabled in preferences. Local cleanup completes in one step.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(mode));
    polish_page()->polish_models = gtk_string_list_new(NULL);
    polish_page()->polish_slots = g_array_new(FALSE, FALSE, sizeof(gint32));
    polish_page()->polish_local_index = -1;
    polish_page()->polish_remote_selected = -1;
    polish_page()->polish_local_selected = -1;
    polish_page()->polish_model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_model_row), "Polishing model");
    adw_combo_row_set_model(polish_page()->polish_model_row, G_LIST_MODEL(polish_page()->polish_models));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_model_row));
    polish_page()->polish_directives_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_directives_row), "Include personal lexicon directives");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(polish_page()->polish_directives_row),
        "Use saved spelling and name instructions with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_directives_row));
    polish_page()->polish_tags_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_tags_row), "Include lexicon context tags");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(polish_page()->polish_tags_row),
        "Use saved context tags with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_tags_row));
    GtkWidget *prompt_label = gtk_label_new("Custom system instructions (optional)");
    gtk_label_set_xalign(GTK_LABEL(prompt_label), 0);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_label);
    polish_page()->polish_prompt_row = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(polish_page()->polish_prompt_row, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_top_margin(polish_page()->polish_prompt_row, 10);
    gtk_text_view_set_bottom_margin(polish_page()->polish_prompt_row, 10);
    gtk_text_view_set_left_margin(polish_page()->polish_prompt_row, 10);
    gtk_text_view_set_right_margin(polish_page()->polish_prompt_row, 10);
    gtk_accessible_update_property(GTK_ACCESSIBLE(polish_page()->polish_prompt_row),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Custom system instructions", -1);
    GtkWidget *prompt_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(prompt_scroll), 140);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(prompt_scroll), GTK_WIDGET(polish_page()->polish_prompt_row));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_scroll);
    polish_page()->polish_key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(polish_page()->polish_key_row), "New key for the selected model's provider (leave empty to keep)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(polish_page()->polish_key_row));
    g_signal_connect(polish_page()->polish_location_row, "notify::selected", G_CALLBACK(on_polish_location), NULL);
    g_signal_connect(polish_page()->polish_model_row, "notify::selected", G_CALLBACK(on_polish_model), NULL);
    GtkWidget *polish_apply = gtk_button_new_with_label("Apply");
    gtk_widget_add_css_class(polish_apply, "suggested-action");
    gtk_widget_set_halign(polish_apply, GTK_ALIGN_END);
    gtk_widget_set_margin_top(polish_apply, 8);
    g_signal_connect(polish_apply, "clicked", G_CALLBACK(on_polish_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), polish_apply);
    gtk_box_append(GTK_BOX(column), polish);
    polish_page()->polish_local_group = jsti_local_cleanup_group_new();
    gtk_widget_set_visible(polish_page()->polish_local_group, FALSE);
    gtk_box_append(GTK_BOX(column), polish_page()->polish_local_group);
    return page;
}

static void polish_free(gpointer pointer) {
    Polish *polish = pointer;
    g_ptr_array_unref(polish->models);
    g_free(polish->prompt);
    g_free(polish->local_notice);
    g_free(polish);
}

void polish_apply(gpointer pointer) {
    Polish *polish = pointer;
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    gint32 local_selected = polish_page()->polish_local_selected;
    gboolean retain_local = local_selected >= polish->local_index && polish_page()->polish_catalog != NULL &&
        (guint)local_selected < polish_page()->polish_catalog->len && (guint)local_selected < polish->models->len &&
        g_strcmp0(g_ptr_array_index(polish_page()->polish_catalog, local_selected),
                  g_ptr_array_index(polish->models, local_selected)) == 0;
    g_clear_pointer(&polish_page()->polish_catalog, g_ptr_array_unref);
    polish_page()->polish_catalog = g_ptr_array_ref(polish->models);
    polish_page()->polish_local_index = polish->local_index;
    polish_page()->polish_remote_count = (guint)polish->local_index;
    g_free(polish_page()->polish_local_notice);
    polish_page()->polish_local_notice = g_strdup(polish->local_notice);
    polish_page()->polish_remote_selected = polish->selected >= 0 && polish->selected < polish->local_index
        ? polish->selected : polish->remembered_remote_index;
    polish_page()->polish_local_selected = polish->selected >= polish->local_index ? polish->selected
        : retain_local ? local_selected : polish->local_index;
    adw_combo_row_set_selected(polish_page()->polish_location_row, polish->selected < 0
        ? 2 : (guint)polish->selected >= polish_remote_boundary() ? 0 : 1);
    polish_select_location(polish->selected, FALSE);
    adw_switch_row_set_active(polish_page()->polish_row, polish->enabled);
    adw_switch_row_set_active(polish_page()->polish_directives_row, polish->include_directives);
    adw_switch_row_set_active(polish_page()->polish_tags_row, polish->include_tags);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(polish_page()->polish_prompt_row),
        polish->prompt != NULL ? polish->prompt : "", -1);
    ui.suppress = suppressed;
}

void cleanup_sources_apply(gpointer pointer) {
    const guint count = GPOINTER_TO_UINT(pointer);
    if (polish_page()->polish_catalog == NULL || count > polish_page()->polish_catalog->len ||
        polish_page()->polish_local_index < 0 || count != (guint)polish_page()->polish_local_index) {
        jsti_window_update("The post-processing source boundary is inconsistent with its model choices.", NULL, -1);
        return;
    }
    gint32 selected = polish_selected_model();
    polish_page()->polish_remote_count = count;
    polish_select_location(selected, FALSE);
}

int32_t jsti_window_set_cleanup_sources(size_t count) {
    if (count > 10000) return -1;
    return post(cleanup_sources_apply, GUINT_TO_POINTER((guint)count), NULL);
}

int32_t jsti_window_set_post_processing(
    const char *const *models, size_t count, int32_t enabled, int32_t selected,
    int32_t local_index, int32_t remembered_remote_index, const char *local_notice,
    int32_t include_directives, int32_t include_tags, const char *prompt) {
    if (models == NULL || count == 0 || count > 10000 || (enabled != 0 && enabled != 1) ||
        selected < -1 || (selected >= 0 && (size_t)selected >= count) ||
        local_index < 0 || (size_t)local_index >= count || local_notice == NULL || *local_notice == '\0' ||
        remembered_remote_index < -1 || remembered_remote_index >= local_index ||
        !g_utf8_validate(local_notice, -1, NULL) || prompt == NULL ||
        !g_utf8_validate(prompt, -1, NULL) || strlen(prompt) > 65535 ||
        (include_directives != 0 && include_directives != 1) || (include_tags != 0 && include_tags != 1)) return -1;
    for (size_t index = 0; index < count; index++) {
        if (models[index] == NULL || !g_utf8_validate(models[index], -1, NULL)) return -1;
    }
    Polish *polish = g_new0(Polish, 1);
    polish->models = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(polish->models, g_strdup(models[index]));
    polish->enabled = enabled != 0;
    polish->include_directives = include_directives != 0;
    polish->include_tags = include_tags != 0;
    polish->selected = selected;
    polish->prompt = g_strdup(prompt);
    polish->local_index = local_index;
    polish->remembered_remote_index = remembered_remote_index;
    polish->local_notice = g_strdup(local_notice);
    return post(polish_apply, polish, polish_free);
}

void post_processing_enabled_apply(gpointer pointer) {
    gboolean suppress = ui.suppress;
    ui.suppress = TRUE;
    adw_switch_row_set_active(polish_page()->polish_row, *(gint32 *)pointer != 0);
    ui.suppress = suppress;
}

int32_t jsti_window_set_post_processing_enabled(int32_t enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    gint32 *value = g_new(gint32, 1);
    *value = enabled;
    return post(post_processing_enabled_apply, value, g_free);
}

/* The run is over: the catalogue and choices go with it. */
void polish_page_close(void) {
    g_clear_pointer(&polish_page()->polish_catalog, g_ptr_array_unref);
    g_clear_pointer(&polish_page()->polish_slots, g_array_unref);
    g_clear_pointer(&polish_page()->polish_local_notice, g_free);
}
