/* The History page's widgets and actions: the list, the selected card's
 * transcript and buttons, export, delete and the functions the rest of the
 * window uses instead of the page state (LinuxWindowHistoryPage.h). */
#include "LinuxWindowHistoryState.h"
#include "LinuxWindowDashboardPage.h"

static void on_search(GtkSearchEntry *entry, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_SEARCH_HISTORY, gtk_editable_get_text(GTK_EDITABLE(entry)), 0);
}

/* The transcript and actions live in the selected History card, as the Mac
 * expands its selected row. The window holds its own reference, so moving
 * the detail between cards or rebuilding the list never destroys it. */
void detach_detail(void) {
    GtkWidget *parent = gtk_widget_get_parent(history_page()->detail);
    if (parent != NULL) gtk_box_remove(GTK_BOX(parent), history_page()->detail);
}

void attach_detail(GtkListBoxRow *row) {
    GtkWidget *card = row != NULL ? gtk_list_box_row_get_child(row) : NULL;
    if (card != NULL && gtk_widget_get_parent(history_page()->detail) == card) return;
    detach_detail();
    if (card != NULL) gtk_box_append(GTK_BOX(card), history_page()->detail);
}

static void on_history_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    attach_detail(row);
    if (row == NULL) return;
    gint index = gtk_list_box_row_get_index(row);
    if (index < 0 || (guint)index >= history_page()->history_ids->len) return;
    const char *id = g_ptr_array_index(history_page()->history_ids, index);
    if (g_strcmp0(id, history_page()->selected_id) == 0) return;
    retire_cleanup_preview();
    g_free(history_page()->selected_id);
    history_page()->selected_id = g_strdup(id);
    /* Stale text never stays under another record's actions. */
    g_clear_pointer(&history_page()->presented_id, g_free);
    set_transcript("");
    history_page()->playback_state = 0;
    gtk_label_set_text(history_page()->playback_label, "");
    refresh_actions();
    emit(JSTI_EVENT_SELECT_HISTORY, id, 0);
}

static void on_version(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (history_page()->selected_id == NULL || g_strcmp0(history_page()->presented_id, history_page()->selected_id) != 0) return;
    guint selected = gtk_drop_down_get_selected(dashboard_page()->version);
    if ((gint32)selected == history_page()->presented_variant) return;
    retire_cleanup_preview();
    history_page()->presented_variant = (gint32)selected;
    emit(JSTI_EVENT_TRANSCRIPT_VERSION, history_page()->selected_id, (gint32)selected);
}

static void on_retry(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id != NULL) emit(JSTI_EVENT_RETRY_HISTORY, history_page()->selected_id, 0);
}

static void on_correction_results(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id != NULL && g_strcmp0(history_page()->presented_id, history_page()->selected_id) == 0)
        emit(72, history_page()->selected_id, 2);
}

static void on_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id != NULL) emit(JSTI_EVENT_PLAYBACK_TOGGLE, history_page()->selected_id, 0);
}

void on_stop_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_PLAYBACK_STOP, history_page()->selected_id, 0);
}

/* The host captures the displayed text with jsti_window_transcript_snapshot
 * while this event runs, so it is the text shown under this record. */
void on_read_aloud(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id == NULL || g_strcmp0(history_page()->presented_id, history_page()->selected_id) != 0) return;
    emit(JSTI_EVENT_READ_ALOUD, history_page()->selected_id, 0);
}

static void on_open_audio(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id != NULL) emit(JSTI_EVENT_OPEN_AUDIO, history_page()->selected_id, 0);
}

static void export_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    gint32 variant = GPOINTER_TO_INT(data);
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL) emit(JSTI_EVENT_EXPORT_HISTORY, path, variant);
        g_free(path);
        g_object_unref(file);
    }
    g_clear_pointer(&history_page()->export_text, g_free);
}

static void on_issue_report(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.state == JSTI_STATE_IDLE && history_page()->selected_id != NULL &&
        g_strcmp0(history_page()->presented_id, history_page()->selected_id) == 0)
        emit(JSTI_EVENT_HISTORY_ISSUE_REPORT, history_page()->selected_id, 0);
}

static void on_export(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (history_page()->selected_id == NULL || history_page()->export_text != NULL) return;
    /* Capture the displayed text and version at the click, before the dialog. */
    history_page()->export_text = displayed_transcript();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Export transcript");
    gchar *name = g_strdup_printf("Transcript-%s.txt", history_page()->selected_id);
    gtk_file_dialog_set_initial_name(dialog, name);
    g_free(name);
    gtk_file_dialog_save(dialog, ui.window, NULL, export_chosen,
                         GINT_TO_POINTER(history_page()->presented_switchable ? history_page()->presented_variant : 1));
    g_object_unref(dialog);
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
    gboolean clear = button == history_page()->history_clear;
    const char *identifiers = clear ? history_page()->all_history_ids : history_page()->selected_id;
    if (ui.state != 0 || identifiers == NULL || identifiers[0] == '\0') return;
    gtk_window_present(GTK_WINDOW(history_delete_dialog(identifiers, clear)));
}

/* Scrolling to the end of History asks the host for its next page of matches. */
static void on_history_edge(GtkScrolledWindow *scroller, GtkPositionType position, gpointer data) {
    (void)scroller;
    (void)data;
    if (position == GTK_POS_BOTTOM && history_page()->history_ids != NULL && history_page()->history_ids->len > 0) {
        emit(JSTI_EVENT_HISTORY_LOAD_MORE, "", 0);
    }
}

GtkWidget *build_history(GtkTextBuffer *buffer) {
    GtkWidget *column, *page = jsti_page_new(&column);
    g_signal_connect(page, "edge-reached", G_CALLBACK(on_history_edge), NULL);
    GtkWidget *chips, *trailing;
    GtkWidget *hero = jsti_hero_new(
        NULL, "Session History", "Search, replay and reuse past recordings and their transcripts.", &chips,
        &trailing);
    history_page()->history_import = GTK_BUTTON(gtk_button_new_with_label("Import…"));
    gtk_widget_add_css_class(GTK_WIDGET(history_page()->history_import), "jsti-hero-button");
    g_signal_connect(history_page()->history_import, "clicked", G_CALLBACK(on_import), NULL);
    gtk_box_append(GTK_BOX(trailing), GTK_WIDGET(history_page()->history_import));
    history_page()->history_clear = GTK_BUTTON(gtk_button_new_with_label("Clear History…"));
    g_signal_connect(history_page()->history_clear, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_prepend(GTK_BOX(trailing), GTK_WIDGET(history_page()->history_clear));
    history_page()->history_filters = jsti_history_filters_button_new();
    gtk_box_prepend(GTK_BOX(trailing), history_page()->history_filters);
    history_page()->search = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    gtk_search_entry_set_placeholder_text(history_page()->search, "Search transcripts, models and profiles");
    gtk_accessible_update_property(GTK_ACCESSIBLE(history_page()->search), GTK_ACCESSIBLE_PROPERTY_LABEL, "Search History", -1);
    g_signal_connect(history_page()->search, "search-changed", G_CALLBACK(on_search), NULL);
    gtk_box_insert_child_after(GTK_BOX(hero), GTK_WIDGET(history_page()->search), gtk_widget_get_first_child(hero));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Sessions", &history_page()->history_sessions));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Errors", &history_page()->history_errors));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Average Length", &history_page()->history_average));
    gtk_flow_box_append(GTK_FLOW_BOX(chips), jsti_chip_new("Spend", &history_page()->history_spend));
    gtk_box_append(GTK_BOX(column), hero);

    history_page()->history = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(history_page()->history), "jsti-history");
    gtk_list_box_set_selection_mode(history_page()->history, GTK_SELECTION_SINGLE);
    g_signal_connect(history_page()->history, "row-selected", G_CALLBACK(on_history_selected), NULL);
    history_page()->history_ids = g_ptr_array_new_with_free_func(g_free);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(history_page()->history));
    history_page()->history_empty = gtk_label_new("No history yet. Press Record to capture your first session.");
    gtk_widget_add_css_class(history_page()->history_empty, "jsti-empty");
    gtk_box_append(GTK_BOX(column), history_page()->history_empty);

    /* The detail moved into the selected card. */
    history_page()->detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    g_object_ref_sink(history_page()->detail);
    gtk_box_append(GTK_BOX(history_page()->detail), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *label = gtk_label_new("Transcript");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_widget_add_css_class(label, "jsti-detail-heading");
    gtk_box_append(GTK_BOX(heading), label);
    const char *versions[] = { "Processed", "Original", NULL };
    dashboard_page()->version = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(versions));
    gtk_widget_set_tooltip_text(GTK_WIDGET(dashboard_page()->version), "Transcript version");
    jsti_accessible_set_name(GTK_WIDGET(dashboard_page()->version), "Transcript version");
    g_signal_connect(dashboard_page()->version, "notify::selected", G_CALLBACK(on_version), NULL);
    gtk_box_append(GTK_BOX(heading), GTK_WIDGET(dashboard_page()->version));
    gtk_box_append(GTK_BOX(history_page()->detail), heading);
    GtkWidget *scroller = transcript_view(buffer, 72);
    dashboard_page()->transcript = GTK_TEXT_VIEW(gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scroller)));
    gtk_box_append(GTK_BOX(history_page()->detail), scroller);

    GtkWidget *playback = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    history_page()->play = GTK_BUTTON(gtk_button_new_with_label("Play"));
    history_page()->stop_play = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(history_page()->play, "clicked", G_CALLBACK(on_play), NULL);
    g_signal_connect(history_page()->stop_play, "clicked", G_CALLBACK(on_stop_play), NULL);
    history_page()->playback_label = GTK_LABEL(gtk_label_new(""));
    gtk_widget_add_css_class(GTK_WIDGET(history_page()->playback_label), "dim-label");
    gtk_widget_add_css_class(GTK_WIDGET(history_page()->playback_label), "numeric");
    gtk_widget_set_hexpand(GTK_WIDGET(history_page()->playback_label), TRUE);
    gtk_label_set_xalign(history_page()->playback_label, 0);
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(history_page()->play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(history_page()->stop_play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(history_page()->playback_label));
    dashboard_page()->copy = GTK_BUTTON(gtk_button_new_with_label("Copy"));
    gtk_widget_add_css_class(GTK_WIDGET(dashboard_page()->copy), "suggested-action");
    g_signal_connect(dashboard_page()->copy, "clicked", G_CALLBACK(on_copy), NULL);
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(dashboard_page()->copy));
    gtk_box_append(GTK_BOX(history_page()->detail), playback);

    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    read_aloud.button = GTK_BUTTON(gtk_button_new_with_label("Read aloud"));
    g_signal_connect(read_aloud.button, "clicked", G_CALLBACK(on_read_aloud), NULL);
    history_page()->retry = GTK_BUTTON(gtk_button_new_with_label("Retry"));
    history_page()->export_button = GTK_BUTTON(gtk_button_new_with_label("Export…"));
    history_page()->issue_button = GTK_BUTTON(gtk_button_new_with_label("Create Issue with Details…"));
    g_signal_connect(history_page()->issue_button, "clicked", G_CALLBACK(on_issue_report), NULL);
    history_page()->open_audio = GTK_BUTTON(gtk_button_new_with_label("Open audio"));
    g_signal_connect(history_page()->retry, "clicked", G_CALLBACK(on_retry), NULL);
    g_signal_connect(history_page()->export_button, "clicked", G_CALLBACK(on_export), NULL);
    g_signal_connect(history_page()->open_audio, "clicked", G_CALLBACK(on_open_audio), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(read_aloud.button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(history_page()->retry));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(history_page()->export_button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(history_page()->open_audio));
    gtk_box_append(GTK_BOX(history_page()->detail), actions);
    gtk_widget_set_halign(GTK_WIDGET(history_page()->issue_button), GTK_ALIGN_END);
    gtk_widget_set_size_request(GTK_WIDGET(history_page()->issue_button), -1, 44);
    gtk_box_append(GTK_BOX(history_page()->detail), GTK_WIDGET(history_page()->issue_button));
    GtkWidget *management = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(management, GTK_ALIGN_END);
    history_page()->correction_results = GTK_BUTTON(gtk_button_new_with_label("Correction results"));
    g_signal_connect(history_page()->correction_results, "clicked", G_CALLBACK(on_correction_results), NULL);
    history_page()->history_delete = GTK_BUTTON(gtk_button_new_with_label("Delete…"));
    g_signal_connect(history_page()->history_delete, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(history_page()->correction_results));
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(history_page()->history_delete));
    gtk_box_append(GTK_BOX(history_page()->detail), management);
    return page;
}

void history_page_start(void) { history_page()->presented_variant = -1; }
void history_page_close(void) { g_clear_pointer(&history_page()->all_history_ids, g_free); }
void history_set_import_button(GtkButton *button) { history_page()->import_button = button; }
GtkWidget *history_audio_cleanup_button(void) {
    history_page()->audio_cleanup = GTK_BUTTON(gtk_button_new_with_mnemonic("Delete _audio…"));
    gtk_widget_add_css_class(GTK_WIDGET(history_page()->audio_cleanup), "destructive-action");
    gtk_widget_set_valign(GTK_WIDGET(history_page()->audio_cleanup), GTK_ALIGN_CENTER);
    g_signal_connect(history_page()->audio_cleanup, "clicked", G_CALLBACK(on_audio_cleanup), NULL);
    return GTK_WIDGET(history_page()->audio_cleanup);
}
GtkWidget *history_filters_button(void) { return history_page()->history_filters; }
void history_show_insights(const char *sessions, const char *errors, const char *average, const char *spend) {
    gtk_label_set_text(history_page()->history_sessions, sessions);
    gtk_label_set_text(history_page()->history_errors, errors);
    gtk_label_set_text(history_page()->history_average, average);
    gtk_label_set_text(history_page()->history_spend, spend);
}

const char *history_selected_id(void) { return history_page()->selected_id; }
gboolean history_is_selected(const char *id) { return g_strcmp0(id, history_page()->selected_id) == 0; }
gboolean history_selection_presented(void) {
    return history_page()->selected_id != NULL && g_strcmp0(history_page()->presented_id, history_page()->selected_id) == 0;
}
gint32 history_presented_variant(void) { return history_page()->presented_variant; }
gboolean history_presented_switchable(void) { return history_page()->presented_switchable; }
void history_mark_presented(const char *id, gint32 variant, gboolean switchable) {
    g_free(history_page()->presented_id);
    history_page()->presented_id = g_strdup(id);
    history_page()->presented_variant = variant;
    history_page()->presented_switchable = switchable;
}
void history_forget_presentation(void) { g_clear_pointer(&history_page()->presented_id, g_free); }
void history_show_playback(const char *id, gint32 state, const char *text) {
    if (!history_is_selected(id)) return;
    history_page()->playback_state = state;
    gtk_label_set_text(history_page()->playback_label, text != NULL ? text : "");
}
const char *history_export_text(void) { return history_page()->export_text; }

void refresh_history_actions(gboolean idle, gboolean has_text) {
    gboolean has_record = history_page()->selected_id != NULL;
    gboolean presented = history_selection_presented();
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->retry), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->correction_results), idle && presented);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->export_button), idle && presented && has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->issue_button), idle && presented);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->open_audio), has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->play), has_record && (idle || history_page()->playback_state != 0));
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->stop_play), has_record && history_page()->playback_state != 0);
    gtk_button_set_label(history_page()->play, history_page()->playback_state == 1 ? "Pause" : "Play");
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->import_button), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->history_import), idle);
    gtk_widget_set_sensitive(history_page()->history_filters, idle);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->history_delete), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(history_page()->history_clear),
        idle && history_page()->all_history_ids != NULL && history_page()->all_history_ids[0] != '\0');
    if (history_page()->audio_cleanup != NULL) gtk_widget_set_sensitive(GTK_WIDGET(history_page()->audio_cleanup), idle);
}
