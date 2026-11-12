/* The Output page: clipboard restoration and the app-switch destination policy. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowDashboardState.h"
#include "../CLinuxSupport/LinuxWindowOutputState.h"

static void text_output_capture(int32_t event, const char *text, int32_t index, void *context) {
    gchar *expected = output_page()->app_switch_configured
        ? g_strdup_printf("restore\t%u", adw_combo_row_get_selected(output_page()->app_switch_row)) : g_strdup("restore");
    if (event == JSTI_EVENT_TEXT_OUTPUT && index == 1 && g_strcmp0(text, expected) == 0)
        ++*(guint *)context;
    g_free(expected);
}

static gboolean app_switch_output_self_test(void) {
    GListModel *model = adw_combo_row_get_model(output_page()->app_switch_row);
    if (model != NULL) g_object_ref(model);
    guint selection = adw_combo_row_get_selected(output_page()->app_switch_row);
    gboolean configured = output_page()->app_switch_configured;
    gchar *title = g_strdup(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(output_page()->app_switch_row)));
    gchar *help = g_strdup(gtk_label_get_text(output_page()->app_switch_help));
    TextOutput original = {
        .method = (gint32)adw_combo_row_get_selected(output_page()->output_row),
        .restore = adw_switch_row_get_active(output_page()->restore_row), .can_restore = output_page()->can_restore_clipboard
    };
    TextOutput policy = {
        .method = 0, .restore = TRUE, .can_restore = FALSE,
        .policy_title = (gchar *)"Fixture destination", .policy_labels = (gchar *)"Legacy\nOriginal\nCurrent\nCopy",
        .policy_help = (gchar *)"Wayland copies explicit intent only.", .policy_selection = 2
    };
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    text_output_apply(&policy);
    gboolean valid = observed.event == 0 && adw_combo_row_get_selected(output_page()->app_switch_row) == 2 &&
        g_list_model_get_n_items(adw_combo_row_get_model(output_page()->app_switch_row)) == 4 &&
        gtk_label_get_wrap(output_page()->app_switch_help) &&
        g_strcmp0(gtk_label_get_text(output_page()->app_switch_help), policy.policy_help) == 0;
    adw_combo_row_set_selected(output_page()->app_switch_row, 3);
    valid = valid && observed.event == JSTI_EVENT_TEXT_OUTPUT && observed.index == 0 &&
        g_strcmp0(observed.text, "restore\t3") == 0;
    policy.method = 1;
    policy.policy_selection = 3;
    observed.event = 0;
    text_output_apply(&policy);
    valid = valid && observed.event == 0 && !gtk_widget_get_sensitive(GTK_WIDGET(output_page()->app_switch_row)) &&
        adw_combo_row_get_selected(output_page()->app_switch_row) == 3;
    ui.suppress = TRUE;
    adw_combo_row_set_model(output_page()->app_switch_row, model);
    if (model != NULL) g_object_unref(model);
    adw_combo_row_set_selected(output_page()->app_switch_row, selection);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->app_switch_row), title);
    gtk_label_set_text(output_page()->app_switch_help, help);
    output_page()->app_switch_configured = configured;
    ui.suppress = FALSE;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    g_free(title);
    g_free(help);
    text_output_apply(&original);
    return valid;
}

gboolean text_output_self_test(void) {
    guint original_policy = adw_combo_row_get_selected(output_page()->app_switch_row);
    if (output_page()->app_switch_configured) {
        ui.suppress = TRUE;
        adw_combo_row_set_selected(output_page()->app_switch_row, 0);
        ui.suppress = FALSE;
    }
    TextOutput original = {
        .method = (gint32)adw_combo_row_get_selected(output_page()->output_row),
        .restore = adw_switch_row_get_active(output_page()->restore_row),
        .can_restore = output_page()->can_restore_clipboard,
        .hint = g_strdup(adw_action_row_get_subtitle(output_page()->shortcut_row))
    };
    TextOutput unsupported = { .method = 0, .restore = TRUE, .can_restore = FALSE };
    text_output_apply(&unsupported);
    gboolean valid = !gtk_widget_get_visible(GTK_WIDGET(output_page()->restore_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(output_page()->restore_row)) && adw_switch_row_get_active(output_page()->restore_row) &&
        gtk_widget_get_visible(GTK_WIDGET(output_page()->output_group)) &&
        strstr(adw_preferences_group_get_description(output_page()->output_group), "Wayland") != NULL &&
        strstr(gtk_label_get_text(dashboard_page()->setup_output), "restored") == NULL;
    guint calls = 0;
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    ui.callback = text_output_capture;
    ui.context = &calls;
    adw_combo_row_set_selected(output_page()->output_row, 1);
    valid = valid && calls == 1 && adw_switch_row_get_active(output_page()->restore_row);
    ui.callback = callback;
    ui.context = context;
    TextOutput supported = { .method = 0, .restore = TRUE, .can_restore = TRUE };
    text_output_apply(&supported);
    valid = valid && gtk_widget_get_visible(GTK_WIDGET(output_page()->restore_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(output_page()->restore_row)) &&
        strstr(gtk_label_get_text(dashboard_page()->setup_output), "restored") != NULL;
    supported.method = 1;
    text_output_apply(&supported);
    valid = valid && !gtk_widget_get_sensitive(GTK_WIDGET(output_page()->restore_row)) &&
        adw_switch_row_get_active(output_page()->restore_row) && strstr(gtk_label_get_text(dashboard_page()->setup_output), "restored") == NULL;
    text_output_apply(&original);
    gboolean policy_valid = app_switch_output_self_test();
    if (output_page()->app_switch_configured) {
        ui.suppress = TRUE;
        adw_combo_row_set_selected(output_page()->app_switch_row, original_policy);
        ui.suppress = FALSE;
        text_output_apply(&original);
    }
    g_free(original.hint);
    return valid && policy_valid;
}
