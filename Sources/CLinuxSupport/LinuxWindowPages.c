/* Page builders: shared page scaffolding, Dashboard and History. */
#include "LinuxWindowInternal.h"

/* --------------------------------------------------------------- layout */

GtkWidget *group(const char *title) {
    GtkWidget *widget = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(widget), title);
    return widget;
}

/* The voice Read aloud uses; the list comes from jsti_window_set_voices. */
GtkWidget *read_aloud_group(void) {
    GtkWidget *widget = group("Voice");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(widget),
        "Read aloud sends the displayed History transcript to the selected voice provider using its saved key. "
        "Play, Pause and Stop control playback.");
    read_aloud.voices = gtk_string_list_new(NULL);
    read_aloud.voice_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(read_aloud.voice_row), "Voice");
    adw_combo_row_set_model(read_aloud.voice_row, G_LIST_MODEL(read_aloud.voices));
    adw_combo_row_set_enable_search(read_aloud.voice_row, TRUE);
    g_signal_connect(read_aloud.voice_row, "notify::selected", G_CALLBACK(on_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), GTK_WIDGET(read_aloud.voice_row));
    read_aloud.favorite_names = gtk_string_list_new(NULL);
    read_aloud.favorite_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(read_aloud.favorite_row), "Favorites");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(read_aloud.favorite_row),
        "Choose a saved voice. Unavailable saved IDs are retained, not substituted.");
    adw_combo_row_set_model(read_aloud.favorite_row, G_LIST_MODEL(read_aloud.favorite_names));
    adw_combo_row_set_enable_search(read_aloud.favorite_row, TRUE);
    g_signal_connect(read_aloud.favorite_row, "notify::selected", G_CALLBACK(on_favorite_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), GTK_WIDGET(read_aloud.favorite_row));
    GtkWidget *favorite_action = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(favorite_action), "Favorite selected voice");
    read_aloud.favorite_button = GTK_BUTTON(gtk_button_new_with_label("Add to favorites"));
    gtk_widget_set_valign(GTK_WIDGET(read_aloud.favorite_button), GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(GTK_WIDGET(read_aloud.favorite_button), -1, 36);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), FALSE);
    g_signal_connect(read_aloud.favorite_button, "clicked", G_CALLBACK(on_favorite_toggle), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(favorite_action), GTK_WIDGET(read_aloud.favorite_button));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), favorite_action);
    return widget;
}

GtkWidget *settings_hero(const char *title, const char *subtitle) {
    return jsti_hero_new("settings", title, subtitle, NULL, NULL);
}

void add_page(gint32 page, GtkWidget *widget) {
    gtk_stack_add_named(ui.pages, widget, page_info[page].name);
}

static GtkWidget *transcript_view(GtkTextBuffer *buffer, int height) {
    GtkWidget *view = buffer != NULL ? gtk_text_view_new_with_buffer(buffer) : gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 4);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(view), 4);
    gtk_widget_add_css_class(view, "jsti-transcript");
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroller), height);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroller), height * 3);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroller), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), view);
    gtk_widget_add_css_class(scroller, "jsti-transcript-box");
    return scroller;
}

static GtkWidget *setup_tile(const char *icon, const char *title, GtkLabel **detail) {
    GtkWidget *tile = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(tile, "jsti-setup-tile");
    GtkWidget *image = gtk_image_new_from_icon_name(icon);
    gtk_image_set_pixel_size(GTK_IMAGE(image), 18);
    gtk_widget_add_css_class(image, "jsti-tint-accent");
    gtk_widget_set_valign(image, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(tile), image);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *heading = gtk_label_new(title);
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_widget_add_css_class(heading, "jsti-setup-title");
    gtk_box_append(GTK_BOX(text), heading);
    GtkWidget *value = gtk_label_new("—");
    gtk_label_set_xalign(GTK_LABEL(value), 0);
    gtk_label_set_wrap(GTK_LABEL(value), TRUE);
    gtk_widget_add_css_class(value, "jsti-setup-detail");
    gtk_box_append(GTK_BOX(text), value);
    gtk_box_append(GTK_BOX(tile), text);
    *detail = GTK_LABEL(value);
    return tile;
}

/* Side by side, or stacked when the window is narrow (see build_window). */
GtkWidget *columns;

/* Stack hero actions before their labels force the page wider than its viewport.
 * Breakpoint setters restore the desktop arrangement when space is available. */
void add_compact_hero_setters(AdwBreakpoint *breakpoint, GtkWidget *widget) {
    if (gtk_widget_has_css_class(widget, "jsti-hero-header")) {
        GValue orientation = G_VALUE_INIT;
        g_value_init(&orientation, GTK_TYPE_ORIENTATION);
        g_value_set_enum(&orientation, GTK_ORIENTATION_VERTICAL);
        adw_breakpoint_add_setter(breakpoint, G_OBJECT(widget), "orientation", &orientation);
        g_value_unset(&orientation);
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) add_compact_hero_setters(breakpoint, child);
}

static GtkWidget *two_columns(GtkWidget *first, GtkWidget *second) {
    columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 20);
    gtk_box_set_homogeneous(GTK_BOX(columns), TRUE);
    gtk_widget_set_valign(first, GTK_ALIGN_START);
    gtk_widget_set_valign(second, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(columns), first);
    gtk_box_append(GTK_BOX(columns), second);
    return columns;
}

static GtkWidget *grid_of(GtkWidget *const *items, int count) {
    GtkWidget *flow = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(flow), TRUE);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(flow), 1);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 2);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow), 10);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow), 10);
    for (int index = 0; index < count; index++) gtk_flow_box_append(GTK_FLOW_BOX(flow), items[index]);
    for (GtkWidget *child = gtk_widget_get_first_child(flow); child != NULL; child = gtk_widget_get_next_sibling(child)) {
        gtk_widget_set_focusable(child, FALSE);
    }
    return flow;
}

static void transcript_placeholder_changed(GtkTextBuffer *buffer, GtkWidget *placeholder) {
    gtk_widget_set_visible(placeholder, gtk_text_buffer_get_char_count(buffer) == 0);
}

GtkWidget *build_dashboard(GtkTextBuffer *buffer) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *chips, *trailing;
    GtkWidget *hero = jsti_hero_new(
        NULL, "Ready when you are",
        "Turn a thought into text. Record, review, and use it anywhere.",
        &chips, &trailing);
    ui.record = GTK_BUTTON(gtk_button_new_with_label("Start Recording"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.record), "jsti-record-hero");
    g_signal_connect(ui.record, "clicked", G_CALLBACK(on_record), NULL);
    gtk_box_append(GTK_BOX(trailing), GTK_WIDGET(ui.record));
    ui.live_preview = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_xalign(ui.live_preview, 0);
    gtk_label_set_wrap(ui.live_preview, TRUE);
    gtk_label_set_lines(ui.live_preview, 3);
    gtk_label_set_ellipsize(ui.live_preview, PANGO_ELLIPSIZE_START);
    gtk_widget_add_css_class(GTK_WIDGET(ui.live_preview), "jsti-live-preview");
    gtk_widget_set_visible(GTK_WIDGET(ui.live_preview), FALSE);
    gtk_box_insert_child_after(GTK_BOX(hero), GTK_WIDGET(ui.live_preview), gtk_widget_get_first_child(hero));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Sessions", &ui.hero_sessions));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Recording Time", &ui.hero_time));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Spend", &ui.hero_spend));
    gtk_box_append(GTK_BOX(column), hero);

    GtkWidget *body;
    GtkWidget *transcript = jsti_card_new("document-edit-symbolic", "Transcript", &body);
    GtkWidget *preview = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(preview), transcript_view(buffer, 96));
    GtkWidget *placeholder = gtk_label_new("Your words will appear here.");
    gtk_widget_add_css_class(placeholder, "jsti-empty");
    gtk_label_set_wrap(GTK_LABEL(placeholder), TRUE);
    gtk_widget_set_can_target(placeholder, FALSE);
    gtk_overlay_add_overlay(GTK_OVERLAY(preview), placeholder);
    g_signal_connect_object(buffer, "changed", G_CALLBACK(transcript_placeholder_changed), placeholder, 0);
    transcript_placeholder_changed(buffer, placeholder);
    gtk_box_append(GTK_BOX(body), preview);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    ui.cancel = GTK_BUTTON(gtk_button_new_with_label("Cancel"));
    g_signal_connect(ui.cancel, "clicked", G_CALLBACK(on_cancel), NULL);
    ui.dashboard_copy = GTK_BUTTON(gtk_button_new_with_label("Copy"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.dashboard_copy), "suggested-action");
    g_signal_connect(ui.dashboard_copy, "clicked", G_CALLBACK(on_copy), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.cancel));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.dashboard_copy));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), transcript);

    GtkWidget *insights_body;
    GtkWidget *insights = jsti_card_new("power-profile-performance-symbolic", "Insights", &insights_body);
    GtkWidget *stats[] = {
        jsti_stat_new("Sessions", &ui.insight_sessions), jsti_stat_new("Recording Time", &ui.insight_time),
        jsti_stat_new("Average Length", &ui.insight_average), jsti_stat_new("Spend", &ui.insight_spend),
    };
    gtk_box_append(GTK_BOX(insights_body), grid_of(stats, G_N_ELEMENTS(stats)));
    GtkWidget *setup_body;
    GtkWidget *setup = jsti_card_new("emblem-system-symbolic", "Setup", &setup_body);
    gtk_box_append(GTK_BOX(setup_body), setup_tile("audio-input-microphone-symbolic", "Microphone", &ui.setup_microphone));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("document-edit-symbolic", "Transcription model", &ui.setup_model));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("input-keyboard-symbolic", "Keyboard shortcut", &ui.setup_shortcut));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("edit-paste-symbolic", "Text output", &ui.setup_output));
    gtk_box_append(GTK_BOX(column), two_columns(insights, setup));
    return page;
}

static void history_delete_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    const char *identifiers = g_object_get_data(G_OBJECT(dialog), "jsti-history-delete-ids");
    if (g_strcmp0(response, "keep-audio") == 0 || g_strcmp0(response, "delete-audio") == 0) {
        emit(JSTI_EVENT_HISTORY_DELETE, identifiers, g_strcmp0(response, "delete-audio") == 0 ? 1 : 0);
    }
    gtk_window_destroy(GTK_WINDOW(dialog));
}

GtkWidget *history_delete_dialog(const char *identifiers, gboolean clear) {
    guint count = 1;
    for (const char *cursor = identifiers; *cursor != '\0'; cursor++) if (*cursor == '\n') count++;
    gchar *body = clear ? g_strdup_printf(
        "Remove all %u History entries, including hidden and filtered entries? "
        "You can keep their saved audio or delete owned recording files too. "
        "This cannot be undone. If History sync is enabled, synced text will also be deleted.", count)
        : g_strdup("Remove this History entry? Its saved audio will be kept. "
                   "This cannot be undone. If History sync is enabled, its synced text will also be deleted.");
    GtkWidget *dialog = adw_message_dialog_new(ui.window, clear ? "Clear History?" : "Delete History entry?", body);
    g_free(body);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    g_object_set_data_full(G_OBJECT(dialog), "jsti-history-delete-ids", g_strdup(identifiers), g_free);
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog),
        "cancel", "Cancel", "keep-audio", clear ? "Clear History" : "Delete entry", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "keep-audio", ADW_RESPONSE_DESTRUCTIVE);
    if (clear) {
        adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "delete-audio", "Clear History and recordings");
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete-audio", ADW_RESPONSE_DESTRUCTIVE);
    }
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    g_signal_connect(dialog, "response", G_CALLBACK(history_delete_response), NULL);
    return dialog;
}

static void on_history_delete(GtkButton *button, gpointer data) {
    (void)data;
    gboolean clear = button == ui.history_clear;
    const char *identifiers = clear ? ui.all_history_ids : ui.selected_id;
    if (ui.state != 0 || identifiers == NULL || identifiers[0] == '\0') return;
    gtk_window_present(GTK_WINDOW(history_delete_dialog(identifiers, clear)));
}

GtkWidget *build_history(GtkTextBuffer *buffer) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *chips, *trailing;
    GtkWidget *hero = jsti_hero_new(
        NULL, "Session History", "Search, replay and reuse past recordings and their transcripts.", &chips,
        &trailing);
    ui.history_import = GTK_BUTTON(gtk_button_new_with_label("Import…"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.history_import), "jsti-hero-button");
    g_signal_connect(ui.history_import, "clicked", G_CALLBACK(on_import), NULL);
    gtk_box_append(GTK_BOX(trailing), GTK_WIDGET(ui.history_import));
    ui.history_clear = GTK_BUTTON(gtk_button_new_with_label("Clear History…"));
    g_signal_connect(ui.history_clear, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_prepend(GTK_BOX(trailing), GTK_WIDGET(ui.history_clear));
    ui.history_filters = jsti_history_filters_button_new();
    gtk_box_prepend(GTK_BOX(trailing), ui.history_filters);
    ui.search = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    gtk_search_entry_set_placeholder_text(ui.search, "Search transcripts, models and profiles");
    g_signal_connect(ui.search, "search-changed", G_CALLBACK(on_search), NULL);
    gtk_box_insert_child_after(GTK_BOX(hero), GTK_WIDGET(ui.search), gtk_widget_get_first_child(hero));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Sessions", &ui.history_sessions));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Errors", &ui.history_errors));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Average Length", &ui.history_average));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Spend", &ui.history_spend));
    gtk_box_append(GTK_BOX(column), hero);

    ui.history = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(ui.history), "jsti-history");
    gtk_list_box_set_selection_mode(ui.history, GTK_SELECTION_SINGLE);
    g_signal_connect(ui.history, "row-selected", G_CALLBACK(on_history_selected), NULL);
    ui.history_ids = g_ptr_array_new_with_free_func(g_free);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.history));
    ui.history_empty = gtk_label_new("No history yet. Press Record to capture your first session.");
    gtk_widget_add_css_class(ui.history_empty, "jsti-empty");
    gtk_box_append(GTK_BOX(column), ui.history_empty);

    /* The detail moved into the selected card. */
    ui.detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    g_object_ref_sink(ui.detail);
    gtk_box_append(GTK_BOX(ui.detail), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *label = gtk_label_new("Transcript");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_widget_add_css_class(label, "jsti-detail-heading");
    gtk_box_append(GTK_BOX(heading), label);
    const char *versions[] = { "Processed", "Original", NULL };
    ui.version = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(versions));
    gtk_widget_set_tooltip_text(GTK_WIDGET(ui.version), "Transcript version");
    g_signal_connect(ui.version, "notify::selected", G_CALLBACK(on_version), NULL);
    gtk_box_append(GTK_BOX(heading), GTK_WIDGET(ui.version));
    gtk_box_append(GTK_BOX(ui.detail), heading);
    GtkWidget *scroller = transcript_view(buffer, 72);
    ui.transcript = GTK_TEXT_VIEW(gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scroller)));
    gtk_box_append(GTK_BOX(ui.detail), scroller);

    GtkWidget *playback = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    ui.play = GTK_BUTTON(gtk_button_new_with_label("Play"));
    ui.stop_play = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(ui.play, "clicked", G_CALLBACK(on_play), NULL);
    g_signal_connect(ui.stop_play, "clicked", G_CALLBACK(on_stop_play), NULL);
    ui.playback_label = GTK_LABEL(gtk_label_new(""));
    gtk_widget_add_css_class(GTK_WIDGET(ui.playback_label), "dim-label");
    gtk_widget_add_css_class(GTK_WIDGET(ui.playback_label), "numeric");
    gtk_widget_set_hexpand(GTK_WIDGET(ui.playback_label), TRUE);
    gtk_label_set_xalign(ui.playback_label, 0);
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.stop_play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.playback_label));
    ui.copy = GTK_BUTTON(gtk_button_new_with_label("Copy"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.copy), "suggested-action");
    g_signal_connect(ui.copy, "clicked", G_CALLBACK(on_copy), NULL);
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.copy));
    gtk_box_append(GTK_BOX(ui.detail), playback);

    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    read_aloud.button = GTK_BUTTON(gtk_button_new_with_label("Read aloud"));
    g_signal_connect(read_aloud.button, "clicked", G_CALLBACK(on_read_aloud), NULL);
    ui.retry = GTK_BUTTON(gtk_button_new_with_label("Retry"));
    ui.export_button = GTK_BUTTON(gtk_button_new_with_label("Export…"));
    ui.issue_button = GTK_BUTTON(gtk_button_new_with_label("Create Issue with Details…"));
    g_signal_connect(ui.issue_button, "clicked", G_CALLBACK(on_issue_report), NULL);
    ui.open_audio = GTK_BUTTON(gtk_button_new_with_label("Open audio"));
    g_signal_connect(ui.retry, "clicked", G_CALLBACK(on_retry), NULL);
    g_signal_connect(ui.export_button, "clicked", G_CALLBACK(on_export), NULL);
    g_signal_connect(ui.open_audio, "clicked", G_CALLBACK(on_open_audio), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(read_aloud.button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.retry));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.export_button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.open_audio));
    gtk_box_append(GTK_BOX(ui.detail), actions);
    gtk_widget_set_halign(GTK_WIDGET(ui.issue_button), GTK_ALIGN_END);
    gtk_widget_set_size_request(GTK_WIDGET(ui.issue_button), -1, 44);
    gtk_box_append(GTK_BOX(ui.detail), GTK_WIDGET(ui.issue_button));
    GtkWidget *management = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(management, GTK_ALIGN_END);
    ui.correction_results = GTK_BUTTON(gtk_button_new_with_label("Correction results"));
    g_signal_connect(ui.correction_results, "clicked", G_CALLBACK(on_correction_results), NULL);
    ui.history_delete = GTK_BUTTON(gtk_button_new_with_label("Delete…"));
    g_signal_connect(ui.history_delete, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(ui.correction_results));
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(ui.history_delete));
    gtk_box_append(GTK_BOX(ui.detail), management);
    return page;
}
