/* Compare Models' self-test and screenshot tour, and the event recorder they
 * read: while `testing`, events are recorded here instead of reaching the host. */
#include "LinuxComparisonState.h"

static gboolean testing = FALSE;
static gint32 test_event = 0;
static gint32 test_index = 0;
static gchar *test_payload = NULL;

void comparison_emit(gint32 event, const char *text, gint32 index) {
    if (!testing) { jsti_window_emit(event, text, index); return; }
    test_event = event;
    test_index = index;
    g_free(test_payload); test_payload = g_strdup(text);
}

static Presentation fixture(gboolean revealed) {
    Presentation p = {
        .models = "test/file-a\tFile A\t0\t1\ntest/file-b\tFile B\t0\t0\ntest/live-a\tLive A\t1\t0\ntest/live-b\tLive B\t1\t0",
        .rounds = "synthetic-round\tSynthetic sample.wav", .selected = "synthetic-round",
        .detail = revealed
            ? "Synthetic judged comparison\n\nResult A - File A (rank 2)\nCould we meet Friday?\n"
              "\nResult B - File B (rank 1)\nCould we meet on Friday?\n\nScoreboard\nFile B: 1 win\nFile A: 0 wins"
            : "Synthetic sample.wav\n\nResult A\nCould we meet Friday?\n\nResult B\nCould we meet on Friday?\n"
              "Could we meet [+on] Friday?\n\nDiff against Result A: [+added] / [-removed].\n"
              "Rank every blind result to reveal models.",
        .judgeable = !revealed, .sync_available = TRUE,
        .references = "synthetic-a\tResult A\nsynthetic-b\tResult B", .reference = "synthetic-a"
    };
    return p;
}

static void finish_fixture(void) {
    Comparison *ui = comparison_ui();
    if (ui->window != NULL) gtk_window_close(ui->window);
    testing = FALSE;
    g_clear_pointer(&test_payload, g_free);
}

int32_t jsti_comparison_self_test(GtkWindow *parent, char *error, size_t capacity) {
    Comparison *ui = comparison_ui();
    testing = TRUE;
    jsti_comparison_open(parent);
    Presentation p = fixture(FALSE);
    comparison_present(&p);
    gboolean valid = ui->model_ids->len == 2 && ui->round_ids->len == 1
        && gtk_widget_get_sensitive(GTK_WIDGET(ui->judge));
    valid = valid && gtk_check_button_get_active(GTK_CHECK_BUTTON(
        gtk_list_box_row_get_child(gtk_list_box_get_row_at_index(ui->models, 0))));
    valid = valid && ui->reference_ids->len == 2;
    gtk_drop_down_set_selected(ui->reference, 1);
    valid = valid && test_event == 124 && g_strcmp0(test_payload, "synthetic-b") == 0;
    g_signal_emit_by_name(ui->select_all, "clicked");
    valid = valid && test_event == 125 && test_index == 0
        && g_strcmp0(test_payload, "test/file-a\ttest/file-b") == 0;
    g_signal_emit_by_name(ui->select_none, "clicked");
    valid = valid && test_event == 125 && g_strcmp0(test_payload, "") == 0;
    gchar *all_models = p.models;
    p.models = "test/file-b\tFile B\t0\t0\ntest/live-a\tLive A\t1\t0\ntest/live-b\tLive B\t1\t0";
    comparison_present(&p);
    valid = valid && ui->model_ids->len == 1 && !gtk_widget_get_sensitive(GTK_WIDGET(ui->run));
    g_signal_emit_by_name(ui->select_all, "clicked");
    valid = valid && test_event == 125 && g_strcmp0(test_payload, "test/file-b") == 0;
    p.models = all_models; comparison_present(&p);
    valid = valid && gtk_widget_get_sensitive(GTK_WIDGET(ui->run));
    valid = valid && gtk_widget_get_sensitive(GTK_WIDGET(ui->sync))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->sync_now))
        && gtk_label_get_wrap(GTK_LABEL(gtk_check_button_get_child(ui->sync)));
    gtk_check_button_set_active(ui->sync, TRUE);
    valid = valid && test_event == 121 && test_index == 1;
    p.sync_enabled = TRUE; comparison_present(&p);
    valid = valid && gtk_widget_get_sensitive(GTK_WIDGET(ui->sync_now));
    g_signal_emit_by_name(ui->sync_now, "clicked");
    valid = valid && test_event == 122;
    valid = valid && !gtk_check_button_get_active(ui->save_history)
        && gtk_label_get_wrap(GTK_LABEL(gtk_check_button_get_child(ui->save_history)));
    gtk_check_button_set_active(ui->save_history, TRUE);
    valid = valid && test_event == 129 && test_index == 1;
    gboolean saved = FALSE;
    comparison_present_save_history(&saved);
    valid = valid && !gtk_check_button_get_active(ui->save_history) && test_event == 129 && test_index == 1;
    gtk_drop_down_set_selected(ui->mode, 1);
    for (guint i = 0; i < ui->model_ids->len; ++i) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui->models, (int)i);
        GtkCheckButton *check = GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row));
        valid = valid && GTK_IS_LABEL(gtk_check_button_get_child(check))
            && gtk_label_get_wrap(GTK_LABEL(gtk_check_button_get_child(check)));
        gtk_check_button_set_active(check, TRUE);
    }
    gtk_editable_set_text(GTK_EDITABLE(ui->language), "en_GB");
    g_signal_emit_by_name(ui->run, "clicked");
    valid = valid && test_event == 103 && g_strcmp0(test_payload, "en_GB\ntest/live-a\ttest/live-b") == 0;
    gtk_editable_set_text(GTK_EDITABLE(ui->ranks), "2,1");
    g_signal_emit_by_name(ui->judge, "clicked");
    valid = valid && test_event == 106 && g_strcmp0(test_payload, "synthetic-round\n2,1") == 0;
    g_signal_emit_by_name(ui->play, "clicked");
    valid = valid && test_event == 108 && g_strcmp0(test_payload, "synthetic-round") == 0;
    g_signal_emit_by_name(ui->copy_json, "clicked");
    valid = valid && test_event == 126 && test_index == 0 && g_strcmp0(test_payload, "") == 0;
    gtk_drop_down_set_selected(ui->export_scope, 1);
    g_signal_emit_by_name(ui->copy_markdown, "clicked");
    valid = valid && test_event == 126 && test_index == 1 && g_strcmp0(test_payload, "synthetic-round") == 0;
    PickerRequest *export_request = comparison_picker_request(g_string_new("picker-round"), FALSE);
    comparison_save_export(export_request, "synthetic.json");
    valid = valid && test_event == 127 && test_index == 0
        && g_strcmp0(test_payload, "picker-round\nsynthetic.json") == 0;
    comparison_free_request(export_request);
    PickerRequest *deletion = comparison_picker_request(g_string_new(ui->selected), FALSE);
    comparison_confirm_deletion(deletion, "cancel");
    valid = valid && test_event == 127;
    comparison_confirm_deletion(deletion, "delete");
    valid = valid && test_event == 120 && g_strcmp0(test_payload, "synthetic-round") == 0;
    g_string_assign(deletion->payload, "a-stale-round");
    test_event = 0; comparison_confirm_deletion(deletion, "delete");
    valid = valid && test_event == 0;
    comparison_free_request(deletion);
    p.batch_round = "synthetic-round"; p.batch_remaining = 1; p.can_next = FALSE; comparison_present(&p);
    valid = valid && gtk_widget_get_visible(GTK_WIDGET(ui->next_file))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->next_file))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->run)) && gtk_widget_get_sensitive(GTK_WIDGET(ui->cancel));
    test_event = 0; g_signal_emit_by_name(ui->next_file, "clicked");
    valid = valid && test_event == 0;
    p.judgeable = FALSE; p.can_next = TRUE; comparison_present(&p);
    valid = valid && gtk_widget_get_sensitive(GTK_WIDGET(ui->next_file));
    g_signal_emit_by_name(ui->next_file, "clicked");
    valid = valid && test_event == 128 && g_strcmp0(test_payload, "synthetic-round") == 0;
    PickerRequest *stale_export = comparison_picker_request(g_string_new(ui->selected), TRUE);
    p.busy = TRUE; p.recording = TRUE; p.judgeable = FALSE; comparison_present(&p);
    valid = valid && !gtk_widget_get_sensitive(GTK_WIDGET(ui->run))
        && gtk_widget_get_sensitive(GTK_WIDGET(ui->stop)) && !gtk_widget_get_sensitive(GTK_WIDGET(ui->judge))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->copy_json))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->export_scope))
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui->next_file));
    finish_fixture();
    /* Closing releases the window's rows, so a late picker answer finds no window. */
    valid = valid && test_event == 123 && ui->window == NULL && ui->model_ids == NULL && ui->selected == NULL;
    comparison_save_export(stale_export, "late-picker.md");
    valid = valid && test_event == 123;
    comparison_free_request(stale_export);
    if (!valid) jsti_set_error(error, capacity, "Comparison selection, judging, playback or capture controls failed.");
    return valid ? 0 : -1;
}

typedef struct { GtkWindow *parent; gchar *directory; guint stage; AdwColorScheme original; } ComparisonTour;
static Presentation tour_fixture(guint stage) {
    Presentation p = fixture(stage == 1 || stage == 3);
    if (stage >= 2) {
        p.batch_round = "synthetic-round"; p.batch_remaining = 1; p.can_next = stage == 3;
        p.detail = stage == 3
            ? "Batch paused. One sample queued. Choose Next file to continue.\n\n"
              "Result A - File A (rank 2)\nCould we meet Friday?\n\n"
              "Result B - File B (rank 1)\nCould we meet on Friday?\n\nScoreboard\nFile B: 1 win\nFile A: 0 wins"
            : "Batch paused. One sample queued. Judge before Next file.\n\n"
              "Result A\nCould we meet Friday?\n\nResult B\nCould we meet on Friday?\n"
              "Could we meet [+on] Friday?\n\nRank every blind result to reveal models.";
    }
    return p;
}

static gboolean comparison_snapshot(gpointer value) {
    Comparison *ui = comparison_ui();
    ComparisonTour *tour = value;
    const char *names[] = {"comparison-blind-light.png", "comparison-revealed-dark.png",
        "comparison-batch-paused-light.png", "comparison-batch-ready-dark.png"};
    const char *name = names[tour->stage];
    gchar *path = g_build_filename(tour->directory, name, NULL);
    if (ui->window == NULL || jsti_widget_save_snapshot(adw_window_get_content(ADW_WINDOW(ui->window)), path, TRUE) != 0)
        g_printerr("Comparison snapshot %s failed.\n", name);
    g_free(path);
    const char *full_names[] = {"comparison-blind-light-full.png", "comparison-revealed-dark-full.png",
        "comparison-batch-paused-light-full.png", "comparison-batch-ready-dark-full.png"};
    const char *full_name = full_names[tour->stage];
    path = g_build_filename(tour->directory, full_name, NULL);
    if (ui->window == NULL || jsti_widget_save_snapshot(ui->column, path, TRUE) != 0)
        g_printerr("Comparison snapshot %s failed.\n", full_name);
    g_free(path);
    if (tour->stage < 3) {
        ++tour->stage;
        Presentation p = tour_fixture(tour->stage); comparison_present(&p);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(),
            tour->stage == 2 ? ADW_COLOR_SCHEME_FORCE_LIGHT : ADW_COLOR_SCHEME_FORCE_DARK);
        g_timeout_add(700, comparison_snapshot, tour);
    } else {
        finish_fixture();
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), tour->original);
        gtk_window_close(tour->parent);
        g_free(tour->directory); g_free(tour);
    }
    return G_SOURCE_REMOVE;
}

void jsti_comparison_screenshot_tour(GtkWindow *parent, const char *directory) {
    ComparisonTour *tour = g_new0(ComparisonTour, 1);
    tour->parent = parent; tour->directory = g_strdup(directory);
    tour->original = adw_style_manager_get_color_scheme(adw_style_manager_get_default());
    adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_LIGHT);
    testing = TRUE; jsti_comparison_open(parent);
    Presentation p = fixture(FALSE); comparison_present(&p);
    g_timeout_add(700, comparison_snapshot, tour);
}
