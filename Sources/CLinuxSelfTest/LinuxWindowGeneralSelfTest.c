/* The General page: Launch at login and Automation follow the host's answer. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowGeneralState.h"

/* Launch at login shows what the host reports, is fixed while the system
 * decides it, and reports the user's switch once, then waits for the answer. */
int32_t login_item_self_test(char *error, size_t capacity) {
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

int32_t automation_self_test(char *error, size_t capacity) {
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
