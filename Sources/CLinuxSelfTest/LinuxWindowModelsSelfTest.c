/* The Models page: the picker's dependent rows and its four Source/Mode choices. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowModelsState.h"

int32_t model_picker_self_test(char *error, size_t capacity) {
    if (g_list_model_get_n_items(G_LIST_MODEL(models_page()->model_names)) == 0) {
        return fail(error, capacity, "no models are offered");
    }
    /* The Azure resource row follows the picker: shown for Azure models only. */
    guint original = adw_combo_row_get_selected(models_page()->model_row);
    guint azure = GTK_INVALID_LIST_POSITION, other = GTK_INVALID_LIST_POSITION;
    for (guint index = 0; index < models_page()->model_slots->len; index++) {
        gboolean is_azure = g_str_has_prefix(g_array_index(models_page()->model_slots, Slot, index).id, "azure/");
        if (is_azure && azure == GTK_INVALID_LIST_POSITION) azure = index;
        if (!is_azure && other == GTK_INVALID_LIST_POSITION) other = index;
    }
    if (azure == GTK_INVALID_LIST_POSITION || other == GTK_INVALID_LIST_POSITION) {
        return fail(error, capacity, "the picker offers no Azure model, or only Azure models");
    }
    ui.suppress = TRUE;
    adw_combo_row_set_selected(models_page()->model_row, azure);
    gboolean shown_for_azure = gtk_widget_get_visible(GTK_WIDGET(models_page()->azure_row));
    adw_combo_row_set_selected(models_page()->model_row, other);
    gboolean shown_for_other = gtk_widget_get_visible(GTK_WIDGET(models_page()->azure_row));
    adw_combo_row_set_selected(models_page()->model_row, original);
    ui.suppress = FALSE;
    if (!shown_for_azure || shown_for_other) {
        return fail(error, capacity, "the Azure resource row did not follow the selected model");
    }
    for (guint index = 0; index < models_page()->model_slots->len; index++) {
        if (!g_str_has_prefix(g_array_index(models_page()->model_slots, Slot, index).id, "local/")) continue;
        ui.suppress = TRUE;
        adw_combo_row_set_selected(models_page()->model_row, index);
        gboolean key_for_local = gtk_widget_get_visible(GTK_WIDGET(models_page()->key_row));
        adw_combo_row_set_selected(models_page()->model_row, original);
        ui.suppress = FALSE;
        if (key_for_local) return fail(error, capacity, "an on-device model asks for an API key");
        break;
    }
    return 0;
}

/* Real model rows must remain distinct across all four source/mode pairs. */
gboolean model_modes_self_test(void) {
    if (models_page()->model_catalog == NULL) return FALSE;
    gint32 saved[4], preferred[] = { -1, -1, -1, -1 }, first[] = { -1, -1, -1, -1 };
    guint counts[4] = {0};
    memcpy(saved, models_page()->preferred_model_slots, sizeof(saved));
    gint32 selection = selected_model_slot();
    gboolean local = jsti_model_filters_local(), live = jsti_model_filters_live();
    gboolean remote_live = jsti_model_filters_preferred_live(FALSE);
    gboolean local_live = jsti_model_filters_preferred_live(TRUE), suppress = ui.suppress;
    jsti_window_event_fn callback = ui.callback;
    for (guint i = 0; i < models_page()->model_catalog->slots->len; ++i) {
        Slot slot = g_array_index(models_page()->model_catalog->slots, Slot, i);
        guint mode = model_mode(g_str_has_prefix(slot.id, "local/"), slot.live);
        if (first[mode] < 0) first[mode] = slot.global;
        preferred[mode] = slot.global;
        ++counts[mode];
    }
    gboolean okay = counts[0] > 0 && counts[2] > 1 && counts[3] > 1 &&
        jsti_window_set_preferred_models(-2, -1, -1, -1) == -1;
    model_preferences_apply(preferred);
    ui.callback = observe_event;
    const guint modes[] = { 0, 2, 3, 1, 3, 2 };
    for (guint i = 0; okay && i < G_N_ELEMENTS(modes); ++i) {
        guint mode = modes[i];
        if (counts[mode] == 0) continue;
        jsti_model_filters_select(mode >= 2, (mode & 1) != 0);
        observed.event = 0;
        on_model_filter(mode >= 2, (mode & 1) != 0);
        okay = selected_model_slot() == preferred[mode] && models_page()->model_slots->len == counts[mode] &&
            observed.event == JSTI_EVENT_SELECT_MODEL && observed.index == preferred[mode] &&
            gtk_widget_get_visible(GTK_WIDGET(models_page()->key_row)) == (mode < 2);
    }
    if (okay) {
        jsti_model_filters_select(FALSE, FALSE);
        on_model_filter(FALSE, FALSE);
        gint32 selected = selected_model_slot(), event = observed.event = -500;
        const gint32 imported[] = { first[2], first[3] };
        local_model_preferences_apply((gpointer)imported);
        okay = selected_model_slot() == selected && observed.event == event &&
            models_page()->preferred_model_slots[0] == preferred[0] && models_page()->preferred_model_slots[2] == first[2] &&
            models_page()->preferred_model_slots[3] == first[3];
        jsti_model_filters_select(TRUE, TRUE);
        on_model_filter(TRUE, TRUE);
        okay = okay && observed.event == JSTI_EVENT_SELECT_MODEL && observed.index == first[3];
        observed.event = -500;
        const gint32 replacement[] = { preferred[2], preferred[3] };
        local_model_preferences_apply((gpointer)replacement);
        okay = okay && selected_model_slot() == first[3] && observed.event == -500 &&
            models_page()->preferred_model_slots[3] == first[3] &&
            models_page()->preferred_model_slots[2] == preferred[2] &&
            jsti_window_set_local_model_preferences(-2, -1) == -1;
    }
    jsti_model_filters_select(FALSE, remote_live);
    jsti_model_filters_select(TRUE, local_live);
    jsti_model_filters_select(local, live);
    model_preferences_apply(saved);
    filter_models(selection);
    ui.suppress = suppress;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    return okay;
}
