/* Self-tests for post-processing, local cleanup sources, cleanup preview and migration restore. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowDashboardPage.h"
#include "../CLinuxSupport/LinuxWindowHistoryPage.h"
#include "../CLinuxSupport/LinuxWindowPolishPage.h"
#include "../CLinuxSupport/LinuxWindowStoragePage.h"

gboolean post_processing_self_test(void) {
    if (polish_page()->polish_catalog == NULL || polish_page()->polish_local_notice == NULL) return FALSE;
    guint row = adw_combo_row_get_selected(polish_page()->polish_model_row);
    Polish saved = {
        .models = g_ptr_array_ref(polish_page()->polish_catalog),
        .enabled = adw_switch_row_get_active(polish_page()->polish_row),
        .include_directives = adw_switch_row_get_active(polish_page()->polish_directives_row),
        .include_tags = adw_switch_row_get_active(polish_page()->polish_tags_row),
        .selected = row < polish_page()->polish_slots->len ? g_array_index(polish_page()->polish_slots, gint32, row) : -1,
        .local_index = polish_page()->polish_local_index,
        .remembered_remote_index = polish_page()->polish_remote_selected,
        .local_notice = g_strdup(polish_page()->polish_local_notice),
        .prompt = polish_prompt_text()
    };
    guint saved_location = adw_combo_row_get_selected(polish_page()->polish_location_row);
    guint saved_remote = polish_page()->polish_remote_count;
    gint32 saved_local = polish_page()->polish_local_selected;
    GPtrArray *names = g_ptr_array_new();
    g_ptr_array_add(names, (gpointer)"Remote first");
    g_ptr_array_add(names, (gpointer)"Remote second");
    g_ptr_array_add(names, (gpointer)"Local Cleanup (Offline)");
    Polish fixture = {
        .models = names, .enabled = TRUE, .selected = 1, .local_index = 2,
        .remembered_remote_index = 1,
        .include_directives = FALSE, .include_tags = TRUE,
        .local_notice = (gchar *)"Built-in rules ignore custom instructions. No API key is needed.",
        .prompt = (gchar *)"Keep remote instructions."
    };
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    polish_apply(&fixture);
    gboolean okay = adw_combo_row_get_selected(polish_page()->polish_location_row) == 1 &&
        adw_combo_row_get_selected(polish_page()->polish_model_row) == 1 &&
        g_list_model_get_n_items(G_LIST_MODEL(polish_page()->polish_models)) == 2 &&
        gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_key_row)) &&
        !adw_switch_row_get_active(polish_page()->polish_directives_row) && adw_switch_row_get_active(polish_page()->polish_tags_row) &&
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(polish_page()->polish_directives_row)),
            "Include personal lexicon directives") == 0 &&
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(polish_page()->polish_tags_row)),
            "Include lexicon context tags") == 0;
    gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "synthetic-key");
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == JSTI_EVENT_POST_PROCESSING && observed.index == 1 &&
        g_strcmp0(observed.text, "Keep%20remote%20instructions.\tsynthetic-key\t0\t1") == 0;
    observed.event = 0;
    adw_combo_row_set_selected(polish_page()->polish_location_row, 0);
    okay = okay && observed.event == 0 &&
        g_list_model_get_n_items(G_LIST_MODEL(polish_page()->polish_models)) == 1 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_key_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row)) &&
        g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(polish_page()->polish_location_row)), fixture.local_notice) == 0;
    gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "must-not-reach-callback");
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == 2 &&
        g_strcmp0(observed.text, "Keep%20remote%20instructions.\t\t0\t1") == 0;
    adw_switch_row_set_active(polish_page()->polish_row, FALSE);
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == -3;
    fixture.selected = 2;
    polish_apply(&fixture);
    adw_combo_row_set_selected(polish_page()->polish_location_row, 1);
    row = adw_combo_row_get_selected(polish_page()->polish_model_row);
    okay = okay && row < polish_page()->polish_slots->len && g_array_index(polish_page()->polish_slots, gint32, row) == 1;
    fixture.remembered_remote_index = -1;
    polish_apply(&fixture);
    adw_combo_row_set_selected(polish_page()->polish_location_row, 1);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 && polish_selected_model() == -1 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_key_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row));
    fixture.selected = -1;
    polish_apply(&fixture);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 && polish_selected_model() == -1 &&
        adw_combo_row_get_selected(polish_page()->polish_location_row) == 2 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_model_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_key_row));
    adw_combo_row_set_selected(polish_page()->polish_location_row, 1);
    adw_combo_row_set_selected(polish_page()->polish_model_row, 0);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == JSTI_EVENT_POST_PROCESSING && observed.index == 0 &&
        polish_selected_model() == 0 && gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row));
    const char *labels[] = {"Remote", "Local"};
    okay = okay && jsti_window_set_post_processing(labels, 2, 1, 0, 2, -1, fixture.local_notice, 1, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 2, 0, 1, -1, fixture.local_notice, 1, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 1, 0, 1, -1, fixture.local_notice, 2, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 1, 0, 1, 1, fixture.local_notice, 1, 1, "") == -1;
    polish_apply(&saved);
    polish_page()->polish_remote_count = saved_remote;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(polish_page()->polish_location_row, saved_location);
    polish_select_location(saved.selected, FALSE);
    polish_page()->polish_local_selected = saved_local;
    ui.suppress = FALSE;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    g_ptr_array_unref(names);
    g_ptr_array_unref(saved.models);
    g_free(saved.local_notice);
    g_free(saved.prompt);
    return okay;
}

int32_t local_cleanup_sources_self_test(char *error, size_t capacity) {
    if (polish_page()->polish_catalog == NULL || polish_page()->polish_local_notice == NULL)
        return fail(error, capacity, "post-processing was not configured before its source fixture");
    Polish saved = {
        .models = g_ptr_array_ref(polish_page()->polish_catalog),
        .enabled = adw_switch_row_get_active(polish_page()->polish_row),
        .include_directives = adw_switch_row_get_active(polish_page()->polish_directives_row),
        .include_tags = adw_switch_row_get_active(polish_page()->polish_tags_row),
        .selected = polish_selected_model(), .local_index = polish_page()->polish_local_index,
        .remembered_remote_index = polish_page()->polish_remote_selected,
        .local_notice = g_strdup(polish_page()->polish_local_notice), .prompt = polish_prompt_text()
    };
    const guint saved_location = adw_combo_row_get_selected(polish_page()->polish_location_row);
    const guint saved_remote = polish_page()->polish_remote_count;
    const gint32 saved_local = polish_page()->polish_local_selected;
    Polish fixture = {.models = g_ptr_array_new_with_free_func(g_free), .enabled = TRUE,
        .selected = 4, .local_index = 2, .remembered_remote_index = 1,
        .include_directives = FALSE, .include_tags = TRUE,
        .local_notice = "Built-in rules ignore custom instructions and context.",
        .prompt = "One stop after each word.\nExact\tsecond line."};
    const char *names[] = {"Remote A", "Remote B", "Built-in rules", "Local A", "Local B"};
    for (size_t i = 0; i < G_N_ELEMENTS(names); ++i) g_ptr_array_add(fixture.models, g_strdup(names[i]));
    polish_apply(&fixture);
    polish_page()->polish_remote_count = G_MAXUINT;
    cleanup_sources_apply(GUINT_TO_POINTER(2));
    const char *failure_stage = NULL;
    gboolean okay = adw_combo_row_get_selected(polish_page()->polish_location_row) == 0
        && adw_combo_row_get_selected(polish_page()->polish_model_row) == 2 && polish_selected_model() == 4
        && g_list_model_get_n_items(G_LIST_MODEL(polish_page()->polish_models)) == 3
        && !gtk_widget_get_visible(GTK_WIDGET(polish_page()->polish_key_row))
        && gtk_widget_get_visible(polish_page()->polish_local_group)
        && gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row))
        && gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row))
        && gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row));
    if (!okay && failure_stage == NULL) failure_stage = "initial local source, selection and controls";
    gchar *actual_prompt = polish_prompt_text();
    okay = okay && g_strcmp0(actual_prompt, fixture.prompt) == 0;
    if (!okay && failure_stage == NULL) failure_stage = "prompt preservation";
    jsti_window_event_fn saved_callback = ui.callback;
    ui.callback = observe_event;
    gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "must-not-reach-local-callback");
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == JSTI_EVENT_POST_PROCESSING && observed.index == 4
        && g_strcmp0(observed.text, "One%20stop%20after%20each%20word.%0AExact%09second%20line.\t\t0\t1") == 0;
    if (!okay && failure_stage == NULL) failure_stage = "local callback and private key filtering";
    observed.event = 0;
    adw_combo_row_set_selected(polish_page()->polish_location_row, 1);
    okay = okay && gtk_widget_get_visible(GTK_WIDGET(polish_page()->polish_key_row))
        && !gtk_widget_get_visible(polish_page()->polish_local_group)
        && polish_selected_model() == 1 && observed.event == 0;
    if (!okay && failure_stage == NULL) failure_stage = "remembered remote selection";
    gtk_editable_set_text(GTK_EDITABLE(polish_page()->polish_key_row), "clear-on-local-switch");
    adw_combo_row_set_selected(polish_page()->polish_location_row, 0);
    okay = okay && polish_selected_model() == 4 &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(polish_page()->polish_key_row)), "") == 0;
    if (!okay && failure_stage == NULL) failure_stage = "local return clears remote key";
    adw_combo_row_set_selected(polish_page()->polish_model_row, 0);
    okay = okay && polish_selected_model() == 2 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row));
    if (!okay && failure_stage == NULL) failure_stage = "built-in rules disable prompt and context";
    adw_combo_row_set_selected(polish_page()->polish_model_row, 1);
    okay = okay && polish_selected_model() == 3 &&
        gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row)) &&
        !adw_switch_row_get_active(polish_page()->polish_directives_row) && adw_switch_row_get_active(polish_page()->polish_tags_row);
    if (!okay && failure_stage == NULL) failure_stage = "downloaded local controls and context";
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == 3 &&
        g_strcmp0(observed.text, "One%20stop%20after%20each%20word.%0AExact%09second%20line.\t\t0\t1") == 0;
    if (!okay && failure_stage == NULL) failure_stage = "downloaded local callback";
    fixture.remembered_remote_index = -1;
    polish_apply(&fixture);
    adw_combo_row_set_selected(polish_page()->polish_location_row, 1);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 && polish_selected_model() == -1 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_key_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(polish_page()->polish_tags_row));
    if (!okay && failure_stage == NULL) failure_stage = "unavailable remote stays unselected";
    adw_combo_row_set_selected(polish_page()->polish_location_row, 0);
    okay = okay && polish_selected_model() == 4;
    if (!okay && failure_stage == NULL) failure_stage = "unavailable remote retains local selection";
    okay = okay && jsti_window_set_cleanup_sources(10001) == -1;
    if (!okay && failure_stage == NULL) failure_stage = "source count boundary";
    polish_apply(&saved);
    polish_page()->polish_remote_count = saved_remote;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(polish_page()->polish_location_row, saved_location);
    polish_select_location(saved.selected, FALSE);
    polish_page()->polish_local_selected = saved_local;
    ui.suppress = FALSE;
    ui.callback = saved_callback;
    g_clear_pointer(&observed.text, g_free);
    g_free(saved.local_notice); g_free(saved.prompt); g_free(actual_prompt);
    g_ptr_array_unref(saved.models); g_ptr_array_unref(fixture.models);
    if (okay) return 0;
    gchar *detail = g_strdup_printf("local cleanup source/index/prompt/privacy controls failed: %s", failure_stage);
    int32_t result = fail(error, capacity, detail);
    g_free(detail);
    return result;
}

gboolean cleanup_preview_self_test(void) {
    gchar *original = displayed_transcript();
    gchar *status = g_strdup(gtk_label_get_text(dashboard_page()->status));
    gchar *presented = g_strdup(history_page()->presented_id);
    gint32 state = ui.state, page = ui.page;
    gboolean visible = cleanup_preview.visible;
    jsti_window_event_fn callback = ui.callback;
    ui.callback = NULL;
    ui.state = JSTI_STATE_WORKING;
    show_page(JSTI_PAGE_DASHBOARD);
    guint64 first = jsti_window_begin_cleanup_preview();
    gboolean okay = jsti_window_cleanup_preview("first", first) == 0 &&
        jsti_window_cleanup_preview("latest", first) == 0;
    cleanup_preview_apply(NULL);
    gchar *actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "latest") == 0 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dashboard_page()->copy)) && !gtk_widget_get_sensitive(GTK_WIDGET(dashboard_page()->dashboard_copy));
    g_free(actual);
    show_page(JSTI_PAGE_GENERAL);
    show_page(JSTI_PAGE_DASHBOARD);
    okay = okay && jsti_window_cleanup_preview("away/back stale", first) == 1;
    guint64 second = jsti_window_begin_cleanup_preview();
    okay = okay && second != first && jsti_window_cleanup_preview("replacement", second) == 0;
    jsti_window_end_cleanup_preview(first);
    cleanup_preview_apply(NULL);
    actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "replacement") == 0;
    g_free(actual);
    gchar *maximum = g_strnfill(65536, 'x');
    okay = okay && jsti_window_cleanup_preview(maximum, second) == 0;
    g_free(maximum);
    jsti_window_end_cleanup_preview(second);
    cleanup_preview_apply(NULL);
    actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "replacement") == 0;
    g_free(actual);
    gchar *oversized = g_strnfill(65537, 'x');
    okay = okay && jsti_window_cleanup_preview("retired", second) == 1 &&
        jsti_window_cleanup_preview(oversized, second) == -1 &&
        jsti_window_cleanup_preview("\xff", second) == -1;
    g_free(oversized);
    set_transcript(original);
    gtk_label_set_text(dashboard_page()->status, status);
    g_free(history_page()->presented_id);
    history_page()->presented_id = presented;
    ui.state = state;
    cleanup_preview.visible = visible;
    show_page(page);
    ui.callback = callback;
    refresh_actions();
    g_free(original);
    g_free(status);
    return okay;
}

gboolean migration_restore_self_test(void) {
    if (storage_page()->restore_dialog != NULL) return FALSE;
    jsti_window_event_fn saved = ui.callback;
    gint32 state = ui.state;
    ui.callback = observe_event;
    ui.state = JSTI_STATE_IDLE;
    gchar token[] = "00000000-0000-0000-0000-000000000098";
    gchar text[] = "Synthetic restore counts. Nothing has been written yet.";
    MigrationRestoreConfirmation request = {.token = token, .text = text, .offers_replace = FALSE};
    gboolean okay = jsti_window_confirm_migration_restore(NULL, text, 0) == -1 &&
        jsti_window_confirm_migration_restore("bad-token", text, 0) == -1 &&
        jsti_window_confirm_migration_restore(token, NULL, 0) == -1 &&
        jsti_window_confirm_migration_restore(token, "", 0) == -1 &&
        jsti_window_confirm_migration_restore(token, "\xff", 0) == -1 &&
        jsti_window_confirm_migration_restore(token, text, 2) == -1;
    observed.event = -500;
    okay = okay && migration_restore_stage(&request) && storage_page()->restore_dialog != NULL;
    if (storage_page()->restore_dialog != NULL) {
        AdwMessageDialog *dialog = ADW_MESSAGE_DIALOG(storage_page()->restore_dialog);
        token[0] = 'x';
        text[0] = 'x';
        okay = okay &&
            g_strcmp0(adw_message_dialog_get_default_response(dialog), "cancel") == 0 &&
            g_strcmp0(adw_message_dialog_get_close_response(dialog), "cancel") == 0 &&
            !adw_message_dialog_has_response(dialog, "replace") &&
            g_str_has_prefix(adw_message_dialog_get_body(dialog), "Synthetic restore counts.") &&
            !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_restore)) && observed.event == -500;
        migration_restore_response(dialog, "merge", NULL);
        okay = okay && storage_page()->restore_dialog == NULL && observed.event == JSTI_EVENT_MIGRATION_RESTORE_RESPONSE &&
            observed.index == 1 && g_strcmp0(observed.text, "00000000-0000-0000-0000-000000000098") == 0;
    }
    token[0] = '0';
    observed.event = -500;
    okay = migration_restore_stage(&request) && okay;
    if (storage_page()->restore_dialog != NULL) {
        GtkWidget *current = storage_page()->restore_dialog;
        okay = !migration_restore_stage(&request) && storage_page()->restore_dialog == current && observed.event == -500 && okay;
        migration_restore_response(ADW_MESSAGE_DIALOG(storage_page()->restore_dialog), "replace", NULL);
        okay = okay && storage_page()->restore_dialog == NULL && observed.index == 0 &&
            observed.event == JSTI_EVENT_MIGRATION_RESTORE_RESPONSE;
    }
    request.offers_replace = TRUE;
    observed.event = -500;
    okay = migration_restore_stage(&request) && okay;
    if (storage_page()->restore_dialog != NULL) {
        GtkWidget *old = g_object_ref(storage_page()->restore_dialog);
        migration_restore_response(ADW_MESSAGE_DIALOG(old), "replace", NULL);
        okay = okay && storage_page()->restore_dialog != NULL && storage_page()->restore_dialog != old && observed.event == -500;
        migration_restore_response(ADW_MESSAGE_DIALOG(old), "merge", NULL);
        okay = okay && observed.event == -500;
        g_object_unref(old);
        if (storage_page()->restore_dialog != NULL) {
            AdwMessageDialog *dialog = ADW_MESSAGE_DIALOG(storage_page()->restore_dialog);
            okay = okay && !adw_message_dialog_has_response(dialog, "merge") &&
                g_strcmp0(adw_message_dialog_get_default_response(dialog), "cancel") == 0 &&
                g_strcmp0(adw_message_dialog_get_close_response(dialog), "cancel") == 0 &&
                strstr(adw_message_dialog_get_body(dialog), "History is still only merged") != NULL;
            migration_restore_response(dialog, "replace", NULL);
            okay = okay && storage_page()->restore_dialog == NULL && observed.index == 2 &&
                observed.event == JSTI_EVENT_MIGRATION_RESTORE_RESPONSE;
        }
    }
    for (gint scenario = 0; scenario < 3; ++scenario) {
        observed.event = -500;
        okay = migration_restore_stage(&request) && okay;
        if (storage_page()->restore_dialog == NULL) { okay = FALSE; continue; }
        ui.state = scenario == 1 ? JSTI_STATE_WORKING : JSTI_STATE_IDLE;
        refresh_actions();
        if (scenario == 2) {
            migration_restore_response(ADW_MESSAGE_DIALOG(storage_page()->restore_dialog), "replace", NULL);
            okay = okay && storage_page()->restore_dialog != NULL && observed.event == -500;
        }
        if (storage_page()->restore_dialog == NULL) { okay = FALSE; continue; }
        if (scenario == 1)
            okay = okay && !adw_message_dialog_get_response_enabled(ADW_MESSAGE_DIALOG(storage_page()->restore_dialog), "merge");
        migration_restore_response(ADW_MESSAGE_DIALOG(storage_page()->restore_dialog), scenario == 1 ? "merge" : "cancel", NULL);
        okay = okay && observed.event == JSTI_EVENT_MIGRATION_RESTORE_RESPONSE && observed.index == 0;
    }
    ui.state = JSTI_STATE_WORKING;
    okay = migration_restore_stage(&request) && okay;
    if (storage_page()->restore_dialog != NULL) {
        AdwMessageDialog *dialog = ADW_MESSAGE_DIALOG(storage_page()->restore_dialog);
        okay = okay && !adw_message_dialog_get_response_enabled(dialog, "merge");
        ui.state = JSTI_STATE_IDLE;
        refresh_actions();
        okay = okay && adw_message_dialog_get_response_enabled(dialog, "merge");
        migration_restore_response(dialog, "cancel", NULL);
    }
    ui.state = JSTI_STATE_IDLE;
    okay = migration_restore_stage(&request) && okay;
    observed.event = -500;
    retire_migration_restore();
    okay = okay && storage_page()->restore_dialog == NULL && observed.event == -500;
    ui.closing = TRUE;
    okay = !migration_restore_stage(&request) && okay;
    okay = okay && storage_page()->restore_dialog == NULL && observed.index == 0;
    ui.closing = FALSE;
    ui.state = state;
    ui.callback = saved;
    g_clear_pointer(&observed.text, g_free);
    refresh_actions();
    return okay;
}
