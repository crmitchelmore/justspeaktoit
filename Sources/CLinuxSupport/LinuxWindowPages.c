/* Page builders: shared page scaffolding and the Dashboard. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowDashboardPage.h"

static DashboardPage dashboard_state;
DashboardPage *dashboard_page(void) { return &dashboard_state; }

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

GtkWidget *transcript_view(GtkTextBuffer *buffer, int height) {
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
    dashboard_page()->columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 20);
    gtk_box_set_homogeneous(GTK_BOX(dashboard_page()->columns), TRUE);
    gtk_widget_set_valign(first, GTK_ALIGN_START);
    gtk_widget_set_valign(second, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(dashboard_page()->columns), first);
    gtk_box_append(GTK_BOX(dashboard_page()->columns), second);
    return dashboard_page()->columns;
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
    dashboard_page()->record = GTK_BUTTON(gtk_button_new_with_label("Start Recording"));
    gtk_widget_add_css_class(GTK_WIDGET(dashboard_page()->record), "jsti-record-hero");
    g_signal_connect(dashboard_page()->record, "clicked", G_CALLBACK(on_record), NULL);
    gtk_box_append(GTK_BOX(trailing), GTK_WIDGET(dashboard_page()->record));
    dashboard_page()->live_preview = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_xalign(dashboard_page()->live_preview, 0);
    gtk_label_set_wrap(dashboard_page()->live_preview, TRUE);
    gtk_label_set_lines(dashboard_page()->live_preview, 3);
    gtk_label_set_ellipsize(dashboard_page()->live_preview, PANGO_ELLIPSIZE_START);
    gtk_widget_add_css_class(GTK_WIDGET(dashboard_page()->live_preview), "jsti-live-preview");
    gtk_widget_set_visible(GTK_WIDGET(dashboard_page()->live_preview), FALSE);
    gtk_box_insert_child_after(GTK_BOX(hero), GTK_WIDGET(dashboard_page()->live_preview), gtk_widget_get_first_child(hero));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Sessions", &dashboard_page()->hero_sessions));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Recording Time", &dashboard_page()->hero_time));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Spend", &dashboard_page()->hero_spend));
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
    dashboard_page()->cancel = GTK_BUTTON(gtk_button_new_with_label("Cancel"));
    g_signal_connect(dashboard_page()->cancel, "clicked", G_CALLBACK(on_cancel), NULL);
    dashboard_page()->dashboard_copy = GTK_BUTTON(gtk_button_new_with_label("Copy"));
    gtk_widget_add_css_class(GTK_WIDGET(dashboard_page()->dashboard_copy), "suggested-action");
    g_signal_connect(dashboard_page()->dashboard_copy, "clicked", G_CALLBACK(on_copy), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dashboard_page()->cancel));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(dashboard_page()->dashboard_copy));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), transcript);

    GtkWidget *insights_body;
    GtkWidget *insights = jsti_card_new("power-profile-performance-symbolic", "Insights", &insights_body);
    GtkWidget *stats[] = {
        jsti_stat_new("Sessions", &dashboard_page()->insight_sessions), jsti_stat_new("Recording Time", &dashboard_page()->insight_time),
        jsti_stat_new("Average Length", &dashboard_page()->insight_average), jsti_stat_new("Spend", &dashboard_page()->insight_spend),
    };
    gtk_box_append(GTK_BOX(insights_body), grid_of(stats, G_N_ELEMENTS(stats)));
    GtkWidget *setup_body;
    GtkWidget *setup = jsti_card_new("emblem-system-symbolic", "Setup", &setup_body);
    gtk_box_append(GTK_BOX(setup_body), setup_tile("audio-input-microphone-symbolic", "Microphone", &dashboard_page()->setup_microphone));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("document-edit-symbolic", "Transcription model", &dashboard_page()->setup_model));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("input-keyboard-symbolic", "Keyboard shortcut", &dashboard_page()->setup_shortcut));
    gtk_box_append(GTK_BOX(setup_body), setup_tile("edit-paste-symbolic", "Text output", &dashboard_page()->setup_output));
    gtk_box_append(GTK_BOX(column), two_columns(insights, setup));
    return page;
}
