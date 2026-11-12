/* The History page: rows, selection, management, totals, presentation and clearing. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowDashboardState.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"

static const char *const first = SELF_TEST_FIRST_RECORD;
static const char *const second = SELF_TEST_SECOND_RECORD;

int32_t history_records_self_test(char *error, size_t capacity) {
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
    /* Other units see the selection and presentation only through LinuxWindowHistoryPage.h. */
    HistoryPage saved = *history_page();
    gchar *saved_presented = g_strdup(saved.presented_id);
    history_mark_presented(first, 0, TRUE);
    gboolean presented = history_is_selected(first) && !history_is_selected(second) &&
        history_selection_presented() && history_presented_switchable() && history_presented_variant() == 0;
    history_forget_presentation();
    presented = presented && !history_selection_presented() && g_strcmp0(history_selected_id(), first) == 0;
    history_mark_presented(saved_presented, saved.presented_variant, saved.presented_switchable);
    g_free(saved_presented);
    if (!presented) return fail(error, capacity, "the History selection functions disagree with the page state");
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
    return 0;
}

int32_t history_presentation_self_test(char *error, size_t capacity) {
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
    if (!gtk_widget_get_sensitive(GTK_WIDGET(history_page()->copy)) || !gtk_widget_get_visible(GTK_WIDGET(history_page()->version))) {
        return fail(error, capacity, "Copy or the version control stayed unavailable");
    }
    return 0;
}

int32_t history_clear_self_test(char *error, size_t capacity) {
    History *empty = history_copy(NULL, 0, "");
    history_apply(empty);
    history_free(empty);
    Update clear = { .status = (gchar *)"Self-test complete.", .transcript = (gchar *)"", .has_transcript = TRUE,
                     .state = JSTI_STATE_IDLE };
    update_apply(&clear);
    if (history_page()->selected_id != NULL || gtk_widget_get_sensitive(GTK_WIDGET(history_page()->copy))) {
        return fail(error, capacity, "clearing History left record actions enabled");
    }
    return 0;
}
