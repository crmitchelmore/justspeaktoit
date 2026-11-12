/* Read aloud on the History card and the favourite-voice picker. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"
#include "../CLinuxSupport/LinuxWindowReadAloudState.h"

/* Read aloud follows the presented record: offered while its text is shown
 * and the window is idle, it reports that record, and the voice picker
 * reports the chosen position. */
int32_t read_aloud_self_test(const char *record, char *error, size_t capacity) {
    if (g_list_model_get_n_items(G_LIST_MODEL(read_aloud_state()->voices)) < 2) {
        return fail(error, capacity, "Read aloud offers fewer than two voices");
    }
    if (!gtk_widget_get_sensitive(GTK_WIDGET(history_page()->read_aloud))) {
        return fail(error, capacity, "Read aloud was unavailable for the presented record");
    }
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    JSTIVoicePickerCallback picker_callback = read_aloud_state()->picker_callback;
    read_aloud_state()->picker_callback = NULL;
    observed.event = 0;
    g_signal_emit_by_name(history_page()->read_aloud, "clicked");
    gboolean reported = observed.event == JSTI_EVENT_READ_ALOUD && g_strcmp0(observed.text, record) == 0;
    guint saved = adw_combo_row_get_selected(read_aloud_state()->voice_row);
    guint other = saved == 0 ? 1 : 0;
    observed.event = 0;
    adw_combo_row_set_selected(read_aloud_state()->voice_row, other);
    gboolean chosen = observed.event == JSTI_EVENT_VOICE_OUTPUT && observed.index == (gint32)other;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(read_aloud_state()->voice_row, saved);
    ui.suppress = FALSE;
    ui.callback = callback;
    read_aloud_state()->picker_callback = picker_callback;
    g_clear_pointer(&observed.text, g_free);
    if (!reported) return fail(error, capacity, "Read aloud did not report the presented record");
    if (!chosen) return fail(error, capacity, "the voice picker did not report the chosen voice");
    Update working = { .state = JSTI_STATE_WORKING };
    update_apply(&working);
    gboolean offered = gtk_widget_get_sensitive(GTK_WIDGET(history_page()->read_aloud));
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

int32_t voice_favorites_self_test(char *error, size_t capacity) {
    Voices original = {0};
    original.names = g_ptr_array_new_with_free_func(g_free);
    for (guint index = 0; index < g_list_model_get_n_items(G_LIST_MODEL(read_aloud_state()->voices)); ++index) {
        g_ptr_array_add(original.names, g_strdup(gtk_string_list_get_string(read_aloud_state()->voices, index)));
    }
    original.selected = (gint32)adw_combo_row_get_selected(read_aloud_state()->voice_row);
    original.identifiers = read_aloud_state()->identifiers != NULL ? g_ptr_array_ref(read_aloud_state()->identifiers) : NULL;
    original.favorite_ranks = read_aloud_state()->favorite_ranks != NULL ? g_array_ref(read_aloud_state()->favorite_ranks) : NULL;
    original.callback = read_aloud_state()->picker_callback;
    original.context = read_aloud_state()->picker_context;
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
    gboolean okay = favorite_observed.calls == 0 && read_aloud_state()->favorite_indices->len == 1 &&
        g_array_index(read_aloud_state()->favorite_indices, guint, 0) == 1 &&
        adw_combo_row_get_selected(read_aloud_state()->favorite_row) == read_aloud_state()->favorite_indices->len &&
        g_list_model_get_n_items(G_LIST_MODEL(read_aloud_state()->favorite_names)) == 2;
    adw_combo_row_set_selected(read_aloud_state()->favorite_row, 0);
    okay = okay && favorite_observed.calls == 1 && favorite_observed.action == 0 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    adw_combo_row_set_selected(read_aloud_state()->favorite_row, read_aloud_state()->favorite_indices->len);
    okay = okay && favorite_observed.calls == 1;
    /* A host acknowledgement, not an optimistic UI write, updates button state. */
    fixture.selected = 1;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud_state()->favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 2 && favorite_observed.action == 2 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    fixture.selected = 0;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud_state()->favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 3 && favorite_observed.action == 1 &&
        g_strcmp0(favorite_observed.identifier, ids[0]) == 0;
    fixture.selected = 2;
    g_array_index(fixture.favorite_ranks, gint32, 1) = -1;
    voices_apply(&fixture);
    okay = okay && !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud_state()->favorite_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud_state()->favorite_button)) && favorite_observed.calls == 3;
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
