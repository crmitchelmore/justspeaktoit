/*
 * The window self-test (jsti_window_self_test) and its UI checks. SpeakLinux links
 * this target, so CI and the desktop checks still run it inside the shipped binary.
 */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowAboutPage.h"
#include "../CLinuxSupport/LinuxWindowDashboardPage.h"
#include "../CLinuxSupport/LinuxWindowGeneralPage.h"
#include "../CLinuxSupport/LinuxWindowHistoryPage.h"
#include "../CLinuxSupport/LinuxWindowModelsPage.h"
#include "../CLinuxSupport/LinuxWindowOutputPage.h"
#include "../CLinuxSupport/LinuxWindowPolishPage.h"
#include "../CLinuxSupport/LinuxWindowStoragePage.h"

/* ---------------------------------------------------------- self-test */

ObservedEvent observed;

void observe_event(gint32 event, const char *text, gint32 index, void *context) {
    (void)context;
    observed.event = event;
    g_free(observed.text);
    observed.text = g_strdup(text);
    observed.index = index;
}

static void observe_cancel(gint32 event, const char *text, gint32 index, void *context) {
    (void)index;
    gint32 *calls = context;
    ++calls[0];
    calls[1] = event;
    gchar expected[32];
    guint64 token = escape_token(&escape_policy);
    g_snprintf(expected, sizeof(expected), "%" G_GUINT64_FORMAT, token);
    calls[2] = token != 0 && g_strcmp0(text, expected) == 0;
    calls[3] = text != NULL && *text == '\0';
}

static gboolean escape_policy_self_test(void) {
    EscapePolicy policy = { .enabled = TRUE };
    gboolean okay = escape_token(&policy) == 0;
    escape_publish(&policy, JSTI_STATE_RECORDING, -1, FALSE);
    guint64 first = escape_token(&policy);
    escape_publish(&policy, JSTI_STATE_WORKING, -1, FALSE);
    okay = first != 0 && escape_token(&policy) == first && okay;
    escape_publish(&policy, -1, 0, FALSE);
    okay = escape_token(&policy) == 0 && okay;
    escape_publish(&policy, JSTI_STATE_RECORDING, -1, FALSE);
    okay = escape_token(&policy) == 0 && okay;
    escape_publish(&policy, -1, 1, FALSE);
    guint64 second = escape_token(&policy);
    okay = second != 0 && second != first && okay;
    escape_publish(&policy, JSTI_STATE_IDLE, -1, FALSE);
    escape_publish(&policy, JSTI_STATE_RECORDING, -1, FALSE);
    okay = escape_token(&policy) != 0 && escape_token(&policy) != second && okay;
    escape_publish(&policy, -1, -1, TRUE);
    escape_publish(&policy, JSTI_STATE_RECORDING, 1, FALSE);
    okay = escape_token(&policy) == 0 && okay;
    g_mutex_clear(&policy.mutex);
    return okay;
}

static gboolean cancel_key_self_test(void) {
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint32 state = ui.state, calls[4] = {0};
    g_mutex_lock(&escape_policy.mutex);
    gboolean saved_policy = escape_policy.enabled, saved_recording = escape_policy.recording;
    g_mutex_unlock(&escape_policy.mutex);
    gboolean held = ui.cancel_key_held, suppress = ui.suppress, closing = ui.closing;
    gboolean sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.callback = observe_cancel; ui.context = calls;
    ui.cancel_key_held = FALSE; ui.suppress = FALSE; ui.closing = FALSE; ui.state = JSTI_STATE_IDLE;
    escape_publish(&escape_policy, JSTI_STATE_IDLE, 1, FALSE);
    gboolean okay = escape_policy_self_test() && !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE);
    ui.state = JSTI_STATE_RECORDING;
    escape_publish(&escape_policy, ui.state, -1, FALSE);
    const GdkModifierType modified[] = {
        GDK_CONTROL_MASK, GDK_SHIFT_MASK, GDK_ALT_MASK, GDK_SUPER_MASK, GDK_HYPER_MASK, GDK_META_MASK
    };
    for (guint i = 0; i < G_N_ELEMENTS(modified); ++i)
        okay = !cancel_key(GDK_KEY_Escape, modified[i], NULL, TRUE) && okay;
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, FALSE) && !cancel_key(GDK_KEY_a, 0, NULL, TRUE) && okay;
    GtkWidget *popover = gtk_popover_new();
    g_object_ref_sink(popover);
    okay = !cancel_key(GDK_KEY_Escape, 0, popover, TRUE) && okay;
    g_object_unref(popover);
    GtkWidget *dialog = adw_message_dialog_new(ui.window, "Cancel fixture", NULL);
    g_object_ref_sink(dialog);
    okay = !cancel_key(GDK_KEY_Escape, 0, dialog, TRUE) && calls[0] == 0 && okay;
    gtk_window_destroy(GTK_WINDOW(dialog));
    g_object_unref(dialog);
#if ADW_CHECK_VERSION(1, 5, 0)
    AdwDialog *embedded = adw_dialog_new();
    g_object_ref_sink(embedded);
    okay = !cancel_key(GDK_KEY_Escape, 0, GTK_WIDGET(embedded), TRUE) && calls[0] == 0 && okay;
    g_object_unref(embedded);
#endif
    okay = cancel_key(GDK_KEY_Escape, GDK_LOCK_MASK, GTK_WIDGET(dashboard_page()->transcript), TRUE) &&
        calls[0] == 1 && calls[1] == JSTI_EVENT_CANCEL && calls[2] && okay;
    ui.state = JSTI_STATE_IDLE;
    escape_publish(&escape_policy, ui.state, -1, FALSE);
    okay = cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 1 && okay;
    action_key_released(NULL, GDK_KEY_Escape, 9, 0, NULL);
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && !ui.cancel_key_held && okay;
    ui.state = JSTI_STATE_WORKING;
    escape_publish(&escape_policy, ui.state, -1, FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && okay;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.closing = TRUE;
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && okay;
    ui.closing = FALSE;
    okay = cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 2 && okay;
    guint64 old_token = escape_token(&escape_policy);
    okay = jsti_window_set_escape_cancellation(-1) == -1 &&
        jsti_window_set_escape_cancellation(2) == -1 && jsti_window_escape_is_current(old_token) && okay;
    okay = jsti_window_set_escape_cancellation(0) == 0 &&
        !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 2 &&
        !jsti_window_escape_is_current(old_token) && okay;
    on_cancel(NULL, NULL);
    okay = calls[0] == 3 && calls[1] == JSTI_EVENT_CANCEL && calls[3] && okay;
    okay = jsti_window_set_escape_cancellation(1) == 0 &&
        !jsti_window_escape_is_current(old_token) &&
        cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 3 && okay;
    action_key_released(NULL, GDK_KEY_Escape, 9, 0, NULL);
    okay = cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 4 && calls[2] && okay;
    escape_publish(&escape_policy, saved_recording ? JSTI_STATE_RECORDING : JSTI_STATE_IDLE, saved_policy, FALSE);
    ui.callback = callback; ui.context = context; ui.state = state;
    ui.cancel_key_held = held; ui.suppress = suppress; ui.closing = closing;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    return okay;
}

/* Real model rows must remain distinct across all four source/mode pairs. */
static gboolean model_modes_self_test(void) {
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

/* Read aloud follows the presented record: offered while its text is shown
 * and the window is idle, it reports that record, and the voice picker
 * reports the chosen position. */
static int32_t read_aloud_self_test(const char *record, char *error, size_t capacity) {
    if (g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) < 2) {
        return fail(error, capacity, "Read aloud offers fewer than two voices");
    }
    if (!gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.button))) {
        return fail(error, capacity, "Read aloud was unavailable for the presented record");
    }
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    JSTIVoicePickerCallback picker_callback = read_aloud.picker_callback;
    read_aloud.picker_callback = NULL;
    observed.event = 0;
    g_signal_emit_by_name(read_aloud.button, "clicked");
    gboolean reported = observed.event == JSTI_EVENT_READ_ALOUD && g_strcmp0(observed.text, record) == 0;
    guint saved = adw_combo_row_get_selected(read_aloud.voice_row);
    guint other = saved == 0 ? 1 : 0;
    observed.event = 0;
    adw_combo_row_set_selected(read_aloud.voice_row, other);
    gboolean chosen = observed.event == JSTI_EVENT_VOICE_OUTPUT && observed.index == (gint32)other;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(read_aloud.voice_row, saved);
    ui.suppress = FALSE;
    ui.callback = callback;
    read_aloud.picker_callback = picker_callback;
    g_clear_pointer(&observed.text, g_free);
    if (!reported) return fail(error, capacity, "Read aloud did not report the presented record");
    if (!chosen) return fail(error, capacity, "the voice picker did not report the chosen voice");
    Update working = { .state = JSTI_STATE_WORKING };
    update_apply(&working);
    gboolean offered = gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.button));
    Update idle = { .state = JSTI_STATE_IDLE };
    update_apply(&idle);
    if (offered) return fail(error, capacity, "Read aloud stayed available while transcribing");
    return 0;
}

static struct { gint action; guint calls; gchar *identifier; } favorite_observed;
static void observe_favorite(gint32 action, const char *identifier, void *context) {
    (void)context;
    favorite_observed.action = action;
    ++favorite_observed.calls;
    g_free(favorite_observed.identifier);
    favorite_observed.identifier = g_strdup(identifier);
}

static int32_t voice_favorites_self_test(char *error, size_t capacity) {
    Voices original = {0};
    original.names = g_ptr_array_new_with_free_func(g_free);
    for (guint index = 0; index < g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)); ++index) {
        g_ptr_array_add(original.names, g_strdup(gtk_string_list_get_string(read_aloud.voices, index)));
    }
    original.selected = (gint32)adw_combo_row_get_selected(read_aloud.voice_row);
    original.identifiers = read_aloud.identifiers != NULL ? g_ptr_array_ref(read_aloud.identifiers) : NULL;
    original.favorite_ranks = read_aloud.favorite_ranks != NULL ? g_array_ref(read_aloud.favorite_ranks) : NULL;
    original.callback = read_aloud.picker_callback;
    original.context = read_aloud.picker_context;
    Voices fixture = {0};
    fixture.names = g_ptr_array_new_with_free_func(g_free);
    fixture.identifiers = g_ptr_array_new_with_free_func(g_free);
    fixture.favorite_ranks = g_array_new(FALSE, FALSE, sizeof(gint32));
    fixture.selected = 0;
    fixture.callback = observe_favorite;
    const gchar *ids[] = {"synthetic/alpha", "synthetic/beta", ""};
    const gchar *names[] = {"Alpha voice", "Beta voice", "Unavailable stored voice"};
    for (guint index = 0; index < 3; ++index) {
        gint32 rank = index == 1 ? 0 : -1;
        g_ptr_array_add(fixture.names, g_strdup(names[index]));
        g_ptr_array_add(fixture.identifiers, g_strdup(ids[index]));
        g_array_append_val(fixture.favorite_ranks, rank);
    }
    favorite_observed.calls = 0;
    voices_apply(&fixture);
    gboolean okay = favorite_observed.calls == 0 && read_aloud.favorite_indices->len == 1 &&
        g_array_index(read_aloud.favorite_indices, guint, 0) == 1 &&
        adw_combo_row_get_selected(read_aloud.favorite_row) == read_aloud.favorite_indices->len &&
        g_list_model_get_n_items(G_LIST_MODEL(read_aloud.favorite_names)) == 2;
    adw_combo_row_set_selected(read_aloud.favorite_row, 0);
    okay = okay && favorite_observed.calls == 1 && favorite_observed.action == 0 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    adw_combo_row_set_selected(read_aloud.favorite_row, read_aloud.favorite_indices->len);
    okay = okay && favorite_observed.calls == 1;
    /* A host acknowledgement, not an optimistic UI write, updates button state. */
    fixture.selected = 1;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud.favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 2 && favorite_observed.action == 2 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    fixture.selected = 0;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud.favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 3 && favorite_observed.action == 1 &&
        g_strcmp0(favorite_observed.identifier, ids[0]) == 0;
    fixture.selected = 2;
    g_array_index(fixture.favorite_ranks, gint32, 1) = -1;
    voices_apply(&fixture);
    okay = okay && !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.favorite_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.favorite_button)) && favorite_observed.calls == 3;
    voices_apply(&original);
    g_ptr_array_unref(original.names);
    if (original.identifiers != NULL) g_ptr_array_unref(original.identifiers);
    if (original.favorite_ranks != NULL) g_array_unref(original.favorite_ranks);
    g_ptr_array_unref(fixture.names);
    g_ptr_array_unref(fixture.identifiers);
    g_array_unref(fixture.favorite_ranks);
    g_clear_pointer(&favorite_observed.identifier, g_free);
    return okay ? 0 : fail(error, capacity, "Favorite voices lost identity, empty state, or add/remove routing");
}

/* Launch at login shows what the host reports, is fixed while the system
 * decides it, and reports the user's switch once, then waits for the answer. */
static int32_t login_item_self_test(char *error, size_t capacity) {
    LoginItem blocked = { .state = 2, .detail = (gchar *)"Turned off in Settings." };
    login_item_apply(&blocked);
    if (adw_switch_row_get_active(general_page()->login_row) || gtk_widget_get_sensitive(GTK_WIDGET(general_page()->login_row))
        || g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(general_page()->login_row)), blocked.detail) != 0) {
        return fail(error, capacity, "Launch at login did not show a state the system decides");
    }
    LoginItem off = { .state = 0, .detail = (gchar *)"Start minimised." };
    login_item_apply(&off);
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    adw_switch_row_set_active(general_page()->login_row, TRUE);
    gboolean reported = observed.event == JSTI_EVENT_LOGIN_ITEM && observed.index == 1;
    gboolean waiting = !gtk_widget_get_sensitive(GTK_WIDGET(general_page()->login_row));
    observed.event = 0;
    LoginItem on = { .state = 1, .detail = (gchar *)"Start minimised." };
    login_item_apply(&on);
    gboolean quiet = observed.event == 0;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    if (!reported || !waiting) return fail(error, capacity, "Launch at login did not report the switch");
    if (!quiet || !adw_switch_row_get_active(general_page()->login_row) || !gtk_widget_get_sensitive(GTK_WIDGET(general_page()->login_row))) {
        return fail(error, capacity, "Launch at login did not show the state reached");
    }
    login_item_apply(&off);
    return 0;
}

static void text_output_capture(int32_t event, const char *text, int32_t index, void *context) {
    gchar *expected = output_page()->app_switch_configured
        ? g_strdup_printf("restore\t%u", adw_combo_row_get_selected(output_page()->app_switch_row)) : g_strdup("restore");
    if (event == JSTI_EVENT_TEXT_OUTPUT && index == 1 && g_strcmp0(text, expected) == 0)
        ++*(guint *)context;
    g_free(expected);
}

static int32_t automation_self_test(char *error, size_t capacity) {
    LoginItem off = { .state = 0, .detail = (gchar *)"Imported request pending local consent." };
    automation_apply(&off);
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    adw_switch_row_set_active(general_page()->automation_row, TRUE);
    gboolean pending = observed.event == JSTI_EVENT_AUTOMATION && observed.index == 1
        && !gtk_widget_get_sensitive(GTK_WIDGET(general_page()->automation_row));
    observed.event = 0;
    LoginItem failed = { .state = 0, .detail = (gchar *)"Automation could not start." };
    automation_apply(&failed);
    gboolean actual = observed.event == 0 && !adw_switch_row_get_active(general_page()->automation_row)
        && gtk_widget_get_sensitive(GTK_WIDGET(general_page()->automation_row))
        && g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(general_page()->automation_row)), failed.detail) == 0;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    automation_apply(&off);
    return pending && actual ? 0 : fail(error, capacity, "Automation did not show its actual state or failure");
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

static gboolean text_output_self_test(void) {
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

int32_t jsti_window_self_test(char *error, size_t capacity) {
    if (jsti_hands_free_guard_self_test(error, capacity) != 0) return -1;
    if (jsti_desktop_palette_self_test(error, capacity) != 0) return -1;
    if (ui.window == NULL) return fail(error, capacity, "the window was not created");
    if (jsti_issue_report_self_test(error, capacity) != 0) return -1;
    const JSTIAboutLink invalid_about_link = {"Invalid", "file:///not-an-update"};
    if (about_page()->about_details == NULL || about_page()->about_links == NULL ||
        strstr(gtk_label_get_text(about_page()->about_details), "Version:") == NULL ||
        jsti_window_configure_about("bad", NULL, 0) != -1 ||
        jsti_window_configure_about("bad", &invalid_about_link, 1) != -1 ||
        jsti_window_configure_about("\xff", &invalid_about_link, 1) != -1)
        return fail(error, capacity, "About metadata or invalid input refusal failed");
    guint about_count = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(about_page()->about_links));
         child != NULL; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *button = gtk_flow_box_child_get_child(GTK_FLOW_BOX_CHILD(child));
        const char *uri = g_object_get_data(G_OBJECT(button), "about-uri");
        if (!GTK_IS_BUTTON(button) || uri == NULL || !g_str_has_prefix(uri, "https://"))
            return fail(error, capacity, "About link label or destination was not preserved");
        ++about_count;
    }
    if (about_count != 6) return fail(error, capacity, "About canonical links are missing");
    if (!cleanup_preview_self_test())
        return fail(error, capacity, "cleanup preview bounds, coalescing, navigation or retirement failed");
    if (local_cleanup_sources_self_test(error, capacity) != 0) return -1;
    if (jsti_visual_density_self_test(GTK_WIDGET(ui.window)) != 0)
        return fail(error, capacity, "layout density geometry, Normal restoration or editing focus failed");
    if (!sidebar_navigation_self_test())
        return fail(error, capacity, "sidebar hints, focus guards or window-local navigation failed");
    if (jsti_action_shortcuts_self_test(error, capacity) != 0) return -1;
    if (jsti_action_shortcut_editor_self_test(ui.window, error, capacity) != 0) return -1;
    if (!action_execution_self_test())
        return fail(error, capacity, "action shortcut native page, event, slot or sensitivity routing failed");
    if (!command_forwarding_self_test())
        return fail(error, capacity, "desktop-bound command parsing, dispatch or lifetime admission failed");
    if (!command_process_self_test(error, capacity)) return -1;
    if (!post_processing_self_test())
        return fail(error, capacity, "Local/Remote post-processing controls, key isolation or callback indexes failed");
    if (storage_page()->recordings_folder == NULL || history_page()->audio_cleanup == NULL ||
        storage_page()->backup_audio == NULL || storage_page()->backup_profiles == NULL ||
        storage_page()->backup_export == NULL || storage_page()->backup_inspect == NULL || storage_page()->backup_restore == NULL ||
        !adw_switch_row_get_active(storage_page()->backup_audio) ||
        adw_switch_row_get_active(storage_page()->backup_profiles) ||
        jsti_window_confirm_audio_cleanup(NULL, 1) != -1 ||
        g_strcmp0(gtk_button_get_label(storage_page()->recordings_folder), "_Open folder") != 0) {
        return fail(error, capacity, "the recording folder control was not created");
    }
    BackupChoice choice = {0};
    g_weak_ref_init(&choice.parent, G_OBJECT(ui.window));
    choice.cancelled = g_cancellable_new();
    storage_page()->backup_chooser = g_object_ref(choice.cancelled);
    GObject *choice_parent = g_weak_ref_get(&choice.parent);
    refresh_actions();
    gboolean backup_ok = backup_choice_active(&choice, choice_parent) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_audio)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_profiles)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_export)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_inspect)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(storage_page()->backup_restore));
    jsti_window_event_fn backup_callback = ui.callback;
    ui.callback = observe_event;
    for (gint32 flags = 0; flags < 4; ++flags) {
        choice.include_audio = flags & 1;
        choice.include_profiles = flags & 2;
        backup_emit_path(&choice, "synthetic-export.zip");
        backup_ok = backup_ok && observed.event == JSTI_EVENT_MIGRATION_EXPORT && observed.index == flags &&
            g_strcmp0(observed.text, "synthetic-export.zip") == 0;
    }
    choice.action = 1;
    choice.include_audio = 1;
    backup_emit_path(&choice, "synthetic-review.zip");
    backup_ok = backup_ok && observed.event == JSTI_EVENT_MIGRATION_INSPECT && observed.index == 0 &&
        g_strcmp0(observed.text, "synthetic-review.zip") == 0;
    choice.action = 2;
    backup_emit_path(&choice, "synthetic-restore.zip");
    backup_ok = backup_ok && observed.event == JSTI_EVENT_MIGRATION_RESTORE && observed.index == 0 &&
        g_strcmp0(observed.text, "synthetic-restore.zip") == 0;
    observed.event = 0;
    on_recordings_default(NULL, NULL);
    backup_ok = backup_ok && observed.event == JSTI_EVENT_RECORDINGS_LOCATION &&
        observed.event != JSTI_EVENT_MIGRATION_RESTORE && g_strcmp0(observed.text, "") == 0;
    ui.callback = backup_callback;
    g_clear_pointer(&observed.text, g_free);
    ui.closing = TRUE;
    backup_ok = backup_ok && !backup_choice_active(&choice, choice_parent);
    ui.closing = FALSE;
    g_cancellable_cancel(choice.cancelled);
    backup_ok = backup_ok && !backup_choice_active(&choice, choice_parent);
    g_clear_object(&storage_page()->backup_chooser);
    g_clear_object(&choice_parent);
    g_weak_ref_clear(&choice.parent);
    g_object_unref(choice.cancelled);
    refresh_actions();
    if (!backup_ok) return fail(error, capacity, "History backup events, recordings location or chooser fences failed");
    gchar report_text[] = "Synthetic read-only report.";
    GtkWidget *report_dialog = migration_report_dialog(report_text);
    g_object_ref_sink(report_dialog);
    report_text[0] = 'x';
    gboolean report_ok = jsti_window_show_migration_report(NULL) == -1 &&
        g_strcmp0(adw_message_dialog_get_body(ADW_MESSAGE_DIALOG(report_dialog)), "Synthetic read-only report.") == 0 &&
        g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(report_dialog)), "close") == 0 &&
        g_strcmp0(adw_message_dialog_get_close_response(ADW_MESSAGE_DIALOG(report_dialog)), "close") == 0;
    gtk_window_destroy(GTK_WINDOW(report_dialog));
    g_object_unref(report_dialog);
    if (!report_ok) return fail(error, capacity, "Backup inspection report text ownership or close defaults changed");
    if (!migration_restore_self_test())
        return fail(error, capacity, "Backup restore preview, two-stage confirmation or lifecycle fence failed");
    gchar audio_token[] = "00000000-0000-0000-0000-000000000093";
    GtkWidget *audio_confirmation = audio_cleanup_dialog(audio_token, 2);
    g_object_ref_sink(audio_confirmation);
    audio_token[0] = 'x';
    gboolean audio_confirmation_ok =
        g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(audio_confirmation)), "cancel") == 0 &&
        g_strcmp0(adw_message_dialog_get_close_response(ADW_MESSAGE_DIALOG(audio_confirmation)), "cancel") == 0 &&
        g_strcmp0(g_object_get_data(G_OBJECT(audio_confirmation), "jsti-audio-cleanup-token"),
                  "00000000-0000-0000-0000-000000000093") == 0;
    g_signal_handlers_block_by_func(audio_confirmation, G_CALLBACK(audio_cleanup_response), NULL);
    gtk_window_destroy(GTK_WINDOW(audio_confirmation));
    g_object_unref(audio_confirmation);
    if (!audio_confirmation_ok) return fail(error, capacity, "recording audio confirmation defaults or snapshot changed");
    if (!configuration_self_test())
        return fail(error, capacity, "configuration rows did not populate and emit a complete Apply");
    if (!configuration_reveal_self_test())
        return fail(error, capacity, "settings search did not refuse an unknown field or highlight a known one");
    if (jsti_settings_search_self_test(error, capacity) != 0) return -1;
    if (!text_output_self_test())
        return fail(error, capacity, "clipboard restoration did not follow the session capability and saved choice");
    const char *icon_name = gtk_window_get_icon_name(ui.window);
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(GTK_WIDGET(ui.window)));
    if (g_strcmp0(icon_name, "com.justspeaktoit.JustSpeakToIt") != 0 ||
        !gtk_icon_theme_has_icon(theme, "com.justspeaktoit.JustSpeakToIt")) {
        return fail(error, capacity, "the canonical application icon is not available in the window's theme");
    }
    if (login_item_self_test(error, capacity) != 0) return -1;
    if (automation_self_test(error, capacity) != 0) return -1;
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
    if (jsti_local_models_self_test(error, capacity) != 0) return -1;
    if (jsti_model_filters_self_test(error, capacity) != 0) return -1;
    if (!model_modes_self_test())
        return fail(error, capacity, "Model picker did not isolate and restore all four Source/Mode choices");
    if (jsti_cloud_sync_self_test(error, capacity) != 0) return -1;
    if (jsti_history_filters_self_test(error, capacity) != 0) return -1;
    if (jsti_vocabulary_self_test(error, capacity) != 0) return -1;
    if (jsti_profiles_self_test(error, capacity) != 0) return -1;
    if (jsti_troubleshooting_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_api_keys_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_permissions_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_setup_self_test(ui.window, error, capacity) != 0) return -1;
    if (!cancel_key_self_test()) return fail(error, capacity, "Escape cancellation ownership or repeat guards failed");
    {
        GtkTextBuffer *prompt = gtk_text_view_get_buffer(polish_page()->polish_prompt_row);
        GtkTextIter prompt_start, prompt_end;
        gtk_text_buffer_get_bounds(prompt, &prompt_start, &prompt_end);
        gchar *draft = gtk_text_buffer_get_text(prompt, &prompt_start, &prompt_end, TRUE);
        gint32 saved_enabled = adw_switch_row_get_active(polish_page()->polish_row) ? 1 : 0;
        gint32 disabled = 0;
        post_processing_enabled_apply(&disabled);
        gtk_text_buffer_get_bounds(prompt, &prompt_start, &prompt_end);
        gchar *after_fix = gtk_text_buffer_get_text(prompt, &prompt_start, &prompt_end, TRUE);
        gboolean draft_preserved = g_strcmp0(draft, after_fix) == 0 && !adw_switch_row_get_active(polish_page()->polish_row);
        post_processing_enabled_apply(&saved_enabled);
        g_free(draft); g_free(after_fix);
        if (!draft_preserved || jsti_window_set_post_processing_enabled(2) != -1)
            return fail(error, capacity, "cleanup fix refresh replaced a prompt draft or accepted an invalid state");
    }
    const char *first = "00000000-0000-0000-0000-000000000001";
    const char *second = "00000000-0000-0000-0000-000000000002";
    JSTIHistoryRow rows[] = {
        { first, "Today", "24.00", "$0.01", "First transcript", "Model A", "Profile: Email", 0 },
        { second, "Today", "", "", "Second transcript", "Model B", "", 1 },
    };
    History *history = history_copy(rows, G_N_ELEMENTS(rows), first);
    history_apply(history);
    history_free(history);
    if (history_page()->history_ids->len != 2 || g_strcmp0(history_page()->selected_id, first) != 0) {
        return fail(error, capacity, "History rows or selection were not applied");
    }
    gchar *all_ids = g_strdup_printf("%s\n%s", first, second);
    if (jsti_window_set_history_management(NULL) != -1 || jsti_window_set_history_management("\xff") != -1) {
        g_free(all_ids);
        return fail(error, capacity, "invalid History management input was accepted");
    }
    history_management_apply(all_ids);
    GtkWidget *confirmation = history_delete_dialog(all_ids, TRUE);
    g_object_ref_sink(confirmation);
    gboolean management_ok = gtk_widget_get_sensitive(GTK_WIDGET(history_page()->history_delete))
        && gtk_widget_get_sensitive(GTK_WIDGET(history_page()->history_clear))
        && adw_message_dialog_has_response(ADW_MESSAGE_DIALOG(confirmation), "keep-audio")
        && adw_message_dialog_has_response(ADW_MESSAGE_DIALOG(confirmation), "delete-audio")
        && g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(confirmation)), "cancel") == 0;
    history_management_apply((gpointer)first);
    management_ok = management_ok && g_strcmp0(
        g_object_get_data(G_OBJECT(confirmation), "jsti-history-delete-ids"), all_ids) == 0;
    gtk_window_destroy(GTK_WINDOW(confirmation));
    g_object_unref(confirmation);
    history_management_apply(all_ids);
    g_free(all_ids);
    if (!management_ok) return fail(error, capacity, "History confirmation choices or frozen IDs were not retained");
    /* The selected card holds the transcript and its actions. */
    GtkListBoxRow *first_row = gtk_list_box_get_row_at_index(history_page()->history, 0);
    if (gtk_widget_get_parent(history_page()->detail) != gtk_list_box_row_get_child(first_row)) {
        return fail(error, capacity, "the selected History card does not hold its transcript");
    }
    JSTIInsights totals = { "2", "1", "00m 24s", "00m 12s", "$0.01" };
    Insights *insights = g_new0(Insights, 1);
    insights_copy(insights->all, &totals);
    insights_copy(insights->visible, &totals);
    insights_apply(insights);
    insights_free(insights);
    if (g_strcmp0(gtk_label_get_text(dashboard_page()->hero_sessions), "2") != 0
        || g_strcmp0(gtk_label_get_text(history_page()->history_errors), "1") != 0
        || g_strcmp0(gtk_label_get_text(dashboard_page()->insight_average), "00m 12s") != 0) {
        return fail(error, capacity, "the History totals were not shown");
    }
    for (gint32 page = JSTI_PAGE_COUNT - 1; page >= 0; page--) {
        show_page(page);
        if (g_strcmp0(gtk_stack_get_visible_child_name(ui.pages), page_info[page].name) != 0
            || gtk_list_box_row_get_index(gtk_list_box_get_selected_row(ui.sidebar)) != page) {
            return fail(error, capacity, "a sidebar page could not be shown");
        }
    }
    Presentation stale = { .id = (gchar *)second, .variant = 0, .switchable = TRUE,
                           .text = (gchar *)"Stale", .status = (gchar *)"Stale", .has_text = TRUE };
    presentation_apply(&stale);
    gchar *shown = displayed_transcript();
    gboolean leaked = g_strcmp0(shown, "Stale") == 0;
    g_free(shown);
    if (leaked) return fail(error, capacity, "an unselected record's text was displayed");
    Presentation current = { .id = (gchar *)first, .variant = 0, .switchable = TRUE,
                             .text = (gchar *)"Processed text", .status = (gchar *)"Shown", .has_text = TRUE };
    presentation_apply(&current);
    char buffer[64];
    size_t required = 0;
    if (jsti_window_transcript_snapshot(buffer, sizeof buffer, &required) != 0 ||
        g_strcmp0(buffer, "Processed text") != 0 || jsti_window_transcript_variant() != 0) {
        return fail(error, capacity, "the displayed transcript snapshot did not match");
    }
    if (!gtk_widget_get_sensitive(GTK_WIDGET(dashboard_page()->copy)) || !gtk_widget_get_visible(GTK_WIDGET(dashboard_page()->version))) {
        return fail(error, capacity, "Copy or the version control stayed unavailable");
    }
    if (read_aloud_self_test(first, error, capacity) != 0) return -1;
    if (voice_favorites_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_credentials_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_sources_self_test(ui.window, error, capacity) != 0) return -1;
    History *empty = history_copy(NULL, 0, "");
    history_apply(empty);
    history_free(empty);
    Update clear = { .status = (gchar *)"Self-test complete.", .transcript = (gchar *)"", .has_transcript = TRUE,
                     .state = JSTI_STATE_IDLE };
    update_apply(&clear);
    if (history_page()->selected_id != NULL || gtk_widget_get_sensitive(GTK_WIDGET(dashboard_page()->copy))) {
        return fail(error, capacity, "clearing History left record actions enabled");
    }
    if (gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(dashboard_page()->status)) != GTK_ACCESSIBLE_ROLE_STATUS)
        return fail(error, capacity, "the window status lost its accessible status role");
    if (jsti_hud_self_test(error, capacity) != 0) return -1;
    if (jsti_comparison_self_test(ui.window, error, capacity) != 0) return -1;
    return jsti_tray_self_test(error, capacity);
}
