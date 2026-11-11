/* Control handlers: recording, models, microphones, output, appearance and History actions. */
#include "LinuxWindowInternal.h"

void emit(gint32 event, const char *text, gint32 index) {
    if (ui.callback != NULL && !ui.suppress) ui.callback(event, text != NULL ? text : "", index, ui.context);
}

gint32 selected_model_slot(void) {
    guint position = adw_combo_row_get_selected(ui.model_row);
    if (ui.model_slots == NULL || position == GTK_INVALID_LIST_POSITION || position >= ui.model_slots->len) {
        return -1;
    }
    return g_array_index(ui.model_slots, Slot, position).global;
}

const char *selected_microphone(void) {
    guint position = adw_combo_row_get_selected(ui.microphone_row);
    if (ui.microphone_ids == NULL || position == GTK_INVALID_LIST_POSITION || position >= ui.microphone_ids->len) {
        return "";
    }
    return g_ptr_array_index(ui.microphone_ids, position);
}

gchar *displayed_transcript(void) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(ui.transcript);
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}

void set_transcript(const char *text) {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.transcript), text != NULL ? text : "", -1);
}

static const char *combo_text(AdwComboRow *row) {
    GObject *item = adw_combo_row_get_selected_item(row);
    return item != NULL ? gtk_string_object_get_string(GTK_STRING_OBJECT(item)) : NULL;
}

/* The dashboard's Setup card and the header subtitle echo the settings. */
void refresh_setup(void) {
    const char *microphone = combo_text(ui.microphone_row);
    gtk_label_set_text(ui.setup_microphone, microphone != NULL ? microphone : "Default microphone");
    const char *model = combo_text(ui.model_row);
    gtk_label_set_text(ui.setup_model, model != NULL ? model : "No model selected");
    adw_window_title_set_subtitle(ui.title, model != NULL ? model : "");
    const char *output = combo_text(ui.output_row);
    gboolean restores = ui.can_restore_clipboard && adw_combo_row_get_selected(ui.output_row) == 0 &&
                        adw_switch_row_get_active(ui.restore_row);
    gchar *text = g_strdup_printf("%s%s", output != NULL ? output : "", restores ? " · clipboard restored" : "");
    gtk_label_set_text(ui.setup_output, text);
    g_free(text);
    const char *hint = adw_action_row_get_subtitle(ui.shortcut_row);
    gtk_label_set_text(ui.setup_shortcut, hint != NULL && hint[0] != '\0' ? hint : "Checking the desktop…");
}

void refresh_actions(void) {
    gboolean idle = ui.state == JSTI_STATE_IDLE;
    jsti_action_shortcut_editor_set_idle(idle);
    jsti_api_keys_set_idle(idle);
    gchar *text = displayed_transcript();
    gboolean has_text = text != NULL && text[0] != '\0';
    g_free(text);
    gboolean has_record = ui.selected_id != NULL;
    gboolean presented = has_record && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy), has_text && !cleanup_visible);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.dashboard_copy), has_text && !cleanup_visible);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gtk_widget_set_visible(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gboolean recording = ui.state == JSTI_STATE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), ui.state != JSTI_STATE_WORKING);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.header_record), ui.state != JSTI_STATE_WORKING);
    gtk_button_set_label(ui.record, recording ? "Stop Recording"
                                    : ui.state == JSTI_STATE_WORKING ? "Working…" : "Start Recording");
    adw_button_content_set_label(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                 recording ? "Stop" : "Record");
    adw_button_content_set_icon_name(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                     recording ? "media-playback-stop-symbolic" : "audio-input-microphone-symbolic");
    if (recording) {
        gtk_widget_add_css_class(GTK_WIDGET(ui.record), "recording");
        gtk_widget_add_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    } else {
        gtk_widget_remove_css_class(GTK_WIDGET(ui.record), "recording");
        gtk_widget_remove_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    }
    /* While recording, the hero previews the words as they arrive. */
    gchar *preview = recording ? displayed_transcript() : NULL;
    gtk_label_set_text(ui.live_preview, preview != NULL && preview[0] != '\0' ? preview : "Listening…");
    gtk_widget_set_visible(GTK_WIDGET(ui.live_preview), recording);
    g_free(preview);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.retry), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.correction_results), idle && presented);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.export_button), idle && presented && has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.issue_button), idle && presented);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.open_audio), has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), has_record && (idle || ui.playback_state != 0));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop_play), has_record && ui.playback_state != 0);
    gtk_button_set_label(ui.play, ui.playback_state == 1 ? "Pause" : "Play");
    /* Speaks the presented record's displayed text, so it needs both. */
    gboolean voices = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) > 0;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.button), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_read), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), !ui.closing);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_sources), idle && voices);
    jsti_voice_credentials_set_idle(idle);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.voice_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_row),
        idle && read_aloud.favorite_indices != NULL && read_aloud.favorite_indices->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button),
        idle && read_aloud.favorite_executable && !read_aloud.favorite_pending);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.import_button), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_import), idle);
    gtk_widget_set_sensitive(ui.history_filters, idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_delete), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_clear),
        idle && ui.all_history_ids != NULL && ui.all_history_ids[0] != '\0');
    if (ui.audio_cleanup != NULL) gtk_widget_set_sensitive(GTK_WIDGET(ui.audio_cleanup), idle);
    if (ui.recordings_choose != NULL) {
        gtk_widget_set_sensitive(GTK_WIDGET(ui.recordings_choose), idle && ui.location_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.recordings_default), idle && ui.location_chooser == NULL);
    }
    if (ui.backup_audio != NULL) {
        gboolean backup_idle = idle && ui.backup_chooser == NULL && ui.restore_dialog == NULL;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_audio), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_profiles), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_export), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_inspect), backup_idle);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_restore), backup_idle);
    }
    refresh_migration_restore();
    gtk_widget_set_sensitive(GTK_WIDGET(ui.model_row), idle);
    jsti_model_filters_set_idle(idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.microphone_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.version), presented && ui.presented_switchable && idle);
    gtk_widget_set_visible(GTK_WIDGET(ui.version), presented && ui.presented_switchable);
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
    if (cleanup_visible) return;
    emit(JSTI_EVENT_COPY, "", 0);
}

/* The Azure resource row belongs to Azure models only. */
void refresh_azure_row(void) {
    guint position = adw_combo_row_get_selected(ui.model_row);
    gboolean azure = ui.model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < ui.model_slots->len
        && g_str_has_prefix(g_array_index(ui.model_slots, Slot, position).id, "azure/");
    gtk_widget_set_visible(GTK_WIDGET(ui.azure_row), azure);
    /* On-device models (canonical "local/" identifiers) need no API key. */
    gboolean local = ui.model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < ui.model_slots->len
        && g_str_has_prefix(g_array_index(ui.model_slots, Slot, position).id, "local/");
    gtk_widget_set_visible(GTK_WIDGET(ui.key_row), !local);
}

void on_model(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_azure_row();
    refresh_setup();
    gint32 slot = selected_model_slot();
    if (!ui.suppress && slot >= 0) {
        guint mode = model_mode(jsti_model_filters_local(), jsti_model_filters_live());
        ui.preferred_model_slots[mode] = slot;
    }
    if (slot >= 0) emit(JSTI_EVENT_SELECT_MODEL, "", slot);
}

void on_azure_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_AZURE_RESOURCE, gtk_editable_get_text(GTK_EDITABLE(row)), 0);
}

void on_microphone(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_setup();
    emit(JSTI_EVENT_SELECT_MICROPHONE, selected_microphone(), 0);
}

void on_key_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    const char *key = gtk_editable_get_text(GTK_EDITABLE(row));
    emit(JSTI_EVENT_SAVE_KEY, key, selected_model_slot());
    gtk_editable_set_text(GTK_EDITABLE(row), "");
}

void on_text_output(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint method = adw_combo_row_get_selected(ui.output_row);
    gboolean restore = adw_switch_row_get_active(ui.restore_row);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), method == 0 && ui.can_restore_clipboard);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), method == 0 && ui.app_switch_configured);
    refresh_setup();
    if (ui.app_switch_configured) {
        gchar *payload = g_strdup_printf("%s\t%u", restore ? "restore" : "",
                                        adw_combo_row_get_selected(ui.app_switch_row));
        emit(JSTI_EVENT_TEXT_OUTPUT, payload, (gint32)method);
        g_free(payload);
    } else {
        emit(JSTI_EVENT_TEXT_OUTPUT, restore ? "restore" : "", (gint32)method);
    }
}

void apply_appearance(guint appearance) {
    static const AdwColorScheme schemes[] = { ADW_COLOR_SCHEME_DEFAULT, ADW_COLOR_SCHEME_FORCE_LIGHT,
                                              ADW_COLOR_SCHEME_FORCE_DARK };
    if (appearance < G_N_ELEMENTS(schemes)) {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), schemes[appearance]);
    }
}

void on_appearance(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint appearance = adw_combo_row_get_selected(ui.appearance_row);
    apply_appearance(appearance);
    emit(JSTI_EVENT_APPEARANCE, "", (gint32)appearance);
}

/* Launch at login. The switch waits, insensitive, for the state the desktop
 * reached, which jsti_window_set_login_item reports. */
void on_login_item(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.login_row), FALSE);
    emit(JSTI_EVENT_LOGIN_ITEM, "", adw_switch_row_get_active(ui.login_row) ? 1 : 0);
}

void on_automation(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.automation_row), FALSE);
    emit(JSTI_EVENT_AUTOMATION, "", adw_switch_row_get_active(ui.automation_row) ? 1 : 0);
}

void on_style(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    emit(JSTI_EVENT_SHORTCUT_STYLE, "", (gint32)adw_combo_row_get_selected(ui.style_row));
}

void on_refresh(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_REFRESH_MODELS, "", 0);
}

void on_search(GtkSearchEntry *entry, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_SEARCH_HISTORY, gtk_editable_get_text(GTK_EDITABLE(entry)), 0);
}

/* The transcript and actions live in the selected History card, as the Mac
 * expands its selected row. The window holds its own reference, so moving
 * the detail between cards or rebuilding the list never destroys it. */
void detach_detail(void) {
    GtkWidget *parent = gtk_widget_get_parent(ui.detail);
    if (parent != NULL) gtk_box_remove(GTK_BOX(parent), ui.detail);
}

void attach_detail(GtkListBoxRow *row) {
    GtkWidget *card = row != NULL ? gtk_list_box_row_get_child(row) : NULL;
    if (card != NULL && gtk_widget_get_parent(ui.detail) == card) return;
    detach_detail();
    if (card != NULL) gtk_box_append(GTK_BOX(card), ui.detail);
}

void on_history_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    attach_detail(row);
    if (row == NULL) return;
    gint index = gtk_list_box_row_get_index(row);
    if (index < 0 || (guint)index >= ui.history_ids->len) return;
    const char *id = g_ptr_array_index(ui.history_ids, index);
    if (g_strcmp0(id, ui.selected_id) == 0) return;
    retire_cleanup_preview();
    g_free(ui.selected_id);
    ui.selected_id = g_strdup(id);
    /* Stale text never stays under another record's actions. */
    g_clear_pointer(&ui.presented_id, g_free);
    set_transcript("");
    ui.playback_state = 0;
    gtk_label_set_text(ui.playback_label, "");
    refresh_actions();
    emit(JSTI_EVENT_SELECT_HISTORY, id, 0);
}

void on_version(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return;
    guint selected = gtk_drop_down_get_selected(ui.version);
    if ((gint32)selected == ui.presented_variant) return;
    retire_cleanup_preview();
    ui.presented_variant = (gint32)selected;
    emit(JSTI_EVENT_TRANSCRIPT_VERSION, ui.selected_id, (gint32)selected);
}

void on_retry(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_RETRY_HISTORY, ui.selected_id, 0);
}

void on_correction_results(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL && g_strcmp0(ui.presented_id, ui.selected_id) == 0)
        emit(72, ui.selected_id, 2);
}

void on_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_PLAYBACK_TOGGLE, ui.selected_id, 0);
}

void on_stop_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_PLAYBACK_STOP, ui.selected_id, 0);
}

/* The host captures the displayed text with jsti_window_transcript_snapshot
 * while this event runs, so it is the text shown under this record. */
void on_read_aloud(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return;
    emit(JSTI_EVENT_READ_ALOUD, ui.selected_id, 0);
}

void on_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    read_aloud.favorite_pending = TRUE;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), FALSE);
    if (!ui.suppress) jsti_voice_credentials_selection_pending();
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (read_aloud.picker_callback != NULL) {
        if (read_aloud.identifiers != NULL && position < read_aloud.identifiers->len) {
            const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
            if (*identifier != '\0') read_aloud.picker_callback(0, identifier,
                read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
        }
        return;
    }
    if (position != GTK_INVALID_LIST_POSITION) emit(JSTI_EVENT_VOICE_OUTPUT, "", (gint32)position);
}

void on_favorite_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress || read_aloud.favorite_indices == NULL) return;
    guint position = adw_combo_row_get_selected(read_aloud.favorite_row);
    if (position < read_aloud.favorite_indices->len) {
        guint index = g_array_index(read_aloud.favorite_indices, guint, position);
        if (adw_combo_row_get_selected(read_aloud.voice_row) != index) {
            adw_combo_row_set_selected(read_aloud.voice_row, index);
        }
    }
}

void on_favorite_toggle(GtkButton *button, gpointer data) {
    (void)data;
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (ui.suppress || read_aloud.picker_callback == NULL || read_aloud.identifiers == NULL ||
        position >= read_aloud.identifiers->len) return;
    const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
    if (*identifier == '\0') return;
    gint32 rank = g_array_index(read_aloud.favorite_ranks, gint32, position);
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    read_aloud.favorite_pending = TRUE;
    read_aloud.picker_callback(rank >= 0 ? 2 : 1, identifier,
        read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
}

void on_open_audio(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_OPEN_AUDIO, ui.selected_id, 0);
}
