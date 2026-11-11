/* Self-tests for the functions other window units use instead of a page's state. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowDashboardState.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"
#include "../CLinuxSupport/LinuxWindowModelsState.h"
#include "../CLinuxSupport/LinuxWindowOutputState.h"
#include "../CLinuxSupport/LinuxWindowReadAloudState.h"
#include "../CLinuxSupport/LinuxWindowStorageState.h"
#include "../CLinuxSupport/LinuxWindowVoiceState.h"

static gboolean sensitive(gpointer widget) { return gtk_widget_get_sensitive(GTK_WIDGET(widget)); }
static gboolean visible(gpointer widget) { return gtk_widget_get_visible(GTK_WIDGET(widget)); }

static gboolean names_self_test(void) {
    gboolean okay = page_name(-1) == NULL && page_name(JSTI_PAGE_COUNT) == NULL;
    for (gint32 page = 0; page < JSTI_PAGE_COUNT; ++page)
        okay = okay && page_name(page) != NULL && gtk_stack_get_child_by_name(ui.pages, page_name(page)) != NULL;
    okay = okay && g_strcmp0(models_model_name(), combo_row_text(models_page()->model_row)) == 0 &&
        g_strcmp0(models_microphone_name(), combo_row_text(models_page()->microphone_row)) == 0;
    TextOutput current = output_current();
    okay = okay && current.method == (gint32)adw_combo_row_get_selected(output_page()->output_row) &&
        current.restore == adw_switch_row_get_active(output_page()->restore_row) &&
        current.can_restore == output_page()->can_restore_clipboard &&
        g_strcmp0(output_shortcut_hint(), adw_action_row_get_subtitle(output_page()->shortcut_row)) == 0;
    gchar *summary = output_summary();
    const char *method = combo_row_text(output_page()->output_row);
    okay = okay && g_str_has_prefix(summary, method != NULL ? method : "");
    g_free(summary);
    return okay;
}

static gboolean actions_self_test(void) {
    dashboard_refresh_actions(JSTI_STATE_WORKING, FALSE);
    gboolean okay = !sensitive(dashboard_page()->record) && !dashboard_can_record() &&
        visible(dashboard_page()->cancel) && !sensitive(dashboard_page()->dashboard_copy) &&
        !visible(dashboard_page()->live_preview);
    dashboard_refresh_actions(JSTI_STATE_RECORDING, TRUE);
    okay = okay && sensitive(dashboard_page()->record) && !visible(dashboard_page()->cancel) &&
        visible(dashboard_page()->live_preview) && sensitive(dashboard_page()->dashboard_copy) &&
        g_strcmp0(gtk_button_get_label(dashboard_page()->record), "Stop Recording") == 0;
    dashboard_set_copy_enabled(FALSE);
    history_set_copy_enabled(FALSE);
    okay = okay && !sensitive(dashboard_page()->dashboard_copy) && !sensitive(history_page()->copy);
    history_set_copy_enabled(TRUE);
    okay = okay && sensitive(history_page()->copy);
    refresh_history_actions(TRUE, TRUE, FALSE, TRUE);
    okay = okay && !sensitive(history_page()->copy) && sensitive(history_page()->read_aloud);
    voice_page_refresh_actions(TRUE, FALSE, TRUE);
    okay = okay && !sensitive(voice_page()->voice_read) && sensitive(voice_page()->voice_sources);
    voice_page_refresh_actions(FALSE, TRUE, FALSE);
    okay = okay && sensitive(voice_page()->voice_read) && !sensitive(voice_page()->voice_sources);
    read_aloud_refresh_actions(FALSE);
    okay = okay && !sensitive(read_aloud_state()->voice_row) && !sensitive(read_aloud_state()->favorite_row) &&
        !sensitive(read_aloud_state()->favorite_button) &&
        read_aloud_has_voices() == (g_list_model_get_n_items(G_LIST_MODEL(read_aloud_state()->voices)) > 0);
    models_refresh_actions(FALSE);
    okay = okay && !sensitive(models_page()->model_row) && !sensitive(models_page()->microphone_row);
    storage_refresh_actions(FALSE);
    okay = okay && !sensitive(storage_page()->recordings_choose) && !sensitive(storage_page()->backup_export) &&
        !sensitive(storage_page()->backup_restore);
    storage_refresh_actions(TRUE);
    okay = okay && sensitive(storage_page()->recordings_choose) == (storage_page()->location_chooser == NULL) &&
        sensitive(storage_page()->backup_export) ==
            (storage_page()->backup_chooser == NULL && storage_page()->restore_dialog == NULL);
    /* The Processed/Original choice; nothing is presented, so it emits nothing. */
    if (!history_selection_presented()) {
        guint variant = history_selected_variant();
        history_show_variant(variant == 0 ? 1 : 0);
        okay = okay && history_selected_variant() == (variant == 0 ? 1u : 0u);
        history_show_variant(-1);
        okay = okay && history_selected_variant() == (variant == 0 ? 1u : 0u);
        history_show_variant((gint32)variant);
    }
    return okay;
}

/* Other units reach a page only through its LinuxWindow*Page.h functions;
 * they must agree with the state each page keeps to itself. */
gboolean page_functions_self_test(void) {
    gint32 state = ui.state;
    gboolean okay = names_self_test() && actions_self_test();
    ui.state = state;
    refresh_actions();
    return okay;
}
