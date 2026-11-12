/* The Storage page: recordings folder, History backup choices and audio cleanup confirmation. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"
#include "../CLinuxSupport/LinuxWindowStorageState.h"

int32_t storage_self_test(char *error, size_t capacity) {
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
    return 0;
}
