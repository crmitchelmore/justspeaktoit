/* Page builders: shared page scaffolding and the Dashboard, which owns
 * DashboardPage (LinuxWindowDashboardState.h). */
#include "LinuxWindowDashboardState.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowModelsPage.h"
#include "LinuxWindowOutputPage.h"

static DashboardPage dashboard_state;
DashboardPage *dashboard_page(void) { return &dashboard_state; }

/* --------------------------------------------------------------- layout */

GtkWidget *group(const char *title) {
    GtkWidget *widget = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(widget), title);
    return widget;
}

const char *combo_row_text(AdwComboRow *row) {
    GObject *item = adw_combo_row_get_selected_item(row);
    return item != NULL ? gtk_string_object_get_string(GTK_STRING_OBJECT(item)) : NULL;
}

GtkWidget *settings_hero(const char *title, const char *subtitle) {
    return jsti_hero_new("settings", title, subtitle, NULL, NULL);
}

void add_page(gint32 page, GtkWidget *widget) {
    gtk_stack_add_named(ui.pages, widget, page_name(page));
}

GtkWidget *transcript_view(GtkTextBuffer *buffer, int height) {
    GtkWidget *view = buffer != NULL ? gtk_text_view_new_with_buffer(buffer) : gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 4);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(view), 4);
    gtk_widget_add_css_class(view, "jsti-transcript");
    jsti_accessible_set_name(view, "Transcript");
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
    /* The items are read-only. Marking each GtkFlowBoxChild unfocusable is not enough:
     * GtkFlowBox still claims Tab moved into it, so Tab from the transcript went nowhere. */
    gtk_widget_set_can_focus(flow, FALSE);
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

void dashboard_add_compact_setters(AdwBreakpoint *breakpoint) {
    GValue vertical = G_VALUE_INIT;
    g_value_init(&vertical, GTK_TYPE_ORIENTATION);
    g_value_set_enum(&vertical, GTK_ORIENTATION_VERTICAL);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(dashboard_page()->columns), "orientation", &vertical);
    g_value_unset(&vertical);
    GValue unequal = G_VALUE_INIT;
    g_value_init(&unequal, G_TYPE_BOOLEAN);
    g_value_set_boolean(&unequal, FALSE);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(dashboard_page()->columns), "homogeneous", &unequal);
    g_value_unset(&unequal);
}

void dashboard_refresh_actions(gint32 state, gboolean copyable) {
    gboolean recording = state == JSTI_STATE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->dashboard_copy), copyable);
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->cancel), state == JSTI_STATE_WORKING);
    gtk_widget_set_visible(GTK_WIDGET(dashboard_page()->cancel), state == JSTI_STATE_WORKING);
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->record), state != JSTI_STATE_WORKING);
    gtk_button_set_label(dashboard_page()->record, recording ? "Stop Recording"
                                    : state == JSTI_STATE_WORKING ? "Working…" : "Start Recording");
    if (recording) gtk_widget_add_css_class(GTK_WIDGET(dashboard_page()->record), "recording");
    else gtk_widget_remove_css_class(GTK_WIDGET(dashboard_page()->record), "recording");
    /* While recording, the hero previews the words as they arrive. */
    gchar *preview = recording ? displayed_transcript() : NULL;
    gtk_label_set_text(dashboard_page()->live_preview, preview != NULL && preview[0] != '\0' ? preview : "Listening…");
    gtk_widget_set_visible(GTK_WIDGET(dashboard_page()->live_preview), recording);
    g_free(preview);
}

void dashboard_set_copy_enabled(gboolean enabled) {
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->dashboard_copy), enabled);
}

gboolean dashboard_can_record(void) { return gtk_widget_is_sensitive(GTK_WIDGET(dashboard_page()->record)); }

/* The dashboard's Setup card and the header subtitle echo the settings. */
void refresh_setup(void) {
    const char *microphone = models_microphone_name();
    gtk_label_set_text(dashboard_page()->setup_microphone, microphone != NULL ? microphone : "Default microphone");
    const char *model = models_model_name();
    gtk_label_set_text(dashboard_page()->setup_model, model != NULL ? model : "No model selected");
    adw_window_title_set_subtitle(ui.title, model != NULL ? model : "");
    gchar *output = output_summary();
    gtk_label_set_text(dashboard_page()->setup_output, output);
    g_free(output);
    const char *hint = output_shortcut_hint();
    gtk_label_set_text(dashboard_page()->setup_shortcut, hint != NULL && hint[0] != '\0' ? hint : "Checking the desktop…");
}

void insights_free(gpointer pointer) {
    Insights *insights = pointer;
    for (int index = 0; index < 5; index++) {
        g_free(insights->all[index]);
        g_free(insights->visible[index]);
    }
    g_free(insights);
}

void insights_apply(gpointer pointer) {
    Insights *insights = pointer;
    /* Order: sessions, errors, recording time, average length, spend. */
    gtk_label_set_text(dashboard_page()->hero_sessions, insights->all[0]);
    gtk_label_set_text(dashboard_page()->hero_time, insights->all[2]);
    gtk_label_set_text(dashboard_page()->hero_spend, insights->all[4]);
    gtk_label_set_text(dashboard_page()->insight_sessions, insights->all[0]);
    gtk_label_set_text(dashboard_page()->insight_time, insights->all[2]);
    gtk_label_set_text(dashboard_page()->insight_average, insights->all[3]);
    gtk_label_set_text(dashboard_page()->insight_spend, insights->all[4]);
    history_show_insights(insights->visible[0], insights->visible[1], insights->visible[3], insights->visible[4]);
    /* The status notifier's menu shows the dashboard's totals, as the Mac's menu bar extra does. */
    g_free(ui.tray_summary);
    ui.tray_summary = g_strcmp0(insights->all[0], "0") == 0
        ? g_strdup("No sessions yet")
        : g_strdup_printf("%s %s · %s · %s", insights->all[0],
                          g_strcmp0(insights->all[0], "1") == 0 ? "session" : "sessions", insights->all[2],
                          insights->all[4]);
    jsti_tray_set_state(ui.state, ui.tray_summary);
}

void insights_copy(gchar **target, const JSTIInsights *source) {
    const char *values[5] = { "0", "0", "—", "—", "—" };
    if (source != NULL) {
        values[0] = source->sessions;
        values[1] = source->errors;
        values[2] = source->recording_time;
        values[3] = source->average_length;
        values[4] = source->spend;
    }
    for (int index = 0; index < 5; index++) target[index] = g_strdup(values[index] != NULL ? values[index] : "—");
}

int32_t jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible) {
    Insights *insights = g_new0(Insights, 1);
    insights_copy(insights->all, all);
    insights_copy(insights->visible, visible);
    return post(insights_apply, insights, insights_free);
}
