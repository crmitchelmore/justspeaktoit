#include "LinuxWindowInternal.h"

#include <string.h>

/*
 * App profiles: a group in the main window that opens a modal editor. Swift
 * hands the editor a snapshot of drafts and the host's catalogues; Save hands
 * every draft back through a synchronous callback, which validates and either
 * accepts (the editor closes) or returns a readable reason (the editor stays
 * open with the reason shown). Nothing here decides what a profile means.
 */

typedef struct Draft {
    gchar *id, *name, *paths, *prompt, *output_language, *notes;
    gint32 transcription, polish_mode, polish_model, language;
    /* The stored-value choices this draft started with, offered while editing. */
    gboolean kept_transcription, kept_polish_model, kept_language;
} Draft;

typedef struct Editor {
    GPtrArray *drafts;             /* Draft* */
    GPtrArray *transcription_names; /* gchar* */
    GPtrArray *polish_names;
    GPtrArray *language_names;
    gchar *notice;
    jsti_profiles_fn callback;
    void *context;
    /* Widgets while the editor is open. */
    GtkWindow *window;
    GtkListBox *list;
    GtkLabel *problem;
    GtkWidget *form;
    AdwEntryRow *name_row;
    GtkTextView *paths_view;
    AdwComboRow *transcription_row;
    AdwComboRow *language_row;
    AdwComboRow *polish_mode_row;
    AdwComboRow *polish_model_row;
    AdwEntryRow *prompt_row;
    AdwEntryRow *output_language_row;
    GtkLabel *notes;
    gint selected;
    gboolean loading;
} Editor;

static Editor *editor;
static GtkButton *open_button;
static AdwPreferencesGroup *profiles_group;

static void draft_free(gpointer pointer) {
    Draft *draft = pointer;
    g_free(draft->id); g_free(draft->name); g_free(draft->paths);
    g_free(draft->prompt); g_free(draft->output_language); g_free(draft->notes);
    g_free(draft);
}

static void editor_free(Editor *value) {
    if (value == NULL) return;
    g_ptr_array_unref(value->drafts);
    g_ptr_array_unref(value->transcription_names);
    g_ptr_array_unref(value->polish_names);
    g_ptr_array_unref(value->language_names);
    g_free(value->notice);
    g_free(value);
}

/* ------------------------------------------------------ choice mapping */

/* A combo lists "Use the app setting", then "Keep the stored value" when the
 * draft started with one, then the names. These map positions to values. */
static guint choice_position(gint32 value, gboolean kept) {
    if (value == -1) return 0;
    if (value == -2) return kept ? 1 : 0;
    return (guint)value + 1 + (kept ? 1 : 0);
}

static gint32 choice_value(guint position, gboolean kept) {
    if (position == GTK_INVALID_LIST_POSITION || position == 0) return -1;
    if (kept && position == 1) return -2;
    return (gint32)position - 1 - (kept ? 1 : 0);
}

static GtkStringList *choices(GPtrArray *names, gboolean kept, const char *kept_label) {
    GtkStringList *list = gtk_string_list_new(NULL);
    gtk_string_list_append(list, "Use the app setting");
    if (kept) gtk_string_list_append(list, kept_label);
    for (guint index = 0; index < names->len; index++) gtk_string_list_append(list, g_ptr_array_index(names, index));
    return list;
}

static gchar *text_view_text(GtkTextView *view) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(view);
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}

/* ------------------------------------------------------ form <-> draft */

static Draft *current_draft(void) {
    if (editor == NULL || editor->selected < 0 || (guint)editor->selected >= editor->drafts->len) return NULL;
    return g_ptr_array_index(editor->drafts, editor->selected);
}

static void store_form(void) {
    Draft *draft = current_draft();
    if (draft == NULL || editor->loading) return;
    g_free(draft->name);
    draft->name = g_strdup(gtk_editable_get_text(GTK_EDITABLE(editor->name_row)));
    g_free(draft->paths);
    draft->paths = text_view_text(editor->paths_view);
    g_free(draft->prompt);
    draft->prompt = g_strdup(gtk_editable_get_text(GTK_EDITABLE(editor->prompt_row)));
    g_free(draft->output_language);
    draft->output_language = g_strdup(gtk_editable_get_text(GTK_EDITABLE(editor->output_language_row)));
    draft->transcription = choice_value(adw_combo_row_get_selected(editor->transcription_row), draft->kept_transcription);
    draft->language = choice_value(adw_combo_row_get_selected(editor->language_row), draft->kept_language);
    draft->polish_model = choice_value(adw_combo_row_get_selected(editor->polish_model_row), draft->kept_polish_model);
    guint mode = adw_combo_row_get_selected(editor->polish_mode_row);
    draft->polish_mode = mode == GTK_INVALID_LIST_POSITION ? 0 : (gint32)mode;
}

static void refresh_list(void);

static void load_form(void) {
    Draft *draft = current_draft();
    gtk_widget_set_sensitive(editor->form, draft != NULL);
    if (draft == NULL) return;
    editor->loading = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(editor->name_row), draft->name);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(editor->paths_view), draft->paths, -1);
    adw_combo_row_set_model(editor->transcription_row, G_LIST_MODEL(choices(
        editor->transcription_names, draft->kept_transcription, "Keep the stored model")));
    adw_combo_row_set_selected(editor->transcription_row,
                               choice_position(draft->transcription, draft->kept_transcription));
    adw_combo_row_set_model(editor->language_row, G_LIST_MODEL(choices(
        editor->language_names, draft->kept_language, "Keep the stored language")));
    adw_combo_row_set_selected(editor->language_row, choice_position(draft->language, draft->kept_language));
    adw_combo_row_set_model(editor->polish_model_row, G_LIST_MODEL(choices(
        editor->polish_names, draft->kept_polish_model, "Keep the stored polish model")));
    adw_combo_row_set_selected(editor->polish_model_row,
                               choice_position(draft->polish_model, draft->kept_polish_model));
    adw_combo_row_set_selected(editor->polish_mode_row, (guint)CLAMP(draft->polish_mode, 0, 2));
    gtk_editable_set_text(GTK_EDITABLE(editor->prompt_row), draft->prompt);
    gtk_editable_set_text(GTK_EDITABLE(editor->output_language_row), draft->output_language);
    gtk_label_set_text(editor->notes, draft->notes);
    gtk_widget_set_visible(GTK_WIDGET(editor->notes), draft->notes[0] != '\0');
    editor->loading = FALSE;
}

static void on_form_changed(void) {
    if (editor == NULL || editor->loading) return;
    store_form();
    /* Keep the list's name in step without rebuilding the selection. */
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(editor->list, editor->selected);
    Draft *draft = current_draft();
    if (row != NULL && draft != NULL) {
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), draft->name[0] != '\0' ? draft->name : "Unnamed profile");
    }
}

static void on_entry_changed(GtkEditable *editable, gpointer data) { (void)editable; (void)data; on_form_changed(); }
static void on_combo_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    on_form_changed();
}
static void on_paths_changed(GtkTextBuffer *buffer, gpointer data) { (void)buffer; (void)data; on_form_changed(); }

static void on_row_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    if (editor == NULL || editor->loading) return;
    store_form();
    editor->selected = row != NULL ? gtk_list_box_row_get_index(row) : -1;
    load_form();
}

static void refresh_list(void) {
    editor->loading = TRUE;
    gtk_list_box_remove_all(editor->list);
    for (guint index = 0; index < editor->drafts->len; index++) {
        Draft *draft = g_ptr_array_index(editor->drafts, index);
        GtkWidget *row = adw_action_row_new();
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), draft->name[0] != '\0' ? draft->name : "Unnamed profile");
        gtk_list_box_append(editor->list, row);
    }
    if (editor->selected >= (gint)editor->drafts->len) editor->selected = (gint)editor->drafts->len - 1;
    GtkListBoxRow *row = editor->selected >= 0 ? gtk_list_box_get_row_at_index(editor->list, editor->selected) : NULL;
    if (row != NULL) gtk_list_box_select_row(editor->list, row);
    editor->loading = FALSE;
    load_form();
}

/* ------------------------------------------------------------ actions */

static void on_add(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    store_form();
    Draft *draft = g_new0(Draft, 1);
    draft->id = g_strdup(""); draft->name = g_strdup("New profile"); draft->paths = g_strdup("");
    draft->prompt = g_strdup(""); draft->output_language = g_strdup(""); draft->notes = g_strdup("");
    draft->transcription = -1; draft->polish_model = -1; draft->language = -1;
    g_ptr_array_add(editor->drafts, draft);
    editor->selected = (gint)editor->drafts->len - 1;
    refresh_list();
}

static void on_remove(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (current_draft() == NULL) return;
    g_ptr_array_remove_index(editor->drafts, (guint)editor->selected);
    refresh_list();
}

static void move(gint offset) {
    store_form();
    gint target = editor->selected + offset;
    if (current_draft() == NULL || target < 0 || (guint)target >= editor->drafts->len) return;
    gpointer moving = editor->drafts->pdata[editor->selected];
    editor->drafts->pdata[editor->selected] = editor->drafts->pdata[target];
    editor->drafts->pdata[target] = moving;
    editor->selected = target;
    refresh_list();
}

static void on_up(GtkButton *button, gpointer data) { (void)button; (void)data; move(-1); }
static void on_down(GtkButton *button, gpointer data) { (void)button; (void)data; move(1); }

static void close_editor(gboolean notify_cancel) {
    if (editor == NULL) return;
    Editor *closing = editor;
    editor = NULL;
    if (notify_cancel && closing->callback != NULL) closing->callback(0, NULL, 0, closing->context, NULL, 0);
    if (closing->window != NULL) {
        GtkWindow *window = closing->window;
        closing->window = NULL;
        gtk_window_destroy(window);
    }
    editor_free(closing);
}

/* Hands every draft to Swift; returns 0 when it accepted them. */
static int32_t save(char *error, size_t capacity) {
    store_form();
    guint count = editor->drafts->len;
    JSTIProfileDraft *values = g_new0(JSTIProfileDraft, count > 0 ? count : 1);
    for (guint index = 0; index < count; index++) {
        Draft *draft = g_ptr_array_index(editor->drafts, index);
        values[index] = (JSTIProfileDraft){
            .id = draft->id, .name = draft->name, .paths = draft->paths, .prompt = draft->prompt,
            .output_language = draft->output_language, .notes = draft->notes,
            .transcription = draft->transcription, .polish_mode = draft->polish_mode,
            .polish_model = draft->polish_model, .language = draft->language,
        };
    }
    int32_t result = editor->callback != NULL
        ? editor->callback(1, values, count, editor->context, error, capacity) : -1;
    g_free(values);
    return result;
}

static void on_save(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    char problem[1024] = "";
    if (save(problem, sizeof problem) == 0) {
        close_editor(FALSE);
        return;
    }
    gtk_label_set_text(editor->problem, problem[0] != '\0' ? problem : "The profiles could not be saved.");
    gtk_widget_set_visible(GTK_WIDGET(editor->problem), TRUE);
}

static void on_cancel(GtkButton *button, gpointer data) { (void)button; (void)data; close_editor(TRUE); }

static gboolean on_editor_close(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    if (editor != NULL) {
        editor->window = NULL;
        close_editor(TRUE);
    }
    return FALSE;
}

/* --------------------------------------------------------------- layout */

static AdwComboRow *combo(AdwPreferencesGroup *group, const char *title) {
    AdwComboRow *row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title);
    adw_combo_row_set_enable_search(row, TRUE);
    g_signal_connect(row, "notify::selected", G_CALLBACK(on_combo_changed), NULL);
    adw_preferences_group_add(group, GTK_WIDGET(row));
    return row;
}

static AdwEntryRow *entry(AdwPreferencesGroup *group, const char *title) {
    AdwEntryRow *row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title);
    g_signal_connect(row, "changed", G_CALLBACK(on_entry_changed), NULL);
    adw_preferences_group_add(group, GTK_WIDGET(row));
    return row;
}

static GtkWidget *icon_button(const char *icon, const char *tooltip, GCallback handler) {
    GtkWidget *button = gtk_button_new_from_icon_name(icon);
    gtk_widget_set_tooltip_text(button, tooltip);
    gtk_accessible_update_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL, tooltip, -1);
    g_signal_connect(button, "clicked", handler, NULL);
    return button;
}

static void build_editor(void) {
    /* Widgets report changes while they are built; none may reach a draft yet. */
    editor->loading = TRUE;
    editor->selected = -1;
    GtkWidget *window = adw_window_new();
    editor->window = GTK_WINDOW(window);
    gtk_window_set_title(editor->window, "App profiles");
    gtk_window_set_modal(editor->window, TRUE);
    if (jsti_window_main() != NULL) gtk_window_set_transient_for(editor->window, jsti_window_main());
    gtk_window_set_default_size(editor->window, 820, 640);
    g_signal_connect(window, "close-request", G_CALLBACK(on_editor_close), NULL);

    GtkWidget *toolbar = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    adw_header_bar_set_show_end_title_buttons(ADW_HEADER_BAR(header), FALSE);
    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    GtkWidget *save_button = gtk_button_new_with_label("Save");
    gtk_widget_add_css_class(save_button, "suggested-action");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_cancel), NULL);
    g_signal_connect(save_button, "clicked", G_CALLBACK(on_save), NULL);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), cancel);
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), save_button);
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), header);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget *notice = gtk_label_new(editor->notice);
    gtk_label_set_wrap(GTK_LABEL(notice), TRUE);
    gtk_label_set_xalign(GTK_LABEL(notice), 0);
    gtk_widget_add_css_class(notice, "dim-label");
    gtk_widget_set_margin_start(notice, 12); gtk_widget_set_margin_end(notice, 12); gtk_widget_set_margin_top(notice, 6);
    gtk_box_append(GTK_BOX(outer), notice);
    editor->problem = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(editor->problem, TRUE);
    gtk_label_set_xalign(editor->problem, 0);
    gtk_label_set_selectable(editor->problem, TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(editor->problem), "error");
    gtk_widget_set_margin_start(GTK_WIDGET(editor->problem), 12);
    gtk_widget_set_margin_end(GTK_WIDGET(editor->problem), 12);
    gtk_widget_set_visible(GTK_WIDGET(editor->problem), FALSE);
    gtk_box_append(GTK_BOX(outer), GTK_WIDGET(editor->problem));

    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_vexpand(paned, TRUE);
    GtkWidget *side = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(side, 12); gtk_widget_set_margin_bottom(side, 12);
    gtk_widget_set_size_request(side, 220, -1);
    editor->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(editor->list), "boxed-list");
    gtk_list_box_set_selection_mode(editor->list, GTK_SELECTION_SINGLE);
    g_signal_connect(editor->list, "row-selected", G_CALLBACK(on_row_selected), NULL);
    GtkWidget *list_scroller = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(list_scroller, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list_scroller), GTK_WIDGET(editor->list));
    gtk_box_append(GTK_BOX(side), list_scroller);
    GtkWidget *list_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(list_actions), icon_button("list-add-symbolic", "Add profile", G_CALLBACK(on_add)));
    gtk_box_append(GTK_BOX(list_actions), icon_button("list-remove-symbolic", "Remove profile", G_CALLBACK(on_remove)));
    gtk_box_append(GTK_BOX(list_actions), icon_button("go-up-symbolic", "Move up (earlier profiles win)", G_CALLBACK(on_up)));
    gtk_box_append(GTK_BOX(list_actions), icon_button("go-down-symbolic", "Move down", G_CALLBACK(on_down)));
    gtk_box_append(GTK_BOX(side), list_actions);
    gtk_paned_set_start_child(GTK_PANED(paned), side);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);

    GtkWidget *page = adw_preferences_page_new();
    editor->form = page;
    AdwPreferencesGroup *identity = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(identity, "Profile");
    editor->name_row = entry(identity, "Name");
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), identity);
    AdwPreferencesGroup *apps = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(apps, "Applications");
    adw_preferences_group_set_description(
        apps, "One per line: a full executable path (for example /usr/bin/gedit) or an X11 window class "
              "(for example gedit or gnome-terminal-server). Matching works only on X11: on Wayland the desktop "
              "does not tell apps which window is focused, so your normal settings apply there.");
    editor->paths_view = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_monospace(editor->paths_view, TRUE);
    gtk_text_view_set_top_margin(editor->paths_view, 6); gtk_text_view_set_bottom_margin(editor->paths_view, 6);
    gtk_text_view_set_left_margin(editor->paths_view, 6); gtk_text_view_set_right_margin(editor->paths_view, 6);
    gtk_accessible_update_property(GTK_ACCESSIBLE(editor->paths_view), GTK_ACCESSIBLE_PROPERTY_LABEL, "Applications", -1);
    gtk_widget_add_css_class(GTK_WIDGET(editor->paths_view), "card");
    g_signal_connect(gtk_text_view_get_buffer(editor->paths_view), "changed", G_CALLBACK(on_paths_changed), NULL);
    GtkWidget *paths_scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(paths_scroller), 90);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(paths_scroller), GTK_WIDGET(editor->paths_view));
    adw_preferences_group_add(apps, paths_scroller);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), apps);
    AdwPreferencesGroup *overrides = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(overrides, "For this app");
    editor->transcription_row = combo(overrides, "Transcription model");
    editor->language_row = combo(overrides, "Spoken language");
    editor->polish_mode_row = combo(overrides, "Post-processing");
    const char *modes[] = { "Use the app setting", "Off", "On", NULL };
    adw_combo_row_set_model(editor->polish_mode_row, G_LIST_MODEL(gtk_string_list_new(modes)));
    editor->polish_model_row = combo(overrides, "Polishing model");
    editor->prompt_row = entry(overrides, "Custom instructions");
    editor->output_language_row = entry(overrides, "Output language (for example British English)");
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), overrides);
    AdwPreferencesGroup *notes = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    editor->notes = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(editor->notes, TRUE);
    gtk_label_set_xalign(editor->notes, 0);
    gtk_widget_add_css_class(GTK_WIDGET(editor->notes), "dim-label");
    adw_preferences_group_add(notes, GTK_WIDGET(editor->notes));
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), notes);
    gtk_paned_set_end_child(GTK_PANED(paned), page);
    gtk_box_append(GTK_BOX(outer), paned);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), outer);
    adw_window_set_content(ADW_WINDOW(window), toolbar);
    editor->selected = editor->drafts->len > 0 ? 0 : -1;
    refresh_list();
}

/* ------------------------------------------------------ main window group */

static void on_open(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (editor == NULL) jsti_window_emit(JSTI_EVENT_OPEN_PROFILES, "", 0);
}

void jsti_window_profiles_build(AdwPreferencesPage *page) {
    profiles_group = ADW_PREFERENCES_GROUP(jsti_window_group("App profiles"));
    adw_preferences_group_set_description(
        profiles_group, "Use a different model, language or post-processing when you dictate into a particular app.");
    open_button = GTK_BUTTON(gtk_button_new_with_label("Edit app profiles…"));
    gtk_widget_set_halign(GTK_WIDGET(open_button), GTK_ALIGN_END);
    g_signal_connect(open_button, "clicked", G_CALLBACK(on_open), NULL);
    adw_preferences_group_add(profiles_group, GTK_WIDGET(open_button));
    adw_preferences_page_add(page, profiles_group);
}

void jsti_window_profiles_refresh(gboolean idle) {
    if (open_button != NULL) gtk_widget_set_sensitive(GTK_WIDGET(open_button), idle);
}

/* ------------------------------------------------ thread-safe setters */

static GPtrArray *copy_names(const char *const *names, size_t count) {
    GPtrArray *array = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(array, g_strdup(names[index]));
    return array;
}

static void editor_apply(gpointer pointer) {
    Editor *incoming = pointer;
    /* Ownership moves to the open editor; a second request replaces nothing. */
    if (editor != NULL) {
        if (incoming->callback != NULL) incoming->callback(0, NULL, 0, incoming->context, NULL, 0);
        editor_free(incoming);
        return;
    }
    editor = incoming;
    build_editor();
    gtk_window_present(editor->window);
}

static void editor_discard(gpointer pointer) {
    /* Applied editors are owned by the window; only unapplied ones are freed. */
    if (pointer != editor) editor_free(pointer);
}

int32_t jsti_window_set_profiles(
    const JSTIProfileDraft *drafts, size_t count, const char *const *transcription_names, size_t transcription_count,
    const char *const *polish_names, size_t polish_count, const char *const *language_names, size_t language_count,
    const char *notice, jsti_profiles_fn callback, void *context) {
    if (count > 1000 || (count > 0 && drafts == NULL)) return -1;
    Editor *value = g_new0(Editor, 1);
    value->drafts = g_ptr_array_new_with_free_func(draft_free);
    for (size_t index = 0; index < count; index++) {
        const JSTIProfileDraft *source = &drafts[index];
        Draft *draft = g_new0(Draft, 1);
        draft->id = g_strdup(source->id != NULL ? source->id : "");
        draft->name = g_strdup(source->name != NULL ? source->name : "");
        draft->paths = g_strdup(source->paths != NULL ? source->paths : "");
        draft->prompt = g_strdup(source->prompt != NULL ? source->prompt : "");
        draft->output_language = g_strdup(source->output_language != NULL ? source->output_language : "");
        draft->notes = g_strdup(source->notes != NULL ? source->notes : "");
        draft->transcription = source->transcription;
        draft->polish_mode = source->polish_mode;
        draft->polish_model = source->polish_model;
        draft->language = source->language;
        draft->kept_transcription = source->transcription == -2;
        draft->kept_polish_model = source->polish_model == -2;
        draft->kept_language = source->language == -2;
        g_ptr_array_add(value->drafts, draft);
    }
    value->transcription_names = copy_names(transcription_names, transcription_count);
    value->polish_names = copy_names(polish_names, polish_count);
    value->language_names = copy_names(language_names, language_count);
    value->notice = g_strdup(notice != NULL ? notice : "");
    value->callback = callback;
    value->context = context;
    return jsti_window_post(editor_apply, value, editor_discard);
}

static void note_apply(gpointer pointer) {
    if (profiles_group != NULL) adw_preferences_group_set_description(profiles_group, pointer);
}

int32_t jsti_window_set_profiles_note(const char *note) {
    return jsti_window_post(note_apply, g_strdup(note != NULL ? note : ""), g_free);
}

/* ---------------------------------------------------------- self-test */

int32_t jsti_window_profiles_save_for_test(char *error, size_t capacity) {
    if (editor == NULL) {
        jsti_set_error(error, capacity, "The profile editor is not open.");
        return -1;
    }
    int32_t result = save(error, capacity);
    if (result == 0) close_editor(FALSE);
    return result;
}

static int32_t test_callback(
    int32_t action, const JSTIProfileDraft *drafts, size_t count, void *context, char *error, size_t capacity) {
    (void)error; (void)capacity;
    gint *seen = context;
    if (action == 1 && count == 2 && g_strcmp0(drafts[1].name, "New profile") == 0 && drafts[0].transcription == -2 &&
        drafts[0].language == 1) {
        *seen = 1;
    }
    return 0;
}

int32_t jsti_window_profiles_self_test(char *error, size_t capacity) {
    gint seen = 0;
    const char *models[] = { "Batch: Model A", "Live: Model B" };
    const char *languages[] = { "English", "French" };
    JSTIProfileDraft stored = { .id = "00000000-0000-0000-0000-00000000000a", .name = "Editor", .paths = "gedit",
                                .prompt = "", .output_language = "", .notes = "Kept.",
                                .transcription = -2, .polish_mode = 0, .polish_model = -1, .language = 1 };
    jsti_window_set_profiles(&stored, 1, models, 2, models, 0, languages, 2, "Test", test_callback, &seen);
    /* The post runs on this loop; drive it until the editor opens. */
    for (int spin = 0; spin < 50 && editor == NULL; spin++) g_main_context_iteration(NULL, FALSE);
    if (editor == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the profile editor did not open");
        return -1;
    }
    if (adw_combo_row_get_selected(editor->transcription_row) != 1 ||
        adw_combo_row_get_selected(editor->language_row) != 2) {
        close_editor(TRUE);
        jsti_set_error(error, capacity, "Window self-test: stored profile choices were not shown");
        return -1;
    }
    on_add(NULL, NULL);
    if (jsti_window_profiles_save_for_test(error, capacity) != 0 || seen != 1) {
        if (editor != NULL) close_editor(TRUE);
        jsti_set_error(error, capacity, "Window self-test: the profile editor did not save its drafts");
        return -1;
    }
    return 0;
}
