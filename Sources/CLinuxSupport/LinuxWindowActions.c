/* Window actions: the event callback, recording, cancel and copy, and the
 * refresh that asks every page to follow the window state. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowModelsPage.h"
#include "LinuxWindowStoragePage.h"

void emit(gint32 event, const char *text, gint32 index) {
    if (ui.callback != NULL && !ui.suppress) ui.callback(event, text != NULL ? text : "", index, ui.context);
}

/* Every page's actions follow the window state; each page refreshes its own. */
void refresh_actions(void) {
    gboolean idle = ui.state == JSTI_STATE_IDLE;
    jsti_action_shortcut_editor_set_idle(idle);
    jsti_api_keys_set_idle(idle);
    gchar *text = displayed_transcript();
    gboolean has_text = text != NULL && text[0] != '\0';
    g_free(text);
    gboolean copyable = has_text && !cleanup_preview_visible();
    gboolean recording = ui.state == JSTI_STATE_RECORDING;
    dashboard_refresh_actions(ui.state, copyable);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.header_record), ui.state != JSTI_STATE_WORKING);
    adw_button_content_set_label(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                 recording ? "Stop" : "Record");
    adw_button_content_set_icon_name(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                     recording ? "media-playback-stop-symbolic" : "audio-input-microphone-symbolic");
    if (recording) gtk_widget_add_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    else gtk_widget_remove_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    /* Speaks the presented record's displayed text, so it needs both. */
    gboolean voices = read_aloud_has_voices();
    gboolean readable = idle && history_selection_presented() && has_text && voices;
    refresh_history_actions(idle, has_text, copyable, readable);
    voice_page_refresh_actions(idle, readable, voices);
    jsti_voice_credentials_set_idle(idle);
    read_aloud_refresh_actions(idle);
    storage_refresh_actions(idle);
    refresh_migration_restore();
    models_refresh_actions(idle);
    refresh_setup();
}

/* ------------------------------------------------------------ callbacks */

void on_record(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_TOGGLE_RECORDING, selected_microphone(), selected_model_slot());
}

/* A command from the status notifier's menu (LinuxTray.c). */
void jsti_window_tray_command(int command) {
    if (ui.window == NULL) return;
    switch (command) {
    case 1:
        if (ui.state == JSTI_STATE_WORKING) emit(JSTI_EVENT_CANCEL, "", 0);
        else emit(JSTI_EVENT_TOGGLE_RECORDING, selected_microphone(), selected_model_slot());
        break;
    case 3: show_page(JSTI_PAGE_GENERAL); gtk_window_present(ui.window); break;
    case 4: gtk_window_close(ui.window); break;
    default: gtk_window_present(ui.window); break;
    }
}

void on_cancel(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    retire_cleanup_preview();
    emit(JSTI_EVENT_CANCEL, "", 0);
}

void on_copy(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (cleanup_preview_visible()) return;
    emit(JSTI_EVENT_COPY, "", 0);
}

