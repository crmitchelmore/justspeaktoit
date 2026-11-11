/* Settings page builders: Voice output, General, Transcription, Post-processing, Keyboard, iCloud and About. */
#include "LinuxWindowInternal.h"

static void on_voice_sources(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gboolean presented = ui.selected_id != NULL && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gchar *snapshot = presented ? displayed_transcript() : g_strdup("");
    jsti_show_voice_sources(ui.window, presented ? ui.selected_id : "", snapshot);
    g_free(snapshot);
}

GtkWidget *build_voice_output(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), jsti_hero_new(
        "voice", "Voice Output",
        "Read History, typed text, clipboard snapshots or imported text with your selected voice. "
        "Export lossless WAV audio.", NULL,
        NULL));
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("audio-speakers-symbolic", "Read aloud", &body);
    gtk_box_append(GTK_BOX(body), read_aloud_group());
    gtk_box_append(GTK_BOX(body), jsti_voice_credentials_group_new());
    GtkWidget *note = gtk_label_new(
        "Choose a recording in History, or open Text and export for typed/pasted text and an explicit clipboard "
        "snapshot. For external selected text, allow session access below and use a desktop shortcut after "
        "refocusing the external field. Recording, another playback or Stop ends voice output.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_box_append(GTK_BOX(body), note);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    ui.voice_stop = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(ui.voice_stop, "clicked", G_CALLBACK(on_stop_play), NULL);
    ui.voice_read = GTK_BUTTON(gtk_button_new_with_label("Read Selected Recording"));
    ui.voice_sources = GTK_BUTTON(gtk_button_new_with_label("Text and export..."));
    g_signal_connect(ui.voice_sources, "clicked", G_CALLBACK(on_voice_sources), NULL);
    gtk_widget_add_css_class(GTK_WIDGET(ui.voice_read), "suggested-action");
    g_signal_connect(ui.voice_read, "clicked", G_CALLBACK(on_read_aloud), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_stop));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_sources));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_read));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), card);
    gtk_box_append(GTK_BOX(column), jsti_selection_access_group_new());
    return page;
}

GtkWidget *build_general(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[0] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "General", "Choose the microphone, where finished text goes, whether the app starts at login, and how "
        "it looks."));
    GtkWidget *microphone = group("Microphone");
    ui.microphone_names = gtk_string_list_new(NULL);
    ui.microphone_ids = g_ptr_array_new_with_free_func(g_free);
    ui.microphone_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.microphone_row), "Preferred microphone");
    adw_combo_row_set_model(ui.microphone_row, G_LIST_MODEL(ui.microphone_names));
    g_signal_connect(ui.microphone_row, "notify::selected", G_CALLBACK(on_microphone), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(microphone), GTK_WIDGET(ui.microphone_row));
    gtk_box_append(GTK_BOX(column), microphone);

    GtkWidget *output = group("Output");
    ui.output_group = ADW_PREFERENCES_GROUP(output);
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(output),
        "Checking paste and clipboard support for this desktop.");
    const char *methods[] = { "Paste into the focused app", "Copy to the clipboard only", NULL };
    ui.output_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.output_row), "Text output");
    adw_combo_row_set_model(ui.output_row, G_LIST_MODEL(gtk_string_list_new(methods)));
    g_signal_connect(ui.output_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.output_row));
    ui.restore_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.restore_row), "Restore the clipboard after pasting");
    adw_switch_row_set_active(ui.restore_row, TRUE);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.restore_row),
                               "Previous text only, while Just Speak to It still owns the X11 selection.");
    gtk_widget_set_visible(GTK_WIDGET(ui.restore_row), FALSE);
    g_signal_connect(ui.restore_row, "notify::active", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.restore_row));
    ui.app_switch_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.app_switch_row), "App-switch delivery");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), FALSE);
    g_signal_connect(ui.app_switch_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.app_switch_row));
    ui.app_switch_help = GTK_LABEL(gtk_label_new(NULL));
    gtk_label_set_wrap(ui.app_switch_help, TRUE);
    gtk_label_set_xalign(ui.app_switch_help, 0);
    gtk_widget_set_margin_top(GTK_WIDGET(ui.app_switch_help), 8);
    gtk_widget_set_margin_bottom(GTK_WIDGET(ui.app_switch_help), 8);
    gtk_widget_set_margin_start(GTK_WIDGET(ui.app_switch_help), 12);
    gtk_widget_set_margin_end(GTK_WIDGET(ui.app_switch_help), 12);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.app_switch_help));
    gtk_box_append(GTK_BOX(column), output);
    gtk_box_append(GTK_BOX(column), jsti_api_keys_group_new(ui.window));

    GtkWidget *startup = group("Startup");
    ui.login_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.login_row), "Launch at login");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.login_row), "Checking the desktop's startup settings…");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.login_row), FALSE);
    g_signal_connect(ui.login_row, "notify::active", G_CALLBACK(on_login_item), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(startup), GTK_WIDGET(ui.login_row));
    gtk_box_append(GTK_BOX(column), startup);

    GtkWidget *automation = group("Automation");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(automation),
        "The speak command uses a private, same-user local socket. Off by default. "
        "Imported preferences cannot grant access on this computer.");
    ui.automation_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.automation_row), "Allow local automation");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.automation_row), "Automation is off.");
    g_signal_connect(ui.automation_row, "notify::active", G_CALLBACK(on_automation), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(automation), GTK_WIDGET(ui.automation_row));
    gtk_box_append(GTK_BOX(column), automation);

    GtkWidget *appearance = group("Appearance");
    const char *schemes[] = { "Follow the system", "Light", "Dark", NULL };
    ui.appearance_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.appearance_row), "Theme");
    adw_combo_row_set_model(ui.appearance_row, G_LIST_MODEL(gtk_string_list_new(schemes)));
    g_signal_connect(ui.appearance_row, "notify::selected", G_CALLBACK(on_appearance), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(appearance), GTK_WIDGET(ui.appearance_row));
    gtk_box_append(GTK_BOX(column), appearance);
    GtkWidget *housekeeping = group("Housekeeping");
    GtkWidget *folder = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(folder), "Recording storage");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(folder), "Open the folder containing saved audio and History data.");
    ui.recordings_folder = GTK_BUTTON(gtk_button_new_with_mnemonic("_Open folder"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_folder), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_folder, "clicked", G_CALLBACK(on_recordings_folder), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(folder), GTK_WIDGET(ui.recordings_folder));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), folder);
    GtkWidget *location = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(location), "New recordings folder");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(location),
        "Save new audio in a local folder you choose. Existing recordings are never moved or deleted.");
    ui.recordings_choose = GTK_BUTTON(gtk_button_new_with_mnemonic("_Choose…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_choose), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_choose, "clicked", G_CALLBACK(on_recordings_choose), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(ui.recordings_choose));
    ui.recordings_default = GTK_BUTTON(gtk_button_new_with_mnemonic("Use _default"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_default), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_default, "clicked", G_CALLBACK(on_recordings_default), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(ui.recordings_default));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), location);
    GtkWidget *cleanup = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cleanup), "Saved recordings");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(cleanup), "Delete saved audio without removing History entries.");
    ui.audio_cleanup = GTK_BUTTON(gtk_button_new_with_mnemonic("Delete _audio…"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.audio_cleanup), "destructive-action");
    gtk_widget_set_valign(GTK_WIDGET(ui.audio_cleanup), GTK_ALIGN_CENTER);
    g_signal_connect(ui.audio_cleanup, "clicked", G_CALLBACK(on_audio_cleanup), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(cleanup), GTK_WIDGET(ui.audio_cleanup));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), cleanup);
    gtk_box_append(GTK_BOX(column), housekeeping);
    GtkWidget *backup = group("Data backup");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(backup),
        "Save History text with optional saved audio and app profiles in a ZIP backup. "
        "ZIPs are not encrypted. Settings and credentials are not included; existing files are never replaced.");
    ui.backup_audio = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.backup_audio), "Include saved recording audio");
    adw_switch_row_set_active(ui.backup_audio, TRUE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(ui.backup_audio));
    ui.backup_profiles = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.backup_profiles), "Include app profiles");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.backup_profiles), "Includes per-app overrides and prompts.");
    adw_switch_row_set_active(ui.backup_profiles, FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(ui.backup_profiles));
    GtkWidget *backup_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(backup_row), "Save a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(backup_row),
        "Turn off both optional categories for a History-only backup.");
    ui.backup_export = GTK_BUTTON(gtk_button_new_with_mnemonic("Save _backup…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.backup_export), GTK_ALIGN_CENTER);
    g_signal_connect(ui.backup_export, "clicked", G_CALLBACK(on_backup), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(backup_row), GTK_WIDGET(ui.backup_export));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), backup_row);
    GtkWidget *inspect_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(inspect_row), "Inspect a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(inspect_row),
        "Review categories and archive notices without importing any data.");
    ui.backup_inspect = GTK_BUTTON(gtk_button_new_with_mnemonic("_Inspect…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.backup_inspect), GTK_ALIGN_CENTER);
    g_signal_connect(ui.backup_inspect, "clicked", G_CALLBACK(on_backup), GINT_TO_POINTER(1));
    adw_action_row_add_suffix(ADW_ACTION_ROW(inspect_row), GTK_WIDGET(ui.backup_inspect));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), inspect_row);
    GtkWidget *restore_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(restore_row), "Restore a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(restore_row),
        "Preview and confirm History text and app profiles. Settings, audio and credentials stay unchanged.");
    ui.backup_restore = GTK_BUTTON(gtk_button_new_with_mnemonic("_Restore..."));
    gtk_widget_set_valign(GTK_WIDGET(ui.backup_restore), GTK_ALIGN_CENTER);
    g_signal_connect(ui.backup_restore, "clicked", G_CALLBACK(on_backup), GINT_TO_POINTER(2));
    adw_action_row_add_suffix(ADW_ACTION_ROW(restore_row), GTK_WIDGET(ui.backup_restore));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), restore_row);
    gtk_box_append(GTK_BOX(column), backup);
    return page;
}

static void open_comparison(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.state == JSTI_STATE_IDLE) jsti_comparison_open(ui.window);
}

GtkWidget *build_transcription(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[1] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Transcription", "Pick the speech model for new recordings, on this computer or with your own provider key."));
    GtkWidget *models = group("Model");
    jsti_model_filters_add(models, on_model_filter);
    ui.model_names = gtk_string_list_new(NULL);
    ui.model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.model_row), "Transcription model");
    adw_combo_row_set_model(ui.model_row, G_LIST_MODEL(ui.model_names));
    adw_combo_row_set_enable_search(ui.model_row, TRUE);
    g_signal_connect(ui.model_row, "notify::selected", G_CALLBACK(on_model), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.model_row));

    ui.key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.key_row), "API key for the selected provider");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(ui.key_row), TRUE);
    g_signal_connect(ui.key_row, "apply", G_CALLBACK(on_key_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.key_row));

    /* Recorded audio falls back to the key's region; live Azure needs this. */
    ui.azure_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.azure_row),
                                  "Azure Speech resource endpoint (https://…cognitiveservices.azure.com)");
    adw_entry_row_set_show_apply_button(ui.azure_row, TRUE);
    adw_entry_row_set_input_purpose(ui.azure_row, GTK_INPUT_PURPOSE_URL);
    g_signal_connect(ui.azure_row, "apply", G_CALLBACK(on_azure_apply), NULL);
    gtk_widget_set_visible(GTK_WIDGET(ui.azure_row), FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.azure_row));

    GtkWidget *catalog = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(catalog, 8);
    ui.catalog_status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(ui.catalog_status, TRUE);
    gtk_label_set_xalign(ui.catalog_status, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(ui.catalog_status), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(ui.catalog_status), "dim-label");
    ui.catalog_refresh = GTK_BUTTON(gtk_button_new_with_label("Refresh models"));
    g_signal_connect(ui.catalog_refresh, "clicked", G_CALLBACK(on_refresh), NULL);
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_status));
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_refresh));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), catalog);
    gtk_box_append(GTK_BOX(column), models);
    gtk_box_append(GTK_BOX(column), jsti_local_models_group_new());
    GtkWidget *comparison = group("Compare Models");
    GtkWidget *compare = gtk_button_new_with_label("Compare Models…");
    g_signal_connect(compare, "clicked", G_CALLBACK(open_comparison), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(comparison), compare);
    gtk_box_append(GTK_BOX(column), comparison);
    return page;
}

GtkWidget *build_post_processing(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[2] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Post-processing", "Clean up transcripts locally or through OpenRouter. The original is always kept."));
    GtkWidget *polish = group("Clean-up");
    ui.polish_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_row), "Enable post-processing");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_row));
    ui.polish_location_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_location_row), "Model source");
    const char *locations[] = {"Local", "Remote", "Choose a source…", NULL};
    GtkStringList *location_names = gtk_string_list_new(locations);
    adw_combo_row_set_model(ui.polish_location_row, G_LIST_MODEL(location_names));
    g_object_unref(location_names);
    adw_combo_row_set_selected(ui.polish_location_row, 2);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_location_row));
    AdwActionRow *mode = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(mode), "Finished-transcript cleanup");
    adw_action_row_set_subtitle(mode,
        "Remote cleanup can stream previews when enabled in preferences. Local cleanup completes in one step.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(mode));
    ui.polish_models = gtk_string_list_new(NULL);
    ui.polish_slots = g_array_new(FALSE, FALSE, sizeof(gint32));
    ui.polish_local_index = -1;
    ui.polish_remote_selected = -1;
    ui.polish_local_selected = -1;
    ui.polish_model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_model_row), "Polishing model");
    adw_combo_row_set_model(ui.polish_model_row, G_LIST_MODEL(ui.polish_models));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_model_row));
    ui.polish_directives_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_directives_row), "Include personal lexicon directives");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_directives_row),
        "Use saved spelling and name instructions with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_directives_row));
    ui.polish_tags_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_tags_row), "Include lexicon context tags");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_tags_row),
        "Use saved context tags with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_tags_row));
    GtkWidget *prompt_label = gtk_label_new("Custom system instructions (optional)");
    gtk_label_set_xalign(GTK_LABEL(prompt_label), 0);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_label);
    ui.polish_prompt_row = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(ui.polish_prompt_row, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_top_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_bottom_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_left_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_right_margin(ui.polish_prompt_row, 10);
    gtk_accessible_update_property(GTK_ACCESSIBLE(ui.polish_prompt_row),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Custom system instructions", -1);
    GtkWidget *prompt_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(prompt_scroll), 140);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(prompt_scroll), GTK_WIDGET(ui.polish_prompt_row));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_scroll);
    ui.polish_key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_key_row), "New OpenRouter key (leave empty to keep)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_key_row));
    g_signal_connect(ui.polish_location_row, "notify::selected", G_CALLBACK(on_polish_location), NULL);
    g_signal_connect(ui.polish_model_row, "notify::selected", G_CALLBACK(on_polish_model), NULL);
    GtkWidget *polish_apply = gtk_button_new_with_label("Apply");
    gtk_widget_add_css_class(polish_apply, "suggested-action");
    gtk_widget_set_halign(polish_apply, GTK_ALIGN_END);
    gtk_widget_set_margin_top(polish_apply, 8);
    g_signal_connect(polish_apply, "clicked", G_CALLBACK(on_polish_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), polish_apply);
    gtk_box_append(GTK_BOX(column), polish);
    polish_local_group = jsti_local_cleanup_group_new();
    gtk_widget_set_visible(polish_local_group, FALSE);
    gtk_box_append(GTK_BOX(column), polish_local_group);
    return page;
}

GtkWidget *build_keyboard(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[3] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Keyboard", "Start and stop dictation from anywhere with a global shortcut."));
    GtkWidget *shortcut = group("Shortcut");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(shortcut),
        "Where the desktop offers no shortcut portal, bind the command justspeaktoit --toggle to a key in your "
        "desktop's keyboard settings. With the app already running, --speak-clipboard reads clipboard text aloud "
        "and --paste-last-history delivers the newest History text without raising this window. "
        "The running app also accepts --stop-speech, --pause-resume-speech and --quick-voice-1 "
        "(or --quick-voice-2 / --quick-voice-3).");
    ui.shortcut_row = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.shortcut_row), "Keyboard shortcut");
    adw_action_row_set_subtitle(ui.shortcut_row, "Checking the desktop…");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(ui.shortcut_row));
    const char *styles[] = { "Press to toggle", "Hold to record", "Double-tap to toggle",
                             "Hold, or double-tap to toggle", NULL };
    ui.style_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.style_row), "Activation");
    adw_combo_row_set_model(ui.style_row, G_LIST_MODEL(gtk_string_list_new(styles)));
    g_signal_connect(ui.style_row, "notify::selected", G_CALLBACK(on_style), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(ui.style_row));
    gtk_box_append(GTK_BOX(column), shortcut);
    gtk_box_append(GTK_BOX(column), jsti_action_shortcuts_group_new(ui.window));
    return page;
}

GtkWidget *build_cloud_sync(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "iCloud Sync", "Keep History in step with your Mac, through your own iCloud account."));
    gtk_box_append(GTK_BOX(column), jsti_cloud_sync_group_new());
    return page;
}

static void open_link_finished(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        g_warning("Could not open the browser: %s", error->message);
        if (ui.window != NULL && !ui.closing) {
            gtk_label_set_text(ui.status, "Could not open your browser. Check your default browser settings.");
        }
        g_error_free(error);
    }
}

static void open_link(GtkButton *button, gpointer data) {
    (void)button;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(data);
    gtk_uri_launcher_launch(launcher, ui.window, NULL, open_link_finished, NULL);
    g_object_unref(launcher);
}

GtkWidget *link_button(const char *label, const char *uri) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_object_set_data_full(G_OBJECT(button), "about-uri", g_strdup(uri), g_free);
    gtk_widget_set_tooltip_text(button, uri);
    g_signal_connect(button, "clicked", G_CALLBACK(open_link), g_object_get_data(G_OBJECT(button), "about-uri"));
    return button;
}

static void on_troubleshooting(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_troubleshooting_open(ui.window);
}

static void on_permissions(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_permissions_open(ui.window);
}

static void on_setup(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (!ui.closing) jsti_setup_open(ui.window);
}

static void request_setup(gpointer data) { (void)data; on_setup(NULL, NULL); }
int32_t jsti_window_request_setup(void) { return jsti_window_post(request_setup, NULL, NULL); }

static void request_permissions(gpointer data) {
    (void)data;
    if (!ui.closing) jsti_permissions_open(ui.window);
}

int32_t jsti_window_request_permissions(void) { return jsti_window_post(request_permissions, NULL, NULL); }

static void request_api_keys(gpointer data) {
    (void)data;
    if (!ui.closing && ui.state == JSTI_STATE_IDLE) jsti_api_keys_open(ui.window);
    else (void)jsti_window_update("Finish the current operation before opening API Keys.", NULL, -1);
}

int32_t jsti_window_request_api_keys(void) { return jsti_window_post(request_api_keys, NULL, NULL); }

gboolean action_shortcut_run(gint run, const char *page, gint slot) {
    if (ui.closing || !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    switch (run) {
    case 1:
        if (!gtk_widget_is_sensitive(GTK_WIDGET(ui.record))) return FALSE;
        on_record(NULL, NULL);
        return TRUE;
    case 2:
        for (gint index = 0; page != NULL && index < JSTI_PAGE_COUNT; ++index) {
            GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, index));
            if (g_strcmp0(page_info[index].name, page) != 0) continue;
            if (!gtk_widget_is_sensitive(row) || !gtk_widget_get_visible(row)) return FALSE;
            show_page(index);
            return TRUE;
        }
        return FALSE;
    case 3:
        if (!gtk_widget_is_sensitive(GTK_WIDGET(ui.voice_stop))) return FALSE;
        on_stop_play(NULL, NULL);
        return TRUE;
    case 4: on_troubleshooting(NULL, NULL); return TRUE;
    case 5:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        open_comparison(NULL, NULL);
        return TRUE;
    case 6:
        if (ui.state != JSTI_STATE_IDLE || slot < 1 || slot > 3) return FALSE;
        emit(JSTI_EVENT_QUICK_VOICE, "", slot);
        return TRUE;
    case 7:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_CLIPBOARD, "", 0);
        return TRUE;
    case 8:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEECH_PAUSE, "", 0);
        return TRUE;
    case 9:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_API_KEYS, "", 0);
        return TRUE;
    case 10:
        emit(JSTI_EVENT_PERMISSIONS, "", 0);
        return TRUE;
    case 11:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_PASTE_LAST_HISTORY, "", 0);
        return TRUE;
    case 12:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_SELECTED_TEXT, "", 0);
        return TRUE;
    default: return FALSE;
    }
}

GtkWidget *build_about(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("help-about-symbolic", "About", &body);
    GtkWidget *identity = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 18);
    gtk_box_append(GTK_BOX(identity), jsti_brand_icon_new(72));
    GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
    GtkWidget *name = gtk_label_new("Just Speak to It");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_widget_add_css_class(name, "jsti-about-name");
    gtk_box_append(GTK_BOX(names), name);
    GtkWidget *tagline = gtk_label_new("Voice-to-text made simple. Linux developer preview.");
    gtk_label_set_xalign(GTK_LABEL(tagline), 0);
    gtk_widget_add_css_class(tagline, "dim-label");
    gtk_box_append(GTK_BOX(names), tagline);
    gtk_box_append(GTK_BOX(identity), names);
    gtk_box_append(GTK_BOX(body), identity);
    GtkWidget *note = gtk_label_new(
        "Open source under the MIT licence. Your audio goes only to the provider you choose, or stays on this "
        "computer with an on-device model.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_box_append(GTK_BOX(body), note);
    ui.about_details = GTK_LABEL(gtk_label_new("Build metadata has not been supplied by this host."));
    gtk_label_set_xalign(ui.about_details, 0);
    gtk_label_set_selectable(ui.about_details, TRUE);
    gtk_label_set_wrap(ui.about_details, TRUE);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(ui.about_details));
    ui.about_links = GTK_FLOW_BOX(gtk_flow_box_new());
    gtk_flow_box_set_selection_mode(ui.about_links, GTK_SELECTION_NONE);
    gtk_flow_box_set_min_children_per_line(ui.about_links, 1);
    gtk_flow_box_set_max_children_per_line(ui.about_links, 3);
    gtk_flow_box_set_row_spacing(ui.about_links, 8);
    gtk_flow_box_set_column_spacing(ui.about_links, 8);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(ui.about_links));
    GtkWidget *troubleshooting = gtk_button_new_with_mnemonic("_Troubleshooting");
    gtk_widget_set_halign(troubleshooting, GTK_ALIGN_START);
    g_signal_connect(troubleshooting, "clicked", G_CALLBACK(on_troubleshooting), NULL);
    gtk_box_append(GTK_BOX(body), troubleshooting);
    GtkWidget *permissions = gtk_button_new_with_mnemonic("_Permissions");
    gtk_widget_set_size_request(permissions, -1, 44);
    gtk_widget_set_halign(permissions, GTK_ALIGN_START);
    g_signal_connect(permissions, "clicked", G_CALLBACK(on_permissions), NULL);
    GtkWidget *setup = gtk_button_new_with_label("Run setup again");
    gtk_widget_set_size_request(setup, -1, 44);
    gtk_widget_set_halign(setup, GTK_ALIGN_START);
    g_signal_connect(setup, "clicked", G_CALLBACK(on_setup), NULL);
    gtk_box_append(GTK_BOX(body), setup);
    gtk_box_append(GTK_BOX(body), permissions);
    gtk_box_append(GTK_BOX(column), card);
    return page;
}
