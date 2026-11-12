/* Escape cancellation: the shared escape policy and the window's cancel key. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"

static void observe_cancel(gint32 event, const char *text, gint32 index, void *context) {
    (void)index;
    gint32 *calls = context;
    ++calls[0];
    calls[1] = event;
    gchar expected[32];
    guint64 token = window_escape_token();
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

gboolean cancel_key_self_test(void) {
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint32 state = ui.state, calls[4] = {0};
    gboolean saved_policy = escape_enabled(), saved_recording = escape_recording();
    gboolean held = ui.cancel_key_held, suppress = ui.suppress, closing = ui.closing;
    gboolean sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.callback = observe_cancel; ui.context = calls;
    ui.cancel_key_held = FALSE; ui.suppress = FALSE; ui.closing = FALSE; ui.state = JSTI_STATE_IDLE;
    window_escape_publish(JSTI_STATE_IDLE, 1, FALSE);
    gboolean okay = escape_policy_self_test() && !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE);
    ui.state = JSTI_STATE_RECORDING;
    window_escape_publish(ui.state, -1, FALSE);
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
    okay = cancel_key(GDK_KEY_Escape, GDK_LOCK_MASK, GTK_WIDGET(history_page()->transcript), TRUE) &&
        calls[0] == 1 && calls[1] == JSTI_EVENT_CANCEL && calls[2] && okay;
    ui.state = JSTI_STATE_IDLE;
    window_escape_publish(ui.state, -1, FALSE);
    okay = cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 1 && okay;
    action_key_released(NULL, GDK_KEY_Escape, 9, 0, NULL);
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && !ui.cancel_key_held && okay;
    ui.state = JSTI_STATE_WORKING;
    window_escape_publish(ui.state, -1, FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && okay;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.closing = TRUE;
    okay = !cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && okay;
    ui.closing = FALSE;
    okay = cancel_key(GDK_KEY_Escape, 0, NULL, TRUE) && calls[0] == 2 && okay;
    guint64 old_token = window_escape_token();
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
    window_escape_publish(saved_recording ? JSTI_STATE_RECORDING : JSTI_STATE_IDLE, saved_policy, FALSE);
    ui.callback = callback; ui.context = context; ui.state = state;
    ui.cancel_key_held = held; ui.suppress = suppress; ui.closing = closing;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    return okay;
}
