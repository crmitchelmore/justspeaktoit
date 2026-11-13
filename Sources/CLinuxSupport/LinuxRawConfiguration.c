#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * General > Edit raw configuration (#1670): every setting as JSON, checked
 * and saved by the shared host (DesktopHostRawConfiguration) with the same
 * schema and validator as macOS, iOS, Android and `speak config`. This window
 * only edits text and picks files; each action is JSTI_EVENT_RAW_CONFIGURATION
 * with its DesktopRawConfigurationAction as the index, and the host answers
 * through jsti_window_set_raw_configuration in the order it was asked.
 */

enum { ACTION_LOAD, ACTION_VALIDATE, ACTION_APPLY, ACTION_DEFAULTS, ACTION_IMPORT, ACTION_EXPORT };

typedef struct RawConfiguration {
    GtkWindow *owner;
    GtkWindow *window;
    GtkTextBuffer *buffer;
    GtkWidget *editor, *status, *issues, *issues_scroll;
    GtkWidget *reset, *import, *export, *close, *validate, *apply;
    /* Requests the host has not answered; answers to `discard` of them, sent
     * before the window last closed, are dropped. */
    gint outstanding, discard;
} RawConfiguration;

static RawConfiguration raw;
static void (*raw_emit)(int32_t event, const char *text, int32_t index) = jsti_window_emit;
static void (*raw_choose)(gboolean saving) = NULL;

static void set_busy(gboolean busy) {
    if (raw.window == NULL) return;
    GtkWidget *actions[] = { raw.reset, raw.import, raw.export, raw.validate, raw.apply };
    for (gsize i = 0; i < G_N_ELEMENTS(actions); i++) gtk_widget_set_sensitive(actions[i], !busy);
}

static void request(gint action, const char *text) {
    raw.outstanding++;
    set_busy(TRUE);
    raw_emit(JSTI_EVENT_RAW_CONFIGURATION, text != NULL ? text : "", action);
}

static gchar *editor_text(void) {
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(raw.buffer, &start, &end);
    return gtk_text_buffer_get_text(raw.buffer, &start, &end, FALSE);
}

static void show_outcome(const char *text, const char *status, const char *issues, gboolean failed) {
    if (text != NULL) gtk_text_buffer_set_text(raw.buffer, text, -1);
    gtk_label_set_text(GTK_LABEL(raw.status), status != NULL ? status : "");
    if (failed) gtk_widget_add_css_class(raw.status, "error");
    else gtk_widget_remove_css_class(raw.status, "error");
    gboolean has_issues = issues != NULL && *issues != '\0';
    gtk_label_set_text(GTK_LABEL(raw.issues), has_issues ? issues : "");
    gtk_widget_set_visible(raw.issues_scroll, has_issues);
}

static void on_validate(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gchar *text = editor_text();
    request(ACTION_VALIDATE, text);
    g_free(text);
}

static void on_apply(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gchar *text = editor_text();
    request(ACTION_APPLY, text);
    g_free(text);
}

static void on_reset(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    request(ACTION_DEFAULTS, "");
}

static void local_error(const char *status, const char *issue) {
    show_outcome(NULL, status, issue, TRUE);
    gchar *spoken = g_strdup_printf("%s %s", status, issue);
    jsti_accessible_announce(raw.status, spoken, 1);
    g_free(spoken);
}

static void chosen_path(gboolean saving, const char *path) {
    if (raw.window == NULL || path == NULL) return;
    if (strchr(path, '\n') != NULL) {
        local_error(saving ? "Could not export." : "Could not import.", "Choose a file whose name has no line breaks.");
        return;
    }
    if (!saving) { request(ACTION_IMPORT, path); return; }
    gchar *text = editor_text();
    gchar *payload = g_strdup_printf("%s\n%s", path, text);
    request(ACTION_EXPORT, payload);
    g_free(payload);
    g_free(text);
}

static void file_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    gboolean saving = GPOINTER_TO_INT(data);
    GError *error = NULL;
    GFile *file = saving ? gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error)
                         : gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL) chosen_path(saving, path);
        else if (raw.window != NULL) local_error("Could not use that file.", "Choose a file on this computer.");
        g_free(path);
        g_object_unref(file);
    }
    g_clear_error(&error); /* Cancelled by the user. */
}

static void choose_file(gboolean saving) {
    if (raw_choose != NULL) { raw_choose(saving); return; }
    GtkFileDialog *picker = gtk_file_dialog_new();
    GtkFileFilter *json = gtk_file_filter_new();
    gtk_file_filter_set_name(json, "JSON");
    gtk_file_filter_add_suffix(json, "json");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, json);
    gtk_file_dialog_set_filters(picker, G_LIST_MODEL(filters));
    if (saving) {
        gtk_file_dialog_set_title(picker, "Export raw configuration");
        gtk_file_dialog_set_initial_name(picker, "JustSpeakToIt-settings.json");
        gtk_file_dialog_save(picker, raw.window, NULL, file_chosen, GINT_TO_POINTER(TRUE));
    } else {
        gtk_file_dialog_set_title(picker, "Import raw configuration");
        gtk_file_dialog_open(picker, raw.window, NULL, file_chosen, GINT_TO_POINTER(FALSE));
    }
    g_object_unref(filters);
    g_object_unref(json);
    g_object_unref(picker);
}

static void on_import(GtkButton *button, gpointer data) { (void)button; (void)data; choose_file(FALSE); }
static void on_export(GtkButton *button, gpointer data) { (void)button; (void)data; choose_file(TRUE); }
static void on_close(GtkButton *button, gpointer data) { (void)button; (void)data; gtk_window_close(raw.window); }

static gboolean closing(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    raw.discard = raw.outstanding;
    return FALSE;
}

static void destroyed(GtkWidget *window, gpointer data) {
    (void)window; (void)data;
    raw.window = NULL;
    raw.buffer = NULL;
}

static GtkWidget *action_button(const char *label, const char *name, GCallback handler) {
    GtkWidget *button = gtk_button_new_with_mnemonic(label);
    gtk_widget_set_name(button, name);
    g_signal_connect(button, "clicked", handler, NULL);
    return button;
}

static void open_window(void) {
    if (raw.window != NULL) { gtk_window_present(raw.window); return; }
    GtkWidget *column;
    raw.window = jsti_tool_window_new(raw.owner, "Edit raw configuration", 640, &column);
    gtk_window_set_default_size(raw.window, 720, 640);
    gtk_widget_set_name(GTK_WIDGET(raw.window), "rawConfigurationWindow");
    g_signal_connect(raw.window, "close-request", G_CALLBACK(closing), NULL);
    g_signal_connect(raw.window, "destroy", G_CALLBACK(destroyed), NULL);
    gtk_box_set_spacing(GTK_BOX(column), 12);

    GtkWidget *description = gtk_label_new(
        "Every setting as JSON. Changes are checked before they are saved, and nothing is saved unless all of "
        "them are valid. API keys are never shown; \"apiKeys\" lists only whether each is stored. Settings "
        "that only this computer can change, such as automation access, are kept as they are.");
    gtk_label_set_wrap(GTK_LABEL(description), TRUE);
    gtk_label_set_xalign(GTK_LABEL(description), 0);
    gtk_widget_add_css_class(description, "dim-label");
    gtk_box_append(GTK_BOX(column), description);

    raw.editor = gtk_text_view_new();
    raw.buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(raw.editor));
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(raw.editor), TRUE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(raw.editor), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(raw.editor), 8);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(raw.editor), 8);
    gtk_widget_set_name(raw.editor, "rawConfigurationEditor");
    gtk_accessible_update_property(GTK_ACCESSIBLE(raw.editor),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Raw configuration JSON", -1);
    gtk_text_buffer_set_text(raw.buffer, "", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), raw.editor);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_add_css_class(scroll, "card");
    gtk_box_append(GTK_BOX(column), scroll);

    raw.status = GTK_WIDGET(g_object_new(GTK_TYPE_LABEL, "label", "Loading the current configuration…",
                                         "accessible-role", GTK_ACCESSIBLE_ROLE_STATUS, NULL));
    gtk_label_set_wrap(GTK_LABEL(raw.status), TRUE);
    gtk_label_set_xalign(GTK_LABEL(raw.status), 0);
    gtk_widget_set_name(raw.status, "rawConfigurationStatus");
    gtk_box_append(GTK_BOX(column), raw.status);

    raw.issues = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(raw.issues), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(raw.issues), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(raw.issues), 0);
    gtk_label_set_yalign(GTK_LABEL(raw.issues), 0);
    gtk_widget_set_name(raw.issues, "rawConfigurationIssues");
    gtk_accessible_update_property(GTK_ACCESSIBLE(raw.issues),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Configuration issues", -1);
    raw.issues_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(raw.issues_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(raw.issues_scroll), 120);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(raw.issues_scroll), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(raw.issues_scroll), raw.issues);
    gtk_widget_set_can_focus(raw.issues_scroll, FALSE);
    gtk_widget_set_visible(raw.issues_scroll, FALSE);
    gtk_box_append(GTK_BOX(column), raw.issues_scroll);

    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    raw.reset = action_button("_Reset to Defaults", "rawConfigurationReset", G_CALLBACK(on_reset));
    gtk_widget_set_tooltip_text(raw.reset, "Fill the editor with default values. Nothing is saved until you apply.");
    raw.import = action_button("_Import…", "rawConfigurationImport", G_CALLBACK(on_import));
    raw.export = action_button("E_xport…", "rawConfigurationExport", G_CALLBACK(on_export));
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    raw.close = action_button("_Close", "rawConfigurationClose", G_CALLBACK(on_close));
    raw.validate = action_button("_Validate", "rawConfigurationValidate", G_CALLBACK(on_validate));
    raw.apply = action_button("_Apply", "rawConfigurationApply", G_CALLBACK(on_apply));
    gtk_widget_add_css_class(raw.apply, "suggested-action");
    GtkWidget *buttons[] = { raw.reset, raw.import, raw.export, spacer, raw.close, raw.validate, raw.apply };
    for (gsize i = 0; i < G_N_ELEMENTS(buttons); i++) gtk_box_append(GTK_BOX(footer), buttons[i]);
    gtk_box_append(GTK_BOX(column), footer);

    gtk_window_present(raw.window);
    gtk_widget_grab_focus(raw.editor);
    request(ACTION_LOAD, "");
}

static void on_open(GtkButton *button, gpointer data) { (void)button; (void)data; open_window(); }

struct _GtkWidget *jsti_raw_configuration_group_new(struct _GtkWindow *owner) {
    raw.owner = owner;
    GtkWidget *group = adw_preferences_group_new();
    GtkWidget *row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), "Edit raw configuration");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row),
        "View, validate, import or export every setting as JSON, or reset to defaults.");
    adw_action_row_set_subtitle_lines(ADW_ACTION_ROW(row), 0);
    GtkWidget *open = gtk_button_new_with_label("Edit…");
    gtk_widget_set_valign(open, GTK_ALIGN_CENTER);
    gtk_widget_set_name(open, "rawConfigurationOpen");
    jsti_accessible_set_name(open, "Edit raw configuration");
    g_signal_connect(open, "clicked", G_CALLBACK(on_open), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(row), open);
    adw_action_row_set_activatable_widget(ADW_ACTION_ROW(row), open);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), row);
    g_object_set_data(G_OBJECT(group), "jsti-raw-configuration-open", open);
    return group;
}

typedef struct Outcome {
    gchar *text, *status, *issues, *announcement;
    gboolean failed;
} Outcome;

static void outcome_free(gpointer data) {
    Outcome *o = data;
    g_free(o->text); g_free(o->status); g_free(o->issues); g_free(o->announcement); g_free(o);
}

static void outcome_apply(gpointer data) {
    Outcome *o = data;
    if (raw.outstanding > 0) raw.outstanding--;
    if (raw.discard > 0) { raw.discard--; return; }
    if (raw.window == NULL) return;
    set_busy(raw.outstanding > raw.discard);
    show_outcome(o->text, o->status, o->issues, o->failed);
    if (o->announcement != NULL && *o->announcement != '\0') {
        jsti_accessible_announce(raw.status, o->announcement, o->failed ? 1 : 0);
    }
}

static gboolean valid_utf8(const char *text) { return text == NULL || g_utf8_validate(text, -1, NULL); }

int32_t jsti_window_set_raw_configuration(
    const char *text, const char *status, const char *issues, const char *announcement, int32_t failed) {
    if (!valid_utf8(text) || !valid_utf8(status) || !valid_utf8(issues) || !valid_utf8(announcement)) return -1;
    Outcome *o = g_new0(Outcome, 1);
    o->text = g_strdup(text);
    o->status = g_strdup(status);
    o->issues = g_strdup(issues);
    o->announcement = g_strdup(announcement);
    o->failed = failed != 0;
    return jsti_window_post(outcome_apply, o, outcome_free);
}

/* --------------------------------------------------------------- self-test */

typedef struct RawEmitted {
    gint calls;
    gint32 event, index;
    gchar *text;
    gint chooser_calls;
    gboolean chooser_saving;
} RawEmitted;

static RawEmitted raw_emitted;

static void record_raw_emit(int32_t event, const char *text, int32_t index) {
    raw_emitted.calls++;
    raw_emitted.event = event;
    raw_emitted.index = index;
    g_free(raw_emitted.text);
    raw_emitted.text = g_strdup(text);
}

static void record_raw_choose(gboolean saving) {
    raw_emitted.chooser_calls++;
    raw_emitted.chooser_saving = saving;
}

static void answer(const char *text, const char *status, const char *issues, gboolean failed) {
    Outcome o = { (gchar *)text, (gchar *)status, (gchar *)issues, (gchar *)status, failed };
    outcome_apply(&o);
}

static const char *check_raw_configuration(void) {
    if (jsti_window_set_raw_configuration(NULL, "\xff", NULL, NULL, 0) != -1) return "invalid UTF-8 was accepted";
    open_window();
    if (raw.window == NULL || gtk_window_get_transient_for(raw.window) != raw.owner) {
        return "the raw configuration window did not open over the main window";
    }
    if (raw_emitted.calls != 1 || raw_emitted.event != JSTI_EVENT_RAW_CONFIGURATION ||
        raw_emitted.index != ACTION_LOAD) {
        return "opening the raw configuration window did not ask for the saved settings";
    }
    if (gtk_widget_get_sensitive(raw.apply)) return "Apply was available before the settings loaded";
    if (gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(raw.status)) != GTK_ACCESSIBLE_ROLE_STATUS) {
        return "the raw configuration status is not a status";
    }
    answer("{\"settings\":{}}", "", "", FALSE);
    if (!gtk_widget_get_sensitive(raw.apply)) return "Apply stayed unavailable after the settings loaded";
    gchar *shown = editor_text();
    gboolean loaded = g_strcmp0(shown, "{\"settings\":{}}") == 0;
    g_free(shown);
    if (!loaded) return "the saved settings were not shown";

    gtk_text_buffer_set_text(raw.buffer, "{\"settings\":{\"showHUD\":1}}", -1);
    g_signal_emit_by_name(raw.apply, "clicked");
    if (raw_emitted.index != ACTION_APPLY || g_strcmp0(raw_emitted.text, "{\"settings\":{\"showHUD\":1}}") != 0) {
        return "Apply did not send the editor's JSON";
    }
    answer(NULL, "The configuration is not valid. Nothing was saved.", "Error: settings.showHUD: Expected a boolean.",
           TRUE);
    shown = editor_text();
    gboolean kept = g_strcmp0(shown, "{\"settings\":{\"showHUD\":1}}") == 0;
    g_free(shown);
    if (!kept) return "a rejected Apply replaced the user's text";
    if (!gtk_widget_get_visible(raw.issues_scroll) || !gtk_widget_has_css_class(raw.status, "error")) {
        return "a rejected Apply did not show its errors";
    }
    answer(NULL, "Valid. Nothing to change.", "", FALSE);
    if (gtk_widget_get_visible(raw.issues_scroll) || gtk_widget_has_css_class(raw.status, "error")) {
        return "a valid result kept the previous errors";
    }

    g_signal_emit_by_name(raw.validate, "clicked");
    if (raw_emitted.index != ACTION_VALIDATE) return "Validate did not ask the host";
    answer(NULL, "Valid.", "", FALSE);
    g_signal_emit_by_name(raw.reset, "clicked");
    if (raw_emitted.index != ACTION_DEFAULTS) return "Reset to Defaults did not ask the host";
    answer("{}", "Defaults loaded. Apply to save them.", "", FALSE);

    g_signal_emit_by_name(raw.import, "clicked");
    if (raw_emitted.chooser_calls != 1 || raw_emitted.chooser_saving) return "Import did not open a file chooser";
    chosen_path(FALSE, "/tmp/in.json");
    if (raw_emitted.index != ACTION_IMPORT || g_strcmp0(raw_emitted.text, "/tmp/in.json") != 0) {
        return "Import did not send the chosen path";
    }
    answer(NULL, "Valid.", "", FALSE);
    g_signal_emit_by_name(raw.export, "clicked");
    if (raw_emitted.chooser_calls != 2 || !raw_emitted.chooser_saving) return "Export did not open a save chooser";
    chosen_path(TRUE, "/tmp/out.json");
    if (raw_emitted.index != ACTION_EXPORT || g_strcmp0(raw_emitted.text, "/tmp/out.json\n{}") != 0) {
        return "Export did not send the path and the editor's JSON";
    }
    gint before = raw_emitted.calls;
    chosen_path(TRUE, "/tmp/bad\nname.json");
    if (raw_emitted.calls != before) return "a path with a line break was sent";

    /* An answer to a request sent before the window closed never reaches the next window. */
    gtk_window_close(raw.window);
    open_window();
    answer("{\"stale\":true}", "Exported to out.json.", "", FALSE);
    shown = editor_text();
    gboolean dropped = g_strcmp0(shown, "") == 0;
    g_free(shown);
    if (!dropped) return "an answer from before the window closed was shown";
    answer("{}", "", "", FALSE);
    if (raw.outstanding != 0 || raw.discard != 0) return "the window lost count of its requests";
    return NULL;
}

int32_t jsti_raw_configuration_self_test(char *error, size_t capacity) {
    if (raw.owner == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the raw configuration row was not built");
        return -1;
    }
    raw_emit = record_raw_emit;
    raw_choose = record_raw_choose;
    const char *failure = check_raw_configuration();
    if (raw.window != NULL) gtk_window_destroy(raw.window);
    raw_emit = jsti_window_emit;
    raw_choose = NULL;
    raw.outstanding = raw.discard = 0;
    g_clear_pointer(&raw_emitted.text, g_free);
    raw_emitted = (RawEmitted){ 0 };
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
