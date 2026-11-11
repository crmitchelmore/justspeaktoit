/* jsti_window_* setters for History presentation, text output, playback, post-processing and Azure. */
#include "LinuxWindowInternal.h"

static void presentation_free(gpointer pointer) {
    Presentation *presentation = pointer;
    g_free(presentation->id);
    g_free(presentation->text);
    g_free(presentation->status);
    g_free(presentation);
}

void presentation_apply(gpointer pointer) {
    Presentation *presentation = pointer;
    /* Only the selected record's content may be shown under its actions. */
    if (g_strcmp0(presentation->id, ui.selected_id) != 0) return;
    ui.suppress = TRUE;
    if (presentation->has_text) {
        set_transcript(presentation->text);
        if (presentation->status != NULL) gtk_label_set_text(ui.status, presentation->status);
    }
    g_free(ui.presented_id);
    ui.presented_id = g_strdup(presentation->id);
    cleanup_preview.visible = FALSE;
    ui.presented_variant = presentation->variant;
    ui.presented_switchable = presentation->switchable;
    if (presentation->variant >= 0) gtk_drop_down_set_selected(ui.version, (guint)presentation->variant);
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_history_presentation(
    const char *record_id, int32_t variant, int32_t switchable, const char *text, const char *status) {
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->text = g_strdup(text != NULL ? text : "");
    presentation->status = g_strdup(status);
    presentation->has_text = TRUE;
    return post(presentation_apply, presentation, presentation_free);
}

int32_t jsti_window_set_transcript_variant(const char *record_id, int32_t variant, int32_t switchable) {
    if (record_id == NULL || record_id[0] == '\0') {
        return post((apply_fn)refresh_actions, NULL, NULL);
    }
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->has_text = FALSE;
    return post(presentation_apply, presentation, presentation_free);
}

static void text_output_free(gpointer pointer) {
    TextOutput *output = pointer;
    g_free(output->hint);
    g_free(output->policy_title);
    g_free(output->policy_labels);
    g_free(output->policy_help);
    g_free(output);
}

void text_output_apply(gpointer pointer) {
    TextOutput *output = pointer;
    ui.suppress = TRUE;
    ui.can_restore_clipboard = output->can_restore;
    if (output->policy_labels != NULL) {
        gchar **labels = g_strsplit(output->policy_labels, "\n", -1);
        GtkStringList *model = gtk_string_list_new((const char *const *)labels);
        adw_combo_row_set_model(ui.app_switch_row, G_LIST_MODEL(model));
        g_object_unref(model);
        g_strfreev(labels);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.app_switch_row), output->policy_title);
        gtk_label_set_text(ui.app_switch_help, output->policy_help);
        adw_combo_row_set_selected(ui.app_switch_row, output->policy_selection);
        ui.app_switch_configured = TRUE;
    }
    adw_combo_row_set_selected(ui.output_row, output->method == 1 ? 1 : 0);
    adw_switch_row_set_active(ui.restore_row, output->restore);
    gtk_widget_set_visible(GTK_WIDGET(ui.restore_row), output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), output->method != 1 && output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), output->method != 1 && ui.app_switch_configured);
    gboolean explicit_policy = ui.app_switch_configured && adw_combo_row_get_selected(ui.app_switch_row) != 0;
    adw_preferences_group_set_description(ui.output_group, explicit_policy ?
        "The saved app-switch policy is enforced. Unsupported or uncertain destinations copy only; "
        "the delivery support explanation below describes this desktop's limits." : output->can_restore ?
        "Finished text goes to the app you were in when dictation started. Recording in this window offers "
        "Copy instead." :
        "Wayland pastes into the app focused at delivery and cannot confirm when it consumes the paste, "
        "so the transcript stays on the clipboard. Your X11 restoration preference is retained. "
        "Recording in this window offers Copy instead.");
    if (output->hint != NULL) adw_action_row_set_subtitle(ui.shortcut_row, output->hint);
    ui.suppress = FALSE;
    refresh_setup();
}

int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard,
                                   int32_t can_restore_clipboard, const char *shortcut_hint) {
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    return post(text_output_apply, output, text_output_free);
}

int32_t jsti_window_set_text_output_policy(
    int32_t method, int32_t restore_clipboard, int32_t can_restore_clipboard, const char *shortcut_hint,
    const char *policy_title, const char *policy_labels, int32_t policy_selection, const char *policy_help) {
    if (method < 0 || method > 1 || policy_title == NULL || *policy_title == '\0' || policy_labels == NULL ||
        policy_help == NULL || !g_utf8_validate(policy_title, -1, NULL) ||
        !g_utf8_validate(policy_labels, -1, NULL) || !g_utf8_validate(policy_help, -1, NULL)) return -1;
    gchar **labels = g_strsplit(policy_labels, "\n", -1);
    guint count = g_strv_length(labels);
    gboolean valid = count > 0 && policy_selection >= 0 && (guint)policy_selection < count;
    for (guint index = 0; index < count; index++) valid = valid && *labels[index] != '\0';
    g_strfreev(labels);
    if (!valid) return -1;
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    output->policy_title = g_strdup(policy_title);
    output->policy_labels = g_strdup(policy_labels);
    output->policy_help = g_strdup(policy_help);
    output->policy_selection = policy_selection;
    return post(text_output_apply, output, text_output_free);
}

int32_t jsti_window_transcript_snapshot(char *buffer, size_t capacity, size_t *required) {
    gchar *text = ui.export_text != NULL ? g_strdup(ui.export_text) : displayed_transcript();
    size_t length = strlen(text) + 1;
    if (required != NULL) *required = length;
    if (buffer == NULL || capacity < length) {
        g_free(text);
        return 2;
    }
    memcpy(buffer, text, length);
    g_free(text);
    return 0;
}

int32_t jsti_window_transcript_variant(void) {
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return -1;
    if (!ui.presented_switchable) return ui.presented_variant < 0 ? -1 : 1;
    return (int32_t)gtk_drop_down_get_selected(ui.version);
}

typedef struct Playback {
    gchar *id;
    gint32 state;
    gchar *text;
} Playback;

static void playback_free(gpointer pointer) {
    Playback *playback = pointer;
    g_free(playback->id);
    g_free(playback->text);
    g_free(playback);
}

static void playback_apply(gpointer pointer) {
    Playback *playback = pointer;
    if (g_strcmp0(playback->id, ui.selected_id) != 0) return;
    ui.playback_state = playback->state;
    gtk_label_set_text(ui.playback_label, playback->text != NULL ? playback->text : "");
    refresh_actions();
}

int32_t jsti_window_set_playback(const char *record_id, int32_t state, const char *text) {
    Playback *playback = g_new0(Playback, 1);
    playback->id = g_strdup(record_id);
    playback->state = state;
    playback->text = g_strdup(text);
    return post(playback_apply, playback, playback_free);
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
    gint32 local_selected = ui.polish_local_selected;
    gboolean retain_local = local_selected >= polish->local_index && ui.polish_catalog != NULL &&
        (guint)local_selected < ui.polish_catalog->len && (guint)local_selected < polish->models->len &&
        g_strcmp0(g_ptr_array_index(ui.polish_catalog, local_selected),
                  g_ptr_array_index(polish->models, local_selected)) == 0;
    g_clear_pointer(&ui.polish_catalog, g_ptr_array_unref);
    ui.polish_catalog = g_ptr_array_ref(polish->models);
    ui.polish_local_index = polish->local_index;
    polish_remote_count = (guint)polish->local_index;
    g_free(ui.polish_local_notice);
    ui.polish_local_notice = g_strdup(polish->local_notice);
    ui.polish_remote_selected = polish->selected >= 0 && polish->selected < polish->local_index
        ? polish->selected : polish->remembered_remote_index;
    ui.polish_local_selected = polish->selected >= polish->local_index ? polish->selected
        : retain_local ? local_selected : polish->local_index;
    adw_combo_row_set_selected(ui.polish_location_row, polish->selected < 0
        ? 2 : (guint)polish->selected >= polish_remote_boundary() ? 0 : 1);
    polish_select_location(polish->selected, FALSE);
    adw_switch_row_set_active(ui.polish_row, polish->enabled);
    adw_switch_row_set_active(ui.polish_directives_row, polish->include_directives);
    adw_switch_row_set_active(ui.polish_tags_row, polish->include_tags);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.polish_prompt_row),
        polish->prompt != NULL ? polish->prompt : "", -1);
    ui.suppress = suppressed;
}

void cleanup_sources_apply(gpointer pointer) {
    const guint count = GPOINTER_TO_UINT(pointer);
    if (ui.polish_catalog == NULL || count > ui.polish_catalog->len ||
        ui.polish_local_index < 0 || count != (guint)ui.polish_local_index) {
        jsti_window_update("The post-processing source boundary is inconsistent with its model choices.", NULL, -1);
        return;
    }
    gint32 selected = polish_selected_model();
    polish_remote_count = count;
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

static void azure_apply(gpointer data) {
    ui.suppress = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(ui.azure_row), data != NULL ? data : "");
    ui.suppress = FALSE;
}

int32_t jsti_window_set_azure_resource(const char *endpoint) {
    return post(azure_apply, g_strdup(endpoint != NULL ? endpoint : ""), g_free);
}
