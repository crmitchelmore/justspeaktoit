#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    GtkWindow *window;
    GtkDropDown *mode;
    GtkEntry *language, *ranks;
    GtkListBox *models;
    GtkDropDown *rounds;
    GtkTextView *detail;
    GtkWidget *column;
    GtkButton *run, *stop, *cancel, *judge, *json, *markdown, *play, *stop_audio;
    GPtrArray *model_ids, *round_ids;
    gchar *selected, *model_rows, *round_rows;
    gboolean suppress;
} Comparison;
static Comparison ui;
typedef struct { GtkWindow *window; GString *payload; gboolean markdown; } PickerRequest;
static PickerRequest *picker_request(GString *payload, gboolean markdown) {
    PickerRequest *request = g_new0(PickerRequest, 1);
    request->window = g_object_ref(ui.window); request->payload = payload; request->markdown = markdown;
    return request;
}
static void free_request(PickerRequest *request) {
    g_object_unref(request->window);
    if (request->payload != NULL) g_string_free(request->payload, TRUE);
    g_free(request);
}
static gboolean testing = FALSE;
static gint32 test_event = 0;
static gchar *test_payload = NULL;

static void comparison_emit(gint32 event, const char *text, gint32 index) {
    if (!testing) { jsti_window_emit(event, text, index); return; }
    test_event = event;
    g_free(test_payload); test_payload = g_strdup(text);
}

static void comparison_error(const char *message) {
    g_warning("Comparison: %s", message);
    if (ui.window != NULL) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(ui.detail);
        gtk_text_buffer_set_text(buffer, message, -1);
        gtk_widget_grab_focus(GTK_WIDGET(ui.detail));
    }
}
static void named(GtkWidget *widget, const char *name) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
}
static void clear_models(void) {
    while (gtk_widget_get_first_child(GTK_WIDGET(ui.models)) != NULL)
        gtk_list_box_remove(ui.models, gtk_widget_get_first_child(GTK_WIDGET(ui.models)));
    g_ptr_array_set_size(ui.model_ids, 0);
}
static void populate_models(void) {
    clear_models();
    gboolean live = gtk_drop_down_get_selected(ui.mode) == 1;
    gchar **lines = g_strsplit(ui.model_rows != NULL ? ui.model_rows : "", "\n", -1);
    for (guint i = 0; lines[i] != NULL; ++i) {
        gchar **fields = g_strsplit(lines[i], "\t", 3);
        if (g_strv_length(fields) == 3 && (strcmp(fields[2], "1") == 0) == live) {
            GtkWidget *check = gtk_check_button_new();
            GtkWidget *label = gtk_label_new(fields[1]);
            gtk_label_set_wrap(GTK_LABEL(label), TRUE);
            gtk_label_set_xalign(GTK_LABEL(label), 0);
            gtk_check_button_set_child(GTK_CHECK_BUTTON(check), label);
            named(check, fields[1]);
            gtk_list_box_append(ui.models, check);
            g_ptr_array_add(ui.model_ids, g_strdup(fields[0]));
        }
        g_strfreev(fields);
    }
    g_strfreev(lines);
    gtk_button_set_label(ui.run, live ? "Start microphone" : "Choose samples and run…");
}
static void mode_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (!ui.suppress) populate_models();
}
static void round_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint row = gtk_drop_down_get_selected(ui.rounds);
    if (!ui.suppress && row < ui.round_ids->len)
        comparison_emit(101, g_ptr_array_index(ui.round_ids, row), 0);
}
static void picker_error(GError *error) {
    if (error != NULL && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)
        && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED))
        comparison_error(error->message);
    g_clear_error(&error);
}
static void files_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    PickerRequest *request = data;
    GString *payload = request->payload;
    GError *error = NULL;
    GListModel *files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);
    if (files != NULL) {
        gboolean valid = g_list_model_get_n_items(files) <= 32;
        for (guint i = 0; valid && i < g_list_model_get_n_items(files); ++i) {
            GFile *file = g_list_model_get_item(files, i);
            gchar *path = g_file_get_path(file);
            valid = path != NULL && strpbrk(path, "\r\n\t") == NULL;
            if (valid) { g_string_append_c(payload, '\n'); g_string_append(payload, path); }
            g_free(path); g_object_unref(file);
        }
        if (valid && ui.window == request->window) comparison_emit(102, payload->str, 0);
        else if (ui.window == request->window) comparison_error("Choose one to 32 local audio files with single-line names.");
        g_object_unref(files);
    }
    if (ui.window == request->window) picker_error(error); else g_clear_error(&error);
    free_request(request);
}
static void run_clicked(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    const char *language = gtk_editable_get_text(GTK_EDITABLE(ui.language));
    if (strpbrk(language, "\r\n\t") != NULL) {
        comparison_error("Use a single language identifier, or blank for Automatic."); return;
    }
    GString *payload = g_string_new(language);
    g_string_append_c(payload, '\n');
    guint count = 0;
    for (guint i = 0; i < ui.model_ids->len; ++i) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.models, (int)i);
        GtkCheckButton *check = GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row));
        if (gtk_check_button_get_active(check)) {
            if (count++) g_string_append_c(payload, '\t');
            g_string_append(payload, g_ptr_array_index(ui.model_ids, i));
        }
    }
    if (count < 2 || count > 8) {
        comparison_error("Select two to eight comparison models.");
        g_string_free(payload, TRUE); return;
    }
    if (gtk_drop_down_get_selected(ui.mode) == 1) {
        comparison_emit(103, payload->str, 0); g_string_free(payload, TRUE); return;
    }
    GtkFileDialog *picker = gtk_file_dialog_new();
    gtk_file_dialog_set_title(picker, "Choose one sample, or multiple samples for Batch");
    gtk_file_dialog_open_multiple(picker, ui.window, NULL, files_chosen, picker_request(payload, FALSE));
    g_object_unref(picker);
}
static void action_clicked(GtkButton *button, gpointer data) {
    (void)data;
    if (button == ui.stop) comparison_emit(104, "", 0);
    if (button == ui.cancel) comparison_emit(105, "", 0);
    if (button == ui.play) comparison_emit(108, ui.selected != NULL ? ui.selected : "", 0);
    if (button == ui.stop_audio) comparison_emit(109, "", 0);
    if (button == ui.judge) {
        gchar *payload = g_strdup_printf("%s\n%s", ui.selected != NULL ? ui.selected : "",
                                        gtk_editable_get_text(GTK_EDITABLE(ui.ranks)));
        comparison_emit(106, payload, 0); g_free(payload);
    }
}
static void export_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    PickerRequest *request = data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL && ui.window == request->window) comparison_emit(107, path, request->markdown ? 1 : 0);
        else if (ui.window == request->window) comparison_error("Choose a local destination for the comparison export.");
        g_free(path); g_object_unref(file);
    }
    if (ui.window == request->window) picker_error(error); else g_clear_error(&error);
    free_request(request);
}
static void export_clicked(GtkButton *button, gpointer data) {
    (void)data;
    gboolean markdown = button == ui.markdown;
    GtkFileDialog *picker = gtk_file_dialog_new();
    gtk_file_dialog_set_title(picker, "Export transcripts and model identities (no audio)");
    gtk_file_dialog_set_initial_name(picker, markdown ? "Comparisons.md" : "Comparisons.json");
    gtk_file_dialog_save(picker, ui.window, NULL, export_chosen, picker_request(NULL, markdown));
    g_object_unref(picker);
}
static gboolean closing(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    comparison_emit(105, "", 0);
    ui.window = NULL;
    g_clear_pointer(&ui.selected, g_free);
    g_clear_pointer(&ui.model_rows, g_free);
    g_clear_pointer(&ui.round_rows, g_free);
    g_clear_pointer(&ui.model_ids, g_ptr_array_unref);
    g_clear_pointer(&ui.round_ids, g_ptr_array_unref);
    return FALSE;
}
static GtkWidget *button_new(const char *label, GCallback callback) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_signal_connect(button, "clicked", callback, NULL);
    return button;
}
static void heading(GtkBox *box, const char *name) {
    GtkWidget *label = gtk_label_new(name);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_add_css_class(label, "heading");
    gtk_box_append(box, label);
}
void jsti_comparison_open(GtkWindow *parent) {
    if (ui.window != NULL) { gtk_window_present(ui.window); return; }
    ui.model_ids = g_ptr_array_new_with_free_func(g_free);
    ui.round_ids = g_ptr_array_new_with_free_func(g_free);
    ui.window = GTK_WINDOW(adw_window_new());
    gtk_window_set_title(ui.window, "Compare Models");
    gtk_window_set_transient_for(ui.window, parent);
    gtk_window_set_modal(ui.window, TRUE);
    gtk_window_set_default_size(ui.window, 880, 720);
    g_signal_connect(ui.window, "close-request", G_CALLBACK(closing), NULL);
    GtkWidget *toolbar = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), adw_header_bar_new());
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    ui.column = column;
    gtk_widget_set_margin_start(column, 20); gtk_widget_set_margin_end(column, 20);
    gtk_widget_set_margin_top(column, 16); gtk_widget_set_margin_bottom(column, 20);
    GtkWidget *notice = gtk_label_new("One sample, raw results, blind judging. No insertion, post-processing "
                                     "or History changes. Provider keys come from Settings.");
    gtk_label_set_wrap(GTK_LABEL(notice), TRUE); gtk_label_set_xalign(GTK_LABEL(notice), 0);
    gtk_box_append(GTK_BOX(column), notice);
    const char *modes[] = {"File / multi-sample Batch", "Live microphone", NULL};
    ui.mode = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(modes)); named(GTK_WIDGET(ui.mode), "Comparison input");
    g_signal_connect(ui.mode, "notify::selected", G_CALLBACK(mode_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.mode));
    ui.language = GTK_ENTRY(gtk_entry_new());
    gtk_entry_set_placeholder_text(ui.language, "Language hint (e.g. en_GB); blank is Automatic");
    named(GTK_WIDGET(ui.language), "Comparison language hint");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.language));
    heading(GTK_BOX(column), "Models (select two to eight)");
    ui.models = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(ui.models, GTK_SELECTION_NONE);
    GtkWidget *model_scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(model_scroll, -1, 160);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(model_scroll), GTK_WIDGET(ui.models));
    gtk_box_append(GTK_BOX(column), model_scroll);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.run = GTK_BUTTON(button_new("Choose samples and run…", G_CALLBACK(run_clicked)));
    ui.stop = GTK_BUTTON(button_new("Stop", G_CALLBACK(action_clicked)));
    ui.cancel = GTK_BUTTON(button_new("Cancel run", G_CALLBACK(action_clicked)));
    gtk_widget_add_css_class(GTK_WIDGET(ui.run), "suggested-action");
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.run)); gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.stop));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.cancel)); gtk_box_append(GTK_BOX(column), actions);
    heading(GTK_BOX(column), "Saved rounds");
    ui.rounds = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(NULL));
    named(GTK_WIDGET(ui.rounds), "Saved comparison rounds");
    g_signal_connect(ui.rounds, "notify::selected", G_CALLBACK(round_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.rounds));
    GtkWidget *playback = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.play = GTK_BUTTON(button_new("Play sample", G_CALLBACK(action_clicked)));
    ui.stop_audio = GTK_BUTTON(button_new("Stop audio", G_CALLBACK(action_clicked)));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.stop_audio));
    gtk_box_append(GTK_BOX(column), playback);
    ui.detail = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(ui.detail, FALSE); gtk_text_view_set_wrap_mode(ui.detail, GTK_WRAP_WORD_CHAR);
    named(GTK_WIDGET(ui.detail), "Blind results and scoreboard");
    GtkWidget *detail_scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(detail_scroll, -1, 240);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroll), GTK_WIDGET(ui.detail));
    gtk_box_append(GTK_BOX(column), detail_scroll);
    heading(GTK_BOX(column), "Ranks for A, B, ... (e.g. 2,1,3; rank failures too)");
    ui.ranks = GTK_ENTRY(gtk_entry_new()); named(GTK_WIDGET(ui.ranks), "Ranks in blind order");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.ranks));
    ui.judge = GTK_BUTTON(button_new("Save ranking and reveal", G_CALLBACK(action_clicked)));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.judge));
    GtkWidget *exports = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.json = GTK_BUTTON(button_new("Export JSON", G_CALLBACK(export_clicked)));
    ui.markdown = GTK_BUTTON(button_new("Export Markdown", G_CALLBACK(export_clicked)));
    gtk_box_append(GTK_BOX(exports), GTK_WIDGET(ui.json)); gtk_box_append(GTK_BOX(exports), GTK_WIDGET(ui.markdown));
    gtk_box_append(GTK_BOX(column), exports);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), column);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), scrolled);
    adw_window_set_content(ADW_WINDOW(ui.window), toolbar);
    gtk_window_present(ui.window);
    comparison_emit(100, "", 0);
}
typedef struct {
    gchar *models, *rounds, *detail, *selected;
    gboolean busy, recording, judgeable;
} Presentation;
static void free_presentation(gpointer value) {
    Presentation *p = value;
    g_free(p->models); g_free(p->rounds); g_free(p->detail); g_free(p->selected); g_free(p);
}
static void present(gpointer value) {
    if (ui.window == NULL) return;
    Presentation *p = value;
    ui.suppress = TRUE;
    if (g_strcmp0(ui.model_rows, p->models) != 0) {
        g_free(ui.model_rows); ui.model_rows = g_strdup(p->models); populate_models();
    }
    if (g_strcmp0(ui.round_rows, p->rounds) != 0) {
        g_free(ui.round_rows); ui.round_rows = g_strdup(p->rounds);
        g_ptr_array_set_size(ui.round_ids, 0);
        GtkStringList *names = gtk_string_list_new(NULL);
        gchar **lines = g_strsplit(p->rounds, "\n", -1);
        for (guint i = 0; lines[i] != NULL; ++i) {
            gchar **fields = g_strsplit(lines[i], "\t", 2);
            if (g_strv_length(fields) == 2) {
                g_ptr_array_add(ui.round_ids, g_strdup(fields[0]));
                gtk_string_list_append(names, fields[1]);
            }
            g_strfreev(fields);
        }
        g_strfreev(lines);
        gtk_drop_down_set_model(ui.rounds, G_LIST_MODEL(names)); g_object_unref(names);
    }
    for (guint i = 0; i < ui.round_ids->len; ++i)
        if (g_strcmp0(g_ptr_array_index(ui.round_ids, i), p->selected) == 0) gtk_drop_down_set_selected(ui.rounds, i);
    if (g_strcmp0(ui.selected, p->selected) != 0) gtk_editable_set_text(GTK_EDITABLE(ui.ranks), "");
    g_free(ui.selected); ui.selected = g_strdup(p->selected);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.detail), p->detail, -1);
    GtkWidget *settings[] = {GTK_WIDGET(ui.mode), GTK_WIDGET(ui.models), GTK_WIDGET(ui.language), GTK_WIDGET(ui.run)};
    for (guint i = 0; i < G_N_ELEMENTS(settings); ++i) gtk_widget_set_sensitive(settings[i], !p->busy);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop), p->recording);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), p->busy);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.judge), p->judgeable);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.ranks), p->judgeable);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.json), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.markdown), !p->busy && ui.round_ids->len > 0);
    ui.suppress = FALSE;
}
int32_t jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                               const char *selected, int32_t busy, int32_t recording, int32_t judgeable) {
    if (models == NULL || rounds == NULL || detail == NULL || selected == NULL) return -1;
    Presentation *p = g_new0(Presentation, 1);
    p->models = g_strdup(models); p->rounds = g_strdup(rounds); p->detail = g_strdup(detail);
    p->selected = g_strdup(selected); p->busy = busy != 0; p->recording = recording != 0; p->judgeable = judgeable != 0;
    return jsti_window_post(present, p, free_presentation);
}

static Presentation fixture(gboolean revealed) {
    Presentation p = {
        .models = "test/file-a\tFile A\t0\ntest/file-b\tFile B\t0\ntest/live-a\tLive A\t1\ntest/live-b\tLive B\t1",
        .rounds = "synthetic-round\tSynthetic sample.wav", .selected = "synthetic-round",
        .detail = revealed
            ? "Synthetic judged comparison\n\nResult A - File A (rank 2)\nCould we meet Friday?\n"
              "\nResult B - File B (rank 1)\nCould we meet on Friday?\n\nScoreboard\nFile B: 1 win\nFile A: 0 wins"
            : "Synthetic sample.wav\n\nResult A\nCould we meet Friday?\n\nResult B\nCould we meet on Friday?\n"
              "\nRank every blind result to reveal models.",
        .judgeable = !revealed
    };
    return p;
}

static void finish_fixture(void) {
    if (ui.window != NULL) gtk_window_close(ui.window);
    testing = FALSE;
    g_clear_pointer(&test_payload, g_free);
}

int32_t jsti_comparison_self_test(GtkWindow *parent, char *error, size_t capacity) {
    testing = TRUE;
    jsti_comparison_open(parent);
    Presentation p = fixture(FALSE);
    present(&p);
    gboolean valid = ui.model_ids->len == 2 && ui.round_ids->len == 1
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.judge));
    gtk_drop_down_set_selected(ui.mode, 1);
    for (guint i = 0; i < ui.model_ids->len; ++i) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.models, (int)i);
        GtkCheckButton *check = GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row));
        valid = valid && GTK_IS_LABEL(gtk_check_button_get_child(check))
            && gtk_label_get_wrap(GTK_LABEL(gtk_check_button_get_child(check)));
        gtk_check_button_set_active(check, TRUE);
    }
    gtk_editable_set_text(GTK_EDITABLE(ui.language), "en_GB");
    g_signal_emit_by_name(ui.run, "clicked");
    valid = valid && test_event == 103 && g_strcmp0(test_payload, "en_GB\ntest/live-a\ttest/live-b") == 0;
    gtk_editable_set_text(GTK_EDITABLE(ui.ranks), "2,1");
    g_signal_emit_by_name(ui.judge, "clicked");
    valid = valid && test_event == 106 && g_strcmp0(test_payload, "synthetic-round\n2,1") == 0;
    g_signal_emit_by_name(ui.play, "clicked");
    valid = valid && test_event == 108 && g_strcmp0(test_payload, "synthetic-round") == 0;
    p.busy = TRUE; p.recording = TRUE; p.judgeable = FALSE; present(&p);
    valid = valid && !gtk_widget_get_sensitive(GTK_WIDGET(ui.run))
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.stop)) && !gtk_widget_get_sensitive(GTK_WIDGET(ui.judge));
    finish_fixture();
    valid = valid && test_event == 105;
    if (!valid) jsti_set_error(error, capacity, "Comparison selection, judging, playback or capture controls failed.");
    return valid ? 0 : -1;
}

typedef struct { GtkWindow *parent; gchar *directory; gboolean revealed; AdwColorScheme original; } ComparisonTour;
static gboolean comparison_snapshot(gpointer value) {
    ComparisonTour *tour = value;
    const char *name = tour->revealed ? "comparison-revealed-dark.png" : "comparison-blind-light.png";
    gchar *path = g_build_filename(tour->directory, name, NULL);
    if (ui.window == NULL || jsti_widget_save_snapshot(adw_window_get_content(ADW_WINDOW(ui.window)), path, TRUE) != 0)
        g_printerr("Comparison snapshot %s failed.\n", name);
    g_free(path);
    const char *full_name = tour->revealed ? "comparison-revealed-dark-full.png" : "comparison-blind-light-full.png";
    path = g_build_filename(tour->directory, full_name, NULL);
    if (ui.window == NULL || jsti_widget_save_snapshot(ui.column, path, TRUE) != 0)
        g_printerr("Comparison snapshot %s failed.\n", full_name);
    g_free(path);
    if (!tour->revealed) {
        tour->revealed = TRUE;
        Presentation p = fixture(TRUE); present(&p);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
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
    Presentation p = fixture(FALSE); present(&p);
    g_timeout_add(700, comparison_snapshot, tour);
}
