/* The Compare Models window: its controls, model list, handlers and the
 * host's presentation. Owns Comparison (LinuxComparisonState.h). */
#include "LinuxComparisonState.h"
#include <string.h>

static Comparison ui;
Comparison *comparison_ui(void) { return &ui; }
static void models_changed(GtkCheckButton *button, gpointer data);

void comparison_error(const char *message) {
    g_warning("Comparison: %s", message);
    if (ui.window != NULL) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(ui.detail);
        gtk_text_buffer_set_text(buffer, message, -1);
        gtk_widget_grab_focus(GTK_WIDGET(ui.detail));
    }
}
static void clear_models(void) {
    while (gtk_widget_get_first_child(GTK_WIDGET(ui.models)) != NULL)
        gtk_list_box_remove(ui.models, gtk_widget_get_first_child(GTK_WIDGET(ui.models)));
    g_ptr_array_set_size(ui.model_ids, 0);
}
static gchar *model_catalogue(const char *rows) {
    GString *result = g_string_new("");
    gchar **lines = g_strsplit(rows != NULL ? rows : "", "\n", -1);
    for (guint i = 0; lines[i] != NULL; ++i) {
        gchar **fields = g_strsplit(lines[i], "\t", 4);
        if (g_strv_length(fields) >= 3)
            g_string_append_printf(result, "%s\t%s\t%s\n", fields[0], fields[1], fields[2]);
        g_strfreev(fields);
    }
    g_strfreev(lines);
    return g_string_free(result, FALSE);
}
static void restore_selection(void) {
    gchar **lines = g_strsplit(ui.model_rows != NULL ? ui.model_rows : "", "\n", -1);
    for (guint i = 0; lines[i] != NULL; ++i) {
        gchar **fields = g_strsplit(lines[i], "\t", 4);
        if (g_strv_length(fields) == 4) for (guint j = 0; j < ui.model_ids->len; ++j)
            if (g_strcmp0(fields[0], g_ptr_array_index(ui.model_ids, j)) == 0) {
                GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.models, (int)j);
                gtk_check_button_set_active(GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row)), strcmp(fields[3], "1") == 0);
            }
        g_strfreev(fields);
    }
    g_strfreev(lines);
}
static void populate_models(void) {
    clear_models();
    gboolean live = gtk_drop_down_get_selected(ui.mode) == 1;
    gchar **lines = g_strsplit(ui.model_rows != NULL ? ui.model_rows : "", "\n", -1);
    for (guint i = 0; lines[i] != NULL; ++i) {
        gchar **fields = g_strsplit(lines[i], "\t", 4);
        if (g_strv_length(fields) >= 3 && (strcmp(fields[2], "1") == 0) == live) {
            GtkWidget *check = gtk_check_button_new();
            GtkWidget *label = gtk_label_new(fields[1]);
            gtk_label_set_wrap(GTK_LABEL(label), TRUE);
            gtk_label_set_xalign(GTK_LABEL(label), 0);
            gtk_check_button_set_child(GTK_CHECK_BUTTON(check), label);
            jsti_accessible_set_name(check, fields[1]);
            gtk_list_box_append(ui.models, check);
            g_ptr_array_add(ui.model_ids, g_strdup(fields[0]));
            gtk_check_button_set_active(GTK_CHECK_BUTTON(check),
                                        g_strv_length(fields) == 4 && strcmp(fields[3], "1") == 0);
            g_signal_connect(check, "toggled", G_CALLBACK(models_changed), NULL);
        }
        g_strfreev(fields);
    }
    g_strfreev(lines);
    gtk_button_set_label(ui.run, live ? "Start microphone" : "Choose samples and run…");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.run), ui.model_ids->len >= 2);
}
static void models_changed(GtkCheckButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.suppress) return;
    GString *selected = g_string_new("");
    for (guint i = 0; i < ui.model_ids->len; ++i) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.models, (int)i);
        if (gtk_check_button_get_active(GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row)))) {
            if (selected->len > 0) g_string_append_c(selected, '\t');
            g_string_append(selected, g_ptr_array_index(ui.model_ids, i));
        }
    }
    comparison_emit(125, selected->str, gtk_drop_down_get_selected(ui.mode) == 1);
    g_string_free(selected, TRUE);
}
static void select_models(GtkButton *button, gpointer data) {
    (void)data;
    ui.suppress = TRUE;
    for (guint i = 0; i < ui.model_ids->len; ++i) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.models, (int)i);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(gtk_list_box_row_get_child(row)), button == ui.select_all);
    }
    ui.suppress = FALSE;
    models_changed(NULL, NULL);
}
static void reference_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint row = gtk_drop_down_get_selected(ui.reference);
    if (!ui.suppress && row < ui.reference_ids->len)
        comparison_emit(124, g_ptr_array_index(ui.reference_ids, row), 0);
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
    gboolean live = gtk_drop_down_get_selected(ui.mode) == 1;
    if (count < 2 || (live && count > 8)) {
        comparison_error(live ? "Select two to eight Live models." : "Select at least two File models.");
        g_string_free(payload, TRUE); return;
    }
    if (live) {
        comparison_emit(103, payload->str, 0); g_string_free(payload, TRUE); return;
    }
    comparison_choose_samples(payload);
}
static void action_clicked(GtkButton *button, gpointer data) {
    (void)data;
    if (button == ui.stop) comparison_emit(104, "", 0);
    if (button == ui.cancel) comparison_emit(105, "", 0);
    if (button == ui.next_file && gtk_widget_get_sensitive(GTK_WIDGET(button)) && ui.batch_round != NULL)
        comparison_emit(128, ui.batch_round, 0);
    if (button == ui.play) comparison_emit(108, ui.selected != NULL ? ui.selected : "", 0);
    if (button == ui.stop_audio) comparison_emit(109, "", 0);
    if (button == ui.sync_now) comparison_emit(122, "", 0);
    if (button == ui.judge) {
        gchar *payload = g_strdup_printf("%s\n%s", ui.selected != NULL ? ui.selected : "",
                                        gtk_editable_get_text(GTK_EDITABLE(ui.ranks)));
        comparison_emit(106, payload, 0); g_free(payload);
    }
}
static void sync_changed(GtkCheckButton *button, gpointer data) {
    (void)data;
    if (!ui.suppress) comparison_emit(121, "", gtk_check_button_get_active(button));
}
static void save_history_changed(GtkCheckButton *button, gpointer data) {
    (void)data;
    if (!ui.suppress) comparison_emit(129, "", gtk_check_button_get_active(button));
}
static gboolean closing(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    comparison_emit(123, "", 0);
    ui.window = NULL;
    g_clear_pointer(&ui.selected, g_free);
    g_clear_pointer(&ui.model_rows, g_free);
    g_clear_pointer(&ui.round_rows, g_free);
    g_clear_pointer(&ui.reference_rows, g_free);
    g_clear_pointer(&ui.batch_round, g_free);
    g_clear_pointer(&ui.model_ids, g_ptr_array_unref);
    g_clear_pointer(&ui.round_ids, g_ptr_array_unref);
    g_clear_pointer(&ui.reference_ids, g_ptr_array_unref);
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
    ui.reference_ids = g_ptr_array_new_with_free_func(g_free);
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
    ui.mode = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(modes));
    jsti_accessible_set_name(GTK_WIDGET(ui.mode), "Comparison input");
    g_signal_connect(ui.mode, "notify::selected", G_CALLBACK(mode_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.mode));
    ui.language = GTK_ENTRY(gtk_entry_new());
    gtk_entry_set_placeholder_text(ui.language, "Language hint (e.g. en_GB); blank is Automatic");
    jsti_accessible_set_name(GTK_WIDGET(ui.language), "Comparison language hint");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.language));
    heading(GTK_BOX(column), "Models (at least two; Live supports up to eight)");
    GtkWidget *selection = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.select_all = GTK_BUTTON(button_new("Select all ready", G_CALLBACK(select_models)));
    ui.select_none = GTK_BUTTON(button_new("Select none", G_CALLBACK(select_models)));
    gtk_box_append(GTK_BOX(selection), GTK_WIDGET(ui.select_all));
    gtk_box_append(GTK_BOX(selection), GTK_WIDGET(ui.select_none));
    gtk_box_append(GTK_BOX(column), selection);
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
    jsti_accessible_set_name(GTK_WIDGET(ui.rounds), "Saved comparison rounds");
    g_signal_connect(ui.rounds, "notify::selected", G_CALLBACK(round_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.rounds));
    GtkWidget *playback = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.play = GTK_BUTTON(button_new("Play sample", G_CALLBACK(action_clicked)));
    ui.stop_audio = GTK_BUTTON(button_new("Stop audio", G_CALLBACK(action_clicked)));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.play));
    gtk_box_append(GTK_BOX(playback), GTK_WIDGET(ui.stop_audio));
    gtk_box_append(GTK_BOX(column), playback);
    heading(GTK_BOX(column), "Diff against");
    ui.reference = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(NULL));
    jsti_accessible_set_name(GTK_WIDGET(ui.reference), "Blind word-diff reference");
    g_signal_connect(ui.reference, "notify::selected", G_CALLBACK(reference_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.reference));
    ui.detail = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(ui.detail, FALSE); gtk_text_view_set_wrap_mode(ui.detail, GTK_WRAP_WORD_CHAR);
    jsti_accessible_set_name(GTK_WIDGET(ui.detail), "Blind results and scoreboard");
    GtkWidget *detail_scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(detail_scroll, -1, 240);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroll), GTK_WIDGET(ui.detail));
    gtk_box_append(GTK_BOX(column), detail_scroll);
    heading(GTK_BOX(column), "Ranks for A, B, ... (e.g. 2,1,3; rank failures too)");
    ui.ranks = GTK_ENTRY(gtk_entry_new()); jsti_accessible_set_name(GTK_WIDGET(ui.ranks), "Ranks in blind order");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.ranks));
    ui.judge = GTK_BUTTON(button_new("Save ranking and reveal", G_CALLBACK(action_clicked)));
    ui.next_file = GTK_BUTTON(button_new("Next file", G_CALLBACK(action_clicked)));
    jsti_accessible_set_name(GTK_WIDGET(ui.next_file), "Next file");
    gtk_widget_set_visible(GTK_WIDGET(ui.next_file), FALSE);
    GtkWidget *judging = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(judging), GTK_WIDGET(ui.judge));
    gtk_box_append(GTK_BOX(judging), GTK_WIDGET(ui.next_file));
    gtk_box_append(GTK_BOX(column), judging);
    heading(GTK_BOX(column), "Export transcripts and model identities (no audio)");
    const char *scopes[] = {"All rounds", "Selected round", NULL};
    ui.export_scope = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(scopes));
    jsti_accessible_set_name(GTK_WIDGET(ui.export_scope), "Comparison export scope");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.export_scope));
    GtkWidget *exports = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.json = GTK_BUTTON(button_new("Save JSON…", G_CALLBACK(comparison_export_clicked)));
    ui.markdown = GTK_BUTTON(button_new("Save Markdown…", G_CALLBACK(comparison_export_clicked)));
    gtk_box_append(GTK_BOX(exports), GTK_WIDGET(ui.json)); gtk_box_append(GTK_BOX(exports), GTK_WIDGET(ui.markdown));
    gtk_box_append(GTK_BOX(column), exports);
    GtkWidget *copies = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    ui.copy_json = GTK_BUTTON(button_new("Copy JSON", G_CALLBACK(comparison_copy_export)));
    ui.copy_markdown = GTK_BUTTON(button_new("Copy Markdown", G_CALLBACK(comparison_copy_export)));
    gtk_box_append(GTK_BOX(copies), GTK_WIDGET(ui.copy_json));
    gtk_box_append(GTK_BOX(copies), GTK_WIDGET(ui.copy_markdown));
    gtk_box_append(GTK_BOX(column), copies);
    ui.delete_round = GTK_BUTTON(button_new("Delete / discard saved round…", G_CALLBACK(comparison_delete_clicked)));
    gtk_widget_add_css_class(GTK_WIDGET(ui.delete_round), "destructive-action");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.delete_round));
    ui.sync = GTK_CHECK_BUTTON(gtk_check_button_new());
    GtkWidget *sync_label = gtk_label_new("Sync comparison transcripts and rankings with iCloud");
    gtk_label_set_wrap(GTK_LABEL(sync_label), TRUE); gtk_label_set_xalign(GTK_LABEL(sync_label), 0);
    gtk_check_button_set_child(ui.sync, sync_label);
    jsti_accessible_set_name(GTK_WIDGET(ui.sync), "Sync comparison transcripts and rankings with iCloud");
    g_signal_connect(ui.sync, "toggled", G_CALLBACK(sync_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.sync));
    ui.sync_now = GTK_BUTTON(button_new("Sync now / retry", G_CALLBACK(action_clicked)));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.sync_now));
    ui.save_history = GTK_CHECK_BUTTON(gtk_check_button_new());
    GtkWidget *history_label = gtk_label_new("Save results to History (one item per model, including failures)");
    gtk_label_set_wrap(GTK_LABEL(history_label), TRUE); gtk_label_set_xalign(GTK_LABEL(history_label), 0);
    gtk_check_button_set_child(ui.save_history, history_label);
    jsti_accessible_set_name(GTK_WIDGET(ui.save_history),
        "Save results to History, one item per model, including failures");
    g_signal_connect(ui.save_history, "toggled", G_CALLBACK(save_history_changed), NULL);
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ui.save_history));
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), column);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), scrolled);
    adw_window_set_content(ADW_WINDOW(ui.window), toolbar);
    gtk_window_present(ui.window);
    comparison_emit(100, "", 0);
}
static void free_presentation(gpointer value) {
    Presentation *p = value;
    g_free(p->models); g_free(p->rounds); g_free(p->detail); g_free(p->selected);
    g_free(p->references); g_free(p->reference); g_free(p->batch_round); g_free(p);
}
void comparison_present(gpointer value) {
    if (ui.window == NULL) return;
    Presentation *p = value;
    ui.suppress = TRUE;
    if (g_strcmp0(ui.model_rows, p->models) != 0) {
        gchar *previous = model_catalogue(ui.model_rows), *next = model_catalogue(p->models);
        gboolean same = g_strcmp0(previous, next) == 0;
        g_free(previous); g_free(next);
        g_free(ui.model_rows); ui.model_rows = g_strdup(p->models);
        if (same) restore_selection(); else populate_models();
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
    if (g_strcmp0(ui.reference_rows, p->references) != 0) {
        g_free(ui.reference_rows); ui.reference_rows = g_strdup(p->references);
        g_ptr_array_set_size(ui.reference_ids, 0);
        GtkStringList *names = gtk_string_list_new(NULL);
        gchar **lines = g_strsplit(p->references != NULL ? p->references : "", "\n", -1);
        for (guint i = 0; lines[i] != NULL; ++i) {
            gchar **fields = g_strsplit(lines[i], "\t", 2);
            if (g_strv_length(fields) == 2) {
                g_ptr_array_add(ui.reference_ids, g_strdup(fields[0]));
                gtk_string_list_append(names, fields[1]);
            }
            g_strfreev(fields);
        }
        g_strfreev(lines);
        gtk_drop_down_set_model(ui.reference, G_LIST_MODEL(names)); g_object_unref(names);
    }
    for (guint i = 0; i < ui.reference_ids->len; ++i)
        if (g_strcmp0(g_ptr_array_index(ui.reference_ids, i), p->reference) == 0)
            gtk_drop_down_set_selected(ui.reference, i);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.reference), ui.reference_ids->len > 0);
    if (g_strcmp0(ui.selected, p->selected) != 0) gtk_editable_set_text(GTK_EDITABLE(ui.ranks), "");
    g_free(ui.selected); ui.selected = g_strdup(p->selected);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.detail), p->detail, -1);
    gboolean batch = p->batch_round != NULL && p->batch_round[0] != '\0';
    g_free(ui.batch_round); ui.batch_round = g_strdup(p->batch_round);
    GtkWidget *settings[] = {GTK_WIDGET(ui.mode), GTK_WIDGET(ui.models), GTK_WIDGET(ui.language)};
    for (guint i = 0; i < G_N_ELEMENTS(settings); ++i) gtk_widget_set_sensitive(settings[i], !p->busy && !batch);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.select_all), !p->busy && !batch);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.select_none), !p->busy && !batch);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop), p->recording);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), p->busy || batch);
    gtk_widget_set_visible(GTK_WIDGET(ui.next_file), batch);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.next_file), p->can_next && !p->busy && p->batch_remaining > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.judge), p->judgeable);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.ranks), p->judgeable);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.json), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.markdown), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy_json), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy_markdown), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.export_scope), !p->busy && ui.round_ids->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.delete_round), !p->busy && p->selected[0] != '\0');
    gtk_widget_set_sensitive(GTK_WIDGET(ui.run), !p->busy && !batch && ui.model_ids->len >= 2);
    gtk_check_button_set_active(ui.sync, p->sync_enabled);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.sync), p->sync_available);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.sync_now), p->sync_available && p->sync_enabled);
    ui.suppress = FALSE;
}
int32_t jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                               const char *selected, int32_t busy, int32_t recording, int32_t judgeable,
                               int32_t sync_enabled, int32_t sync_available,
                               const char *references, const char *reference) {
    return jsti_comparison_present_batch(models, rounds, detail, selected, busy, recording, judgeable,
        sync_enabled, sync_available, references, reference, "", 0, 0);
}
int32_t jsti_comparison_present_batch(const char *models, const char *rounds, const char *detail,
                                     const char *selected, int32_t busy, int32_t recording, int32_t judgeable,
                                     int32_t sync_enabled, int32_t sync_available,
                                     const char *references, const char *reference,
                                     const char *batch_round, int32_t batch_remaining, int32_t can_next) {
    if (models == NULL || rounds == NULL || detail == NULL || selected == NULL
        || references == NULL || reference == NULL || batch_round == NULL || batch_remaining < 0) return -1;
    Presentation *p = g_new0(Presentation, 1);
    p->models = g_strdup(models); p->rounds = g_strdup(rounds); p->detail = g_strdup(detail);
    p->selected = g_strdup(selected); p->busy = busy != 0; p->recording = recording != 0; p->judgeable = judgeable != 0;
    p->sync_enabled = sync_enabled != 0; p->sync_available = sync_available != 0;
    p->references = g_strdup(references); p->reference = g_strdup(reference);
    p->batch_round = g_strdup(batch_round); p->batch_remaining = batch_remaining; p->can_next = can_next != 0;
    return jsti_window_post(comparison_present, p, free_presentation);
}
void comparison_present_save_history(gpointer value) {
    if (ui.window == NULL) return;
    ui.suppress = TRUE;
    gtk_check_button_set_active(ui.save_history, *(gboolean *)value);
    ui.suppress = FALSE;
}
int32_t jsti_comparison_set_save_history(int32_t enabled) {
    gboolean *state = g_new(gboolean, 1);
    *state = enabled != 0;
    return jsti_window_post(comparison_present_save_history, state, g_free);
}

