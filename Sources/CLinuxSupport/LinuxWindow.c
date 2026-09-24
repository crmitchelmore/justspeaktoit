#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * The GTK 4 / libadwaita window. It owns no application state: every control
 * reports an event to Swift, and Swift pushes display state back through the
 * jsti_window_* setters, which are safe from any thread and applied in call
 * order on the GTK main thread. Record-bound History presentation is applied
 * only while that record is still selected, as on Windows.
 */

typedef struct Slot {
    gchar *id;
    gint32 global;
} Slot;

typedef struct UI {
    AdwApplication *application;
    GtkWindow *window;
    jsti_window_event_fn callback;
    void *context;
    gint32 flags;
    gboolean ready_sent;
    gboolean suppress;
    /* Models: picker position -> global slot. */
    GtkStringList *model_names;
    GArray *model_slots;
    AdwComboRow *model_row;
    GtkLabel *catalog_status;
    GtkButton *catalog_refresh;
    AdwPasswordEntryRow *key_row;
    /* Shown while an Azure model is selected: live routes need the endpoint. */
    AdwEntryRow *azure_row;
    /* Microphones */
    GtkStringList *microphone_names;
    GPtrArray *microphone_ids;
    AdwComboRow *microphone_row;
    /* Text output */
    AdwComboRow *output_row;
    AdwSwitchRow *restore_row;
    AdwActionRow *shortcut_row;
    AdwComboRow *style_row;
    /* Post-processing */
    AdwSwitchRow *polish_row;
    AdwComboRow *polish_model_row;
    GtkStringList *polish_models;
    AdwEntryRow *polish_prompt_row;
    AdwPasswordEntryRow *polish_key_row;
    /* Recording */
    GtkButton *record;
    GtkButton *cancel;
    GtkLabel *status;
    GtkTextView *transcript;
    GtkButton *copy;
    GtkDropDown *version;
    gint32 state;
    /* History */
    GtkSearchEntry *search;
    GtkListBox *history;
    GPtrArray *history_ids;
    gchar *selected_id;
    gchar *presented_id;
    gint32 presented_variant;
    gboolean presented_switchable;
    GtkButton *retry;
    GtkButton *export_button;
    GtkButton *open_audio;
    GtkButton *import_button;
    GtkButton *play;
    GtkButton *stop_play;
    GtkLabel *playback_label;
    gint32 playback_state;
    /* Export in progress: the text and version captured at the click. */
    gchar *export_text;
} UI;

static UI ui;
static gint loop_running;
static GMutex post_lock;
static gboolean window_closed;
static GQueue early_posts = G_QUEUE_INIT;
static void open_posts(void);
static void close_posts(void);

gboolean jsti_window_loop_running(void) { return g_atomic_int_get(&loop_running) != 0; }

static void emit(gint32 event, const char *text, gint32 index) {
    if (ui.callback != NULL && !ui.suppress) ui.callback(event, text != NULL ? text : "", index, ui.context);
}

static gint32 selected_model_slot(void) {
    guint position = adw_combo_row_get_selected(ui.model_row);
    if (ui.model_slots == NULL || position == GTK_INVALID_LIST_POSITION || position >= ui.model_slots->len) {
        return -1;
    }
    return g_array_index(ui.model_slots, Slot, position).global;
}

static const char *selected_microphone(void) {
    guint position = adw_combo_row_get_selected(ui.microphone_row);
    if (ui.microphone_ids == NULL || position == GTK_INVALID_LIST_POSITION || position >= ui.microphone_ids->len) {
        return "";
    }
    return g_ptr_array_index(ui.microphone_ids, position);
}

static gchar *displayed_transcript(void) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(ui.transcript);
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}

static void set_transcript(const char *text) {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.transcript), text != NULL ? text : "", -1);
}

static void refresh_actions(void) {
    gboolean idle = ui.state == JSTI_STATE_IDLE;
    gchar *text = displayed_transcript();
    gboolean has_text = text != NULL && text[0] != '\0';
    g_free(text);
    gboolean has_record = ui.selected_id != NULL;
    gboolean presented = has_record && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy), has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), ui.state != JSTI_STATE_WORKING);
    gtk_button_set_label(ui.record, ui.state == JSTI_STATE_RECORDING ? "Stop recording" : "Record");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.retry), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.export_button), idle && presented && has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.open_audio), has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), has_record && (idle || ui.playback_state != 0));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop_play), has_record && ui.playback_state != 0);
    gtk_button_set_label(ui.play, ui.playback_state == 1 ? "Pause" : "Play");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.import_button), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.model_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.microphone_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.version), presented && ui.presented_switchable && idle);
    gtk_widget_set_visible(GTK_WIDGET(ui.version), presented && ui.presented_switchable);
}

/* ------------------------------------------------------------ callbacks */

static void on_record(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_TOGGLE_RECORDING, selected_microphone(), selected_model_slot());
}

static void on_cancel(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_CANCEL, "", 0);
}

static void on_copy(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_COPY, "", 0);
}

/* The Azure resource row belongs to Azure models only. */
static void refresh_azure_row(void) {
    guint position = adw_combo_row_get_selected(ui.model_row);
    gboolean azure = ui.model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < ui.model_slots->len
        && g_str_has_prefix(g_array_index(ui.model_slots, Slot, position).id, "azure/");
    gtk_widget_set_visible(GTK_WIDGET(ui.azure_row), azure);
    /* On-device models (canonical "local/" identifiers) need no API key. */
    gboolean local = ui.model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < ui.model_slots->len
        && g_str_has_prefix(g_array_index(ui.model_slots, Slot, position).id, "local/");
    gtk_widget_set_visible(GTK_WIDGET(ui.key_row), !local);
}

static void on_model(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_azure_row();
    gint32 slot = selected_model_slot();
    if (slot >= 0) emit(JSTI_EVENT_SELECT_MODEL, "", slot);
}

static void on_azure_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_AZURE_RESOURCE, gtk_editable_get_text(GTK_EDITABLE(row)), 0);
}

static void on_microphone(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    emit(JSTI_EVENT_SELECT_MICROPHONE, selected_microphone(), 0);
}

static void on_key_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    const char *key = gtk_editable_get_text(GTK_EDITABLE(row));
    emit(JSTI_EVENT_SAVE_KEY, key, selected_model_slot());
    gtk_editable_set_text(GTK_EDITABLE(row), "");
}

static void on_text_output(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint method = adw_combo_row_get_selected(ui.output_row);
    gboolean restore = adw_switch_row_get_active(ui.restore_row);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), method == 0);
    emit(JSTI_EVENT_TEXT_OUTPUT, restore ? "restore" : "", (gint32)method);
}

static void on_style(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    emit(JSTI_EVENT_SHORTCUT_STYLE, "", (gint32)adw_combo_row_get_selected(ui.style_row));
}

static void on_polish_apply(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gint32 model = (gint32)adw_combo_row_get_selected(ui.polish_model_row);
    gint32 index = adw_switch_row_get_active(ui.polish_row) ? model : -1 - model;
    gchar *text = g_strdup_printf("%s\x1f%s", gtk_editable_get_text(GTK_EDITABLE(ui.polish_prompt_row)),
                                  gtk_editable_get_text(GTK_EDITABLE(ui.polish_key_row)));
    emit(JSTI_EVENT_POST_PROCESSING, text, index);
    g_free(text);
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "");
}

static void on_refresh(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_REFRESH_MODELS, "", 0);
}

static void on_search(GtkSearchEntry *entry, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_SEARCH_HISTORY, gtk_editable_get_text(GTK_EDITABLE(entry)), 0);
}

static void on_history_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    if (row == NULL) return;
    gint index = gtk_list_box_row_get_index(row);
    if (index < 0 || (guint)index >= ui.history_ids->len) return;
    const char *id = g_ptr_array_index(ui.history_ids, index);
    if (g_strcmp0(id, ui.selected_id) == 0) return;
    g_free(ui.selected_id);
    ui.selected_id = g_strdup(id);
    /* Stale text never stays under another record's actions. */
    g_clear_pointer(&ui.presented_id, g_free);
    set_transcript("");
    ui.playback_state = 0;
    gtk_label_set_text(ui.playback_label, "");
    refresh_actions();
    emit(JSTI_EVENT_SELECT_HISTORY, id, 0);
}

static void on_version(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return;
    guint selected = gtk_drop_down_get_selected(ui.version);
    if ((gint32)selected == ui.presented_variant) return;
    ui.presented_variant = (gint32)selected;
    emit(JSTI_EVENT_TRANSCRIPT_VERSION, ui.selected_id, (gint32)selected);
}

static void on_retry(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_RETRY_HISTORY, ui.selected_id, 0);
}

static void on_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_PLAYBACK_TOGGLE, ui.selected_id, 0);
}

static void on_stop_play(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_PLAYBACK_STOP, ui.selected_id, 0);
}

static void on_open_audio(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_OPEN_AUDIO, ui.selected_id, 0);
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
    g_clear_pointer(&ui.export_text, g_free);
}

static void on_export(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id == NULL || ui.export_text != NULL) return;
    /* Capture the displayed text and version at the click, before the dialog. */
    ui.export_text = displayed_transcript();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Export transcript");
    gchar *name = g_strdup_printf("Transcript-%s.txt", ui.selected_id);
    gtk_file_dialog_set_initial_name(dialog, name);
    g_free(name);
    gtk_file_dialog_save(dialog, ui.window, NULL, export_chosen,
                         GINT_TO_POINTER(ui.presented_switchable ? ui.presented_variant : 1));
    g_object_unref(dialog);
}

static void import_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (file == NULL) return;
    gchar *path = g_file_get_path(file);
    if (path != NULL) emit(JSTI_EVENT_IMPORT, path, selected_model_slot());
    g_free(path);
    g_object_unref(file);
}

static void on_import(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Import audio");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Audio");
    const char *patterns[] = { "*.wav", "*.mp3", "*.mp4", "*.m4a", "*.aac", "*.flac", "*.ogg", "*.opus", "*.webm" };
    for (size_t index = 0; index < G_N_ELEMENTS(patterns); index++) gtk_file_filter_add_pattern(filter, patterns[index]);
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_open(dialog, ui.window, NULL, import_chosen, NULL);
    g_object_unref(filters);
    g_object_unref(filter);
    g_object_unref(dialog);
}

static gboolean on_close_request(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    emit(JSTI_EVENT_CLOSING, "", 0);
    close_posts();
    return FALSE;
}

/* --------------------------------------------------------------- layout */

static GtkWidget *group(const char *title) {
    GtkWidget *widget = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(widget), title);
    return widget;
}

static void build_window(void) {
    GtkWidget *window = adw_application_window_new(GTK_APPLICATION(ui.application));
    ui.window = GTK_WINDOW(window);
    gtk_window_set_title(ui.window, "JustSpeakToIt");
    gtk_window_set_default_size(ui.window, 720, 860);
    g_signal_connect(window, "close-request", G_CALLBACK(on_close_request), NULL);

    GtkWidget *toolbar = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), header);
    ui.import_button = GTK_BUTTON(gtk_button_new_with_label("Import audio…"));
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), GTK_WIDGET(ui.import_button));
    g_signal_connect(ui.import_button, "clicked", G_CALLBACK(on_import), NULL);

    GtkWidget *page = adw_preferences_page_new();
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), page);
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(window), toolbar);

    /* Dictation */
    GtkWidget *dictation = group("Dictation");
    ui.record = GTK_BUTTON(gtk_button_new_with_label("Record"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.record), "suggested-action");
    gtk_widget_add_css_class(GTK_WIDGET(ui.record), "pill");
    ui.cancel = GTK_BUTTON(gtk_button_new_with_label("Cancel"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.cancel), "pill");
    g_signal_connect(ui.record, "clicked", G_CALLBACK(on_record), NULL);
    g_signal_connect(ui.cancel, "clicked", G_CALLBACK(on_cancel), NULL);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(buttons, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(buttons, 12);
    gtk_box_append(GTK_BOX(buttons), GTK_WIDGET(ui.record));
    gtk_box_append(GTK_BOX(buttons), GTK_WIDGET(ui.cancel));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(dictation), buttons);
    ui.status = GTK_LABEL(gtk_label_new("Starting…"));
    gtk_label_set_wrap(ui.status, TRUE);
    gtk_label_set_xalign(ui.status, 0);
    gtk_label_set_selectable(ui.status, TRUE);
    gtk_widget_set_margin_bottom(GTK_WIDGET(ui.status), 12);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(dictation), GTK_WIDGET(ui.status));

    ui.transcript = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(ui.transcript, FALSE);
    gtk_text_view_set_wrap_mode(ui.transcript, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(ui.transcript, 8);
    gtk_text_view_set_right_margin(ui.transcript, 8);
    gtk_text_view_set_top_margin(ui.transcript, 8);
    gtk_text_view_set_bottom_margin(ui.transcript, 8);
    gtk_widget_add_css_class(GTK_WIDGET(ui.transcript), "card");
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroller), 140);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), GTK_WIDGET(ui.transcript));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(dictation), scroller);
    GtkWidget *transcript_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(transcript_actions, 6);
    const char *versions[] = { "Processed", "Original", NULL };
    ui.version = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(versions));
    gtk_widget_set_tooltip_text(GTK_WIDGET(ui.version), "Transcript version");
    g_signal_connect(ui.version, "notify::selected", G_CALLBACK(on_version), NULL);
    ui.copy = GTK_BUTTON(gtk_button_new_with_label("Copy"));
    g_signal_connect(ui.copy, "clicked", G_CALLBACK(on_copy), NULL);
    gtk_box_append(GTK_BOX(transcript_actions), GTK_WIDGET(ui.version));
    gtk_box_append(GTK_BOX(transcript_actions), GTK_WIDGET(ui.copy));
    gtk_widget_set_halign(transcript_actions, GTK_ALIGN_END);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(dictation), transcript_actions);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(dictation));

    /* Settings */
    GtkWidget *settings = group("Settings");
    ui.model_names = gtk_string_list_new(NULL);
    ui.model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.model_row), "Transcription model");
    adw_combo_row_set_model(ui.model_row, G_LIST_MODEL(ui.model_names));
    adw_combo_row_set_enable_search(ui.model_row, TRUE);
    g_signal_connect(ui.model_row, "notify::selected", G_CALLBACK(on_model), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.model_row));

    ui.key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.key_row), "API key for the selected provider");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(ui.key_row), TRUE);
    g_signal_connect(ui.key_row, "apply", G_CALLBACK(on_key_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.key_row));

    /* Recorded audio falls back to the key's region; live Azure needs this. */
    ui.azure_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.azure_row),
                                  "Azure Speech resource endpoint (https://…cognitiveservices.azure.com)");
    adw_entry_row_set_show_apply_button(ui.azure_row, TRUE);
    adw_entry_row_set_input_purpose(ui.azure_row, GTK_INPUT_PURPOSE_URL);
    g_signal_connect(ui.azure_row, "apply", G_CALLBACK(on_azure_apply), NULL);
    gtk_widget_set_visible(GTK_WIDGET(ui.azure_row), FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.azure_row));

    ui.microphone_names = gtk_string_list_new(NULL);
    ui.microphone_ids = g_ptr_array_new_with_free_func(g_free);
    ui.microphone_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.microphone_row), "Microphone");
    adw_combo_row_set_model(ui.microphone_row, G_LIST_MODEL(ui.microphone_names));
    g_signal_connect(ui.microphone_row, "notify::selected", G_CALLBACK(on_microphone), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.microphone_row));

    const char *methods[] = { "Paste into the focused app", "Copy to the clipboard only", NULL };
    ui.output_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.output_row), "Text output");
    adw_combo_row_set_model(ui.output_row, G_LIST_MODEL(gtk_string_list_new(methods)));
    g_signal_connect(ui.output_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.output_row));
    ui.restore_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.restore_row), "Restore the clipboard after pasting");
    adw_switch_row_set_active(ui.restore_row, TRUE);
    g_signal_connect(ui.restore_row, "notify::active", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.restore_row));

    ui.shortcut_row = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.shortcut_row), "Keyboard shortcut");
    adw_action_row_set_subtitle(ui.shortcut_row, "Checking the desktop…");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.shortcut_row));
    const char *styles[] = { "Press to toggle", "Hold to record", "Double-tap to toggle",
                             "Hold, or double-tap to toggle", NULL };
    ui.style_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.style_row), "Shortcut behaviour");
    adw_combo_row_set_model(ui.style_row, G_LIST_MODEL(gtk_string_list_new(styles)));
    g_signal_connect(ui.style_row, "notify::selected", G_CALLBACK(on_style), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), GTK_WIDGET(ui.style_row));

    GtkWidget *catalog = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(catalog, 6);
    ui.catalog_status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(ui.catalog_status, TRUE);
    gtk_label_set_xalign(ui.catalog_status, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(ui.catalog_status), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(ui.catalog_status), "dim-label");
    ui.catalog_refresh = GTK_BUTTON(gtk_button_new_with_label("Refresh models"));
    g_signal_connect(ui.catalog_refresh, "clicked", G_CALLBACK(on_refresh), NULL);
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_status));
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_refresh));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings), catalog);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(settings));
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(jsti_local_models_group_new()));

    /* Post-processing */
    GtkWidget *polish = group("Post-processing");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(polish),
        "Optionally polish transcripts with an OpenRouter model. The original is always kept in History.");
    ui.polish_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_row), "Send transcripts to OpenRouter for polishing");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_row));
    ui.polish_models = gtk_string_list_new(NULL);
    ui.polish_model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_model_row), "Polishing model");
    adw_combo_row_set_model(ui.polish_model_row, G_LIST_MODEL(ui.polish_models));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_model_row));
    ui.polish_prompt_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_prompt_row), "Custom instructions (optional)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_prompt_row));
    ui.polish_key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_key_row), "New OpenRouter key (leave empty to keep)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_key_row));
    GtkWidget *polish_apply = gtk_button_new_with_label("Apply");
    gtk_widget_set_halign(polish_apply, GTK_ALIGN_END);
    gtk_widget_set_margin_top(polish_apply, 6);
    g_signal_connect(polish_apply, "clicked", G_CALLBACK(on_polish_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), polish_apply);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(polish));

    /* History */
    GtkWidget *history = group("History");
    ui.search = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    gtk_search_entry_set_placeholder_text(ui.search, "Search transcripts, models and profiles");
    gtk_widget_set_margin_bottom(GTK_WIDGET(ui.search), 6);
    g_signal_connect(ui.search, "search-changed", G_CALLBACK(on_search), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(history), GTK_WIDGET(ui.search));
    ui.history = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(ui.history), "boxed-list");
    gtk_list_box_set_selection_mode(ui.history, GTK_SELECTION_SINGLE);
    g_signal_connect(ui.history, "row-selected", G_CALLBACK(on_history_selected), NULL);
    ui.history_ids = g_ptr_array_new_with_free_func(g_free);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(history), GTK_WIDGET(ui.history));
    GtkWidget *history_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(history_actions, 6);
    gtk_widget_set_halign(history_actions, GTK_ALIGN_END);
    ui.retry = GTK_BUTTON(gtk_button_new_with_label("Retry"));
    ui.export_button = GTK_BUTTON(gtk_button_new_with_label("Export…"));
    ui.open_audio = GTK_BUTTON(gtk_button_new_with_label("Open audio"));
    g_signal_connect(ui.retry, "clicked", G_CALLBACK(on_retry), NULL);
    g_signal_connect(ui.export_button, "clicked", G_CALLBACK(on_export), NULL);
    g_signal_connect(ui.open_audio, "clicked", G_CALLBACK(on_open_audio), NULL);
    ui.playback_label = GTK_LABEL(gtk_label_new(""));
    gtk_widget_add_css_class(GTK_WIDGET(ui.playback_label), "dim-label");
    gtk_widget_add_css_class(GTK_WIDGET(ui.playback_label), "numeric");
    ui.play = GTK_BUTTON(gtk_button_new_with_label("Play"));
    ui.stop_play = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(ui.play, "clicked", G_CALLBACK(on_play), NULL);
    g_signal_connect(ui.stop_play, "clicked", G_CALLBACK(on_stop_play), NULL);
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.playback_label));
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.play));
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.stop_play));
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.retry));
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.export_button));
    gtk_box_append(GTK_BOX(history_actions), GTK_WIDGET(ui.open_audio));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(history), history_actions);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(history));
    refresh_actions();
}

/* -------------------------------------------------------- application */

typedef struct RunModels {
    const JSTIModelRow *rows;
    size_t count;
    gint32 selected;
} RunModels;

static RunModels initial_models;

static void apply_models(const JSTIModelRow *rows, size_t count, gint32 selected);

static void on_toggle_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter; (void)data;
    emit(JSTI_EVENT_COMMAND_TOGGLE, selected_microphone(), selected_model_slot());
}

static gboolean emit_ready(gpointer data) {
    (void)data;
    emit(JSTI_EVENT_READY, "", 0);
    return G_SOURCE_REMOVE;
}

static void on_activate(GApplication *application, gpointer data) {
    (void)application; (void)data;
    if (ui.window != NULL) {
        gtk_window_present(ui.window);
        return;
    }
    build_window();
    ui.suppress = TRUE;
    apply_models(initial_models.rows, initial_models.count, initial_models.selected);
    ui.suppress = FALSE;
    open_posts();
    gtk_window_present(ui.window);
    if (!ui.ready_sent) {
        ui.ready_sent = TRUE;
        /* The smoke test inspects and captures a laid-out, drawn window. */
        if (ui.flags & JSTI_WINDOW_SMOKE_TEST) g_timeout_add(750, emit_ready, NULL);
        else emit(JSTI_EVENT_READY, "", 0);
    }
}

static int on_command_line(GApplication *application, GApplicationCommandLine *line, gpointer data) {
    (void)data;
    gint argc = 0;
    gchar **argv = g_application_command_line_get_arguments(line, &argc);
    gboolean toggle = FALSE;
    for (gint index = 1; index < argc; index++) {
        if (g_strcmp0(argv[index], "--toggle") == 0) toggle = TRUE;
    }
    g_strfreev(argv);
    gboolean remote = g_application_command_line_get_is_remote(line);
    if (!remote || ui.window == NULL) g_application_activate(application);
    /* A remote --toggle drives the running app without raising its window, so
     * focus stays on the field that should receive the text. */
    if (toggle) emit(JSTI_EVENT_COMMAND_TOGGLE, selected_microphone(), selected_model_slot());
    else if (remote) gtk_window_present(ui.window);
    return 0;
}

int32_t jsti_window_run(
    const char *app_id, int argc, char **argv, const JSTIModelRow *models, size_t model_count,
    int32_t selected_model, jsti_window_event_fn callback, void *context, int32_t flags, char *error,
    size_t capacity) {
    if (ui.application != NULL) {
        jsti_set_error(error, capacity, "The window is already running.");
        return -1;
    }
    GApplicationFlags application_flags = G_APPLICATION_HANDLES_COMMAND_LINE;
    if (flags & JSTI_WINDOW_SMOKE_TEST) application_flags |= G_APPLICATION_NON_UNIQUE;
    ui.application = adw_application_new(app_id, application_flags);
    if (ui.application == NULL) {
        jsti_set_error(error, capacity, "Could not create the application.");
        return -1;
    }
    ui.callback = callback;
    ui.context = context;
    ui.flags = flags;
    ui.presented_variant = -1;
    initial_models = (RunModels){ .rows = models, .count = model_count, .selected = selected_model };
    GSimpleAction *toggle = g_simple_action_new("toggle-recording", NULL);
    g_signal_connect(toggle, "activate", G_CALLBACK(on_toggle_action), NULL);
    g_action_map_add_action(G_ACTION_MAP(ui.application), G_ACTION(toggle));
    g_object_unref(toggle);
    g_signal_connect(ui.application, "activate", G_CALLBACK(on_activate), NULL);
    g_signal_connect(ui.application, "command-line", G_CALLBACK(on_command_line), NULL);
    int status = g_application_run(G_APPLICATION(ui.application), argc, argv);
    close_posts();
    ui.callback = NULL;
    g_clear_object(&ui.application);
    ui.window = NULL;
    if (status != 0) {
        jsti_set_error(error, capacity, "The window exited with status %d.", status);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------ thread-safe setters */

typedef void (*apply_fn)(gpointer data);
typedef struct Pending {
    apply_fn apply;
    GDestroyNotify destroy;
    gpointer data;
} Pending;

static gboolean pending_run(gpointer pointer) {
    Pending *pending = pointer;
    if (ui.window != NULL && jsti_window_loop_running()) pending->apply(pending->data);
    return G_SOURCE_REMOVE;
}

static void pending_free(gpointer pointer) {
    Pending *pending = pointer;
    if (pending->destroy != NULL) pending->destroy(pending->data);
    g_free(pending);
}

static void attach(Pending *pending) {
    /* One FIFO at default priority keeps updates in call order. */
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, pending_run, pending, pending_free);
    g_source_attach(source, g_main_context_default());
    g_source_unref(source);
}

/* Updates made before the window exists (initial microphones, text output)
 * wait here and are applied first, in order; after it closes they are dropped. */
static int32_t post(apply_fn apply, gpointer data, GDestroyNotify destroy) {
    Pending *pending = g_new0(Pending, 1);
    pending->apply = apply;
    pending->destroy = destroy;
    pending->data = data;
    g_mutex_lock(&post_lock);
    if (window_closed) {
        g_mutex_unlock(&post_lock);
        pending_free(pending);
        return 0;
    }
    if (!jsti_window_loop_running()) {
        g_queue_push_tail(&early_posts, pending);
        g_mutex_unlock(&post_lock);
        return 0;
    }
    attach(pending);
    g_mutex_unlock(&post_lock);
    return 0;
}

int32_t jsti_window_post(jsti_window_apply_fn apply, gpointer data, GDestroyNotify destroy) {
    return post(apply, data, destroy);
}

void jsti_window_emit(gint32 event, const char *text, gint32 index) { emit(event, text, index); }

static void open_posts(void) {
    g_mutex_lock(&post_lock);
    g_atomic_int_set(&loop_running, 1);
    Pending *pending;
    while ((pending = g_queue_pop_head(&early_posts)) != NULL) attach(pending);
    g_mutex_unlock(&post_lock);
}

static void close_posts(void) {
    g_mutex_lock(&post_lock);
    window_closed = TRUE;
    g_atomic_int_set(&loop_running, 0);
    Pending *pending;
    while ((pending = g_queue_pop_head(&early_posts)) != NULL) pending_free(pending);
    g_mutex_unlock(&post_lock);
}

typedef struct Update {
    gchar *status;
    gchar *transcript;
    gboolean has_transcript;
    gint32 state;
} Update;

static void update_free(gpointer pointer) {
    Update *update = pointer;
    g_free(update->status);
    g_free(update->transcript);
    g_free(update);
}

static void update_apply(gpointer pointer) {
    Update *update = pointer;
    if (update->status != NULL) gtk_label_set_text(ui.status, update->status);
    if (update->has_transcript) {
        set_transcript(update->transcript);
        /* Global text is not bound to a record. */
        g_clear_pointer(&ui.presented_id, g_free);
    }
    if (update->state >= 0) ui.state = update->state;
    refresh_actions();
}

int32_t jsti_window_update(const char *status, const char *transcript, int32_t state) {
    Update *update = g_new0(Update, 1);
    update->status = g_strdup(status);
    update->transcript = g_strdup(transcript);
    update->has_transcript = transcript != NULL;
    update->state = state;
    return post(update_apply, update, update_free);
}

typedef struct Models {
    GArray *slots;
    GPtrArray *names;
    gint32 selected;
    gchar *status;
    gboolean refreshing;
} Models;

static gint compare_order(gconstpointer left, gconstpointer right, gpointer orders) {
    gint32 a = g_array_index((GArray *)orders, gint32, ((const Slot *)left)->global);
    gint32 b = g_array_index((GArray *)orders, gint32, ((const Slot *)right)->global);
    return a - b;
}

static Models *models_copy(const JSTIModelRow *rows, size_t count, gint32 selected) {
    Models *models = g_new0(Models, 1);
    models->slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    models->names = g_ptr_array_new_with_free_func(g_free);
    models->selected = selected;
    GArray *orders = g_array_sized_new(FALSE, TRUE, sizeof(gint32), (guint)count);
    for (size_t index = 0; index < count; index++) {
        g_array_append_val(orders, rows[index].display_order);
        if (rows[index].display_order < 0) continue;
        Slot slot = { .id = g_strdup(rows[index].id), .global = (gint32)index };
        g_array_append_val(models->slots, slot);
    }
    g_array_sort_with_data(models->slots, compare_order, orders);
    for (guint index = 0; index < models->slots->len; index++) {
        const JSTIModelRow *row = &rows[g_array_index(models->slots, Slot, index).global];
        g_ptr_array_add(models->names, row->is_live ? g_strdup_printf("Live · %s", row->name) : g_strdup(row->name));
    }
    g_array_unref(orders);
    return models;
}

static void models_free(gpointer pointer) {
    Models *models = pointer;
    for (guint index = 0; index < models->slots->len; index++) g_free(g_array_index(models->slots, Slot, index).id);
    g_array_unref(models->slots);
    g_ptr_array_unref(models->names);
    g_free(models->status);
    g_free(models);
}

static void models_apply(gpointer pointer) {
    Models *models = pointer;
    gint32 keep = models->selected >= 0 ? models->selected : selected_model_slot();
    ui.suppress = TRUE;
    if (ui.model_slots != NULL) {
        for (guint index = 0; index < ui.model_slots->len; index++) g_free(g_array_index(ui.model_slots, Slot, index).id);
        g_array_unref(ui.model_slots);
    }
    ui.model_slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    guint position = GTK_INVALID_LIST_POSITION;
    for (guint index = 0; index < models->slots->len; index++) {
        Slot slot = g_array_index(models->slots, Slot, index);
        Slot copy = { .id = g_strdup(slot.id), .global = slot.global };
        g_array_append_val(ui.model_slots, copy);
        if (slot.global == keep) position = index;
    }
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(ui.model_names));
    g_ptr_array_add(models->names, NULL);
    gtk_string_list_splice(ui.model_names, 0, existing, (const char *const *)models->names->pdata);
    g_ptr_array_set_size(models->names, models->names->len - 1);
    if (position != GTK_INVALID_LIST_POSITION) adw_combo_row_set_selected(ui.model_row, position);
    refresh_azure_row();
    if (models->status != NULL) gtk_label_set_text(ui.catalog_status, models->status);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.catalog_refresh), !models->refreshing);
    ui.suppress = FALSE;
}

static void apply_models(const JSTIModelRow *rows, size_t count, gint32 selected) {
    Models *models = models_copy(rows, count, selected);
    models_apply(models);
    models_free(models);
}

int32_t jsti_window_set_model_catalog(
    const JSTIModelRow *rows, size_t count, int32_t selected, const char *status, int32_t refreshing) {
    Models *models = models_copy(rows, count, selected);
    models->status = g_strdup(status);
    models->refreshing = refreshing != 0;
    return post(models_apply, models, models_free);
}

typedef struct Microphones {
    GPtrArray *ids;
    GPtrArray *names;
    gchar *selected;
} Microphones;

static void microphones_free(gpointer pointer) {
    Microphones *microphones = pointer;
    g_ptr_array_unref(microphones->ids);
    g_ptr_array_unref(microphones->names);
    g_free(microphones->selected);
    g_free(microphones);
}

static void microphones_apply(gpointer pointer) {
    Microphones *microphones = pointer;
    ui.suppress = TRUE;
    g_ptr_array_set_size(ui.microphone_ids, 0);
    guint position = 0;
    for (guint index = 0; index < microphones->ids->len; index++) {
        const char *id = g_ptr_array_index(microphones->ids, index);
        g_ptr_array_add(ui.microphone_ids, g_strdup(id));
        if (g_strcmp0(id, microphones->selected) == 0) position = index;
    }
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(ui.microphone_names));
    g_ptr_array_add(microphones->names, NULL);
    gtk_string_list_splice(ui.microphone_names, 0, existing, (const char *const *)microphones->names->pdata);
    g_ptr_array_set_size(microphones->names, microphones->names->len - 1);
    adw_combo_row_set_selected(ui.microphone_row, position);
    ui.suppress = FALSE;
}

int32_t jsti_window_set_microphones(
    const char *const *ids, const char *const *names, size_t count, const char *selected) {
    Microphones *microphones = g_new0(Microphones, 1);
    microphones->ids = g_ptr_array_new_with_free_func(g_free);
    microphones->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) {
        g_ptr_array_add(microphones->ids, g_strdup(ids[index]));
        g_ptr_array_add(microphones->names, g_strdup(names[index]));
    }
    microphones->selected = g_strdup(selected);
    return post(microphones_apply, microphones, microphones_free);
}

typedef struct History {
    GPtrArray *ids;
    GPtrArray *titles;
    GPtrArray *details;
    gchar *selected;
    gboolean select;
} History;

static void history_free(gpointer pointer) {
    History *history = pointer;
    g_ptr_array_unref(history->ids);
    g_ptr_array_unref(history->titles);
    g_ptr_array_unref(history->details);
    g_free(history->selected);
    g_free(history);
}

static void history_apply(gpointer pointer) {
    History *history = pointer;
    ui.suppress = TRUE;
    gtk_list_box_remove_all(ui.history);
    g_ptr_array_set_size(ui.history_ids, 0);
    const char *keep = history->select ? history->selected : ui.selected_id;
    GtkListBoxRow *selected = NULL;
    for (guint index = 0; index < history->ids->len; index++) {
        GtkWidget *row = adw_action_row_new();
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(history->titles, index));
        adw_action_row_set_subtitle(ADW_ACTION_ROW(row), g_ptr_array_index(history->details, index));
        adw_action_row_set_subtitle_lines(ADW_ACTION_ROW(row), 2);
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
        gtk_list_box_append(ui.history, row);
        g_ptr_array_add(ui.history_ids, g_strdup(g_ptr_array_index(history->ids, index)));
        if (g_strcmp0(keep, g_ptr_array_index(history->ids, index)) == 0) selected = GTK_LIST_BOX_ROW(row);
    }
    if (history->select) {
        g_free(ui.selected_id);
        ui.selected_id = g_strdup(history->selected != NULL && history->selected[0] != '\0' ? history->selected : NULL);
    }
    if (selected != NULL) {
        gtk_list_box_select_row(ui.history, selected);
    } else {
        g_clear_pointer(&ui.selected_id, g_free);
        g_clear_pointer(&ui.presented_id, g_free);
    }
    ui.suppress = FALSE;
    refresh_actions();
}

static History *history_copy(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    History *history = g_new0(History, 1);
    history->ids = g_ptr_array_new_with_free_func(g_free);
    history->titles = g_ptr_array_new_with_free_func(g_free);
    history->details = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) {
        g_ptr_array_add(history->ids, g_strdup(rows[index].id));
        g_ptr_array_add(history->titles, g_strdup(rows[index].title));
        g_ptr_array_add(history->details, g_strdup(rows[index].detail));
    }
    history->select = selected_id != NULL;
    history->selected = g_strdup(selected_id);
    return history;
}

int32_t jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    return post(history_apply, history_copy(rows, count, selected_id), history_free);
}

typedef struct Presentation {
    gchar *id;
    gint32 variant;
    gboolean switchable;
    gchar *text;
    gchar *status;
    gboolean has_text;
} Presentation;

static void presentation_free(gpointer pointer) {
    Presentation *presentation = pointer;
    g_free(presentation->id);
    g_free(presentation->text);
    g_free(presentation->status);
    g_free(presentation);
}

static void presentation_apply(gpointer pointer) {
    Presentation *presentation = pointer;
    /* Only the selected record's content may be shown under its actions. */
    if (g_strcmp0(presentation->id, ui.selected_id) != 0) return;
    ui.suppress = TRUE;
    if (presentation->has_text) {
        set_transcript(presentation->text);
        if (presentation->status != NULL) gtk_label_set_text(ui.status, presentation->status);
    }
    g_free(ui.presented_id);
    ui.presented_id = g_strdup(presentation->id);
    ui.presented_variant = presentation->variant;
    ui.presented_switchable = presentation->switchable;
    if (presentation->variant >= 0) gtk_drop_down_set_selected(ui.version, (guint)presentation->variant);
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_history_presentation(
    const char *record_id, int32_t variant, int32_t switchable, const char *text, const char *status) {
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->text = g_strdup(text != NULL ? text : "");
    presentation->status = g_strdup(status);
    presentation->has_text = TRUE;
    return post(presentation_apply, presentation, presentation_free);
}

int32_t jsti_window_set_transcript_variant(const char *record_id, int32_t variant, int32_t switchable) {
    if (record_id == NULL || record_id[0] == '\0') {
        return post((apply_fn)refresh_actions, NULL, NULL);
    }
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->has_text = FALSE;
    return post(presentation_apply, presentation, presentation_free);
}

typedef struct TextOutput {
    gint32 method;
    gboolean restore;
    gchar *hint;
} TextOutput;

static void text_output_free(gpointer pointer) {
    TextOutput *output = pointer;
    g_free(output->hint);
    g_free(output);
}

static void text_output_apply(gpointer pointer) {
    TextOutput *output = pointer;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.output_row, output->method == 1 ? 1 : 0);
    adw_switch_row_set_active(ui.restore_row, output->restore);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), output->method != 1);
    if (output->hint != NULL) adw_action_row_set_subtitle(ui.shortcut_row, output->hint);
    ui.suppress = FALSE;
}

int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard, const char *shortcut_hint) {
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    return post(text_output_apply, output, text_output_free);
}

int32_t jsti_window_transcript_snapshot(char *buffer, size_t capacity, size_t *required) {
    gchar *text = ui.export_text != NULL ? g_strdup(ui.export_text) : displayed_transcript();
    size_t length = strlen(text) + 1;
    if (required != NULL) *required = length;
    if (buffer == NULL || capacity < length) {
        g_free(text);
        return 2;
    }
    memcpy(buffer, text, length);
    g_free(text);
    return 0;
}

int32_t jsti_window_transcript_variant(void) {
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return -1;
    if (!ui.presented_switchable) return ui.presented_variant < 0 ? -1 : 1;
    return (int32_t)gtk_drop_down_get_selected(ui.version);
}

typedef struct Playback {
    gchar *id;
    gint32 state;
    gchar *text;
} Playback;

static void playback_free(gpointer pointer) {
    Playback *playback = pointer;
    g_free(playback->id);
    g_free(playback->text);
    g_free(playback);
}

static void playback_apply(gpointer pointer) {
    Playback *playback = pointer;
    if (g_strcmp0(playback->id, ui.selected_id) != 0) return;
    ui.playback_state = playback->state;
    gtk_label_set_text(ui.playback_label, playback->text != NULL ? playback->text : "");
    refresh_actions();
}

int32_t jsti_window_set_playback(const char *record_id, int32_t state, const char *text) {
    Playback *playback = g_new0(Playback, 1);
    playback->id = g_strdup(record_id);
    playback->state = state;
    playback->text = g_strdup(text);
    return post(playback_apply, playback, playback_free);
}

typedef struct Polish {
    GPtrArray *models;
    gboolean enabled;
    gint32 selected;
    gchar *prompt;
} Polish;

static void polish_free(gpointer pointer) {
    Polish *polish = pointer;
    g_ptr_array_unref(polish->models);
    g_free(polish->prompt);
    g_free(polish);
}

static void polish_apply(gpointer pointer) {
    Polish *polish = pointer;
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(ui.polish_models));
    g_ptr_array_add(polish->models, NULL);
    gtk_string_list_splice(ui.polish_models, 0, existing, (const char *const *)polish->models->pdata);
    if (polish->selected >= 0) adw_combo_row_set_selected(ui.polish_model_row, (guint)polish->selected);
    adw_switch_row_set_active(ui.polish_row, polish->enabled);
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_prompt_row), polish->prompt != NULL ? polish->prompt : "");
}

int32_t jsti_window_set_post_processing(
    const char *const *models, size_t count, int32_t enabled, int32_t selected, const char *prompt) {
    Polish *polish = g_new0(Polish, 1);
    polish->models = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(polish->models, g_strdup(models[index]));
    polish->enabled = enabled != 0;
    polish->selected = selected;
    polish->prompt = g_strdup(prompt);
    return post(polish_apply, polish, polish_free);
}

static void azure_apply(gpointer data) {
    ui.suppress = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(ui.azure_row), data != NULL ? data : "");
    ui.suppress = FALSE;
}

int32_t jsti_window_set_azure_resource(const char *endpoint) {
    return post(azure_apply, g_strdup(endpoint != NULL ? endpoint : ""), g_free);
}

static void style_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.style_row, (guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
}

int32_t jsti_window_set_shortcut_style(int32_t index) {
    if (index < 0 || index > 3) return -1;
    return post(style_apply, GINT_TO_POINTER(index), NULL);
}

static void active_work(JSTIMainCall *call, gpointer data) {
    *(gint *)data = ui.window != NULL && gtk_window_is_active(ui.window) ? 1 : 0;
    jsti_main_call_complete(call);
}

int32_t jsti_window_is_active(void) {
    if (!jsti_window_loop_running()) return 0;
    gint *active = g_new0(gint, 1);
    /* On timeout the pending work still owns `active`; leak it rather than
     * free it under the main thread. Report focused, the safe answer. */
    if (!jsti_main_invoke_sync(active_work, active, NULL, 1000)) return jsti_window_loop_running() ? 1 : 0;
    int32_t result = *active;
    g_free(active);
    return result;
}

static void close_apply(gpointer data) {
    (void)data;
    if (ui.window != NULL) gtk_window_close(ui.window);
}

void jsti_window_request_close(void) { post(close_apply, NULL, NULL); }

typedef struct Notice {
    gchar *title;
    gchar *body;
} Notice;

static void notice_free(gpointer pointer) {
    Notice *notice = pointer;
    g_free(notice->title);
    g_free(notice->body);
    g_free(notice);
}

static void notice_apply(gpointer pointer) {
    Notice *notice = pointer;
    GNotification *notification = g_notification_new(notice->title);
    g_notification_set_body(notification, notice->body);
    g_application_send_notification(G_APPLICATION(ui.application), "dictation", notification);
    g_object_unref(notification);
}

void jsti_notify(const char *title, const char *body) {
    Notice *notice = g_new0(Notice, 1);
    notice->title = g_strdup(title);
    notice->body = g_strdup(body);
    post(notice_apply, notice, notice_free);
}

/* ---------------------------------------------------------- self-test */

static int32_t fail(char *error, size_t capacity, const char *message) {
    jsti_set_error(error, capacity, "Window self-test: %s", message);
    return -1;
}

int32_t jsti_window_self_test(char *error, size_t capacity) {
    if (ui.window == NULL) return fail(error, capacity, "the window was not created");
    if (g_list_model_get_n_items(G_LIST_MODEL(ui.model_names)) == 0) {
        return fail(error, capacity, "no models are offered");
    }
    /* The Azure resource row follows the picker: shown for Azure models only. */
    guint original = adw_combo_row_get_selected(ui.model_row);
    guint azure = GTK_INVALID_LIST_POSITION, other = GTK_INVALID_LIST_POSITION;
    for (guint index = 0; index < ui.model_slots->len; index++) {
        gboolean is_azure = g_str_has_prefix(g_array_index(ui.model_slots, Slot, index).id, "azure/");
        if (is_azure && azure == GTK_INVALID_LIST_POSITION) azure = index;
        if (!is_azure && other == GTK_INVALID_LIST_POSITION) other = index;
    }
    if (azure == GTK_INVALID_LIST_POSITION || other == GTK_INVALID_LIST_POSITION) {
        return fail(error, capacity, "the picker offers no Azure model, or only Azure models");
    }
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.model_row, azure);
    gboolean shown_for_azure = gtk_widget_get_visible(GTK_WIDGET(ui.azure_row));
    adw_combo_row_set_selected(ui.model_row, other);
    gboolean shown_for_other = gtk_widget_get_visible(GTK_WIDGET(ui.azure_row));
    adw_combo_row_set_selected(ui.model_row, original);
    ui.suppress = FALSE;
    if (!shown_for_azure || shown_for_other) {
        return fail(error, capacity, "the Azure resource row did not follow the selected model");
    }
    for (guint index = 0; index < ui.model_slots->len; index++) {
        if (!g_str_has_prefix(g_array_index(ui.model_slots, Slot, index).id, "local/")) continue;
        ui.suppress = TRUE;
        adw_combo_row_set_selected(ui.model_row, index);
        gboolean key_for_local = gtk_widget_get_visible(GTK_WIDGET(ui.key_row));
        adw_combo_row_set_selected(ui.model_row, original);
        ui.suppress = FALSE;
        if (key_for_local) return fail(error, capacity, "an on-device model asks for an API key");
        break;
    }
    if (jsti_local_models_self_test(error, capacity) != 0) return -1;
    const char *first = "00000000-0000-0000-0000-000000000001";
    const char *second = "00000000-0000-0000-0000-000000000002";
    JSTIHistoryRow rows[] = {
        { first, "Today · Model A", "First transcript" },
        { second, "Today · Model B", "Second transcript" },
    };
    History *history = history_copy(rows, G_N_ELEMENTS(rows), first);
    history_apply(history);
    history_free(history);
    if (ui.history_ids->len != 2 || g_strcmp0(ui.selected_id, first) != 0) {
        return fail(error, capacity, "History rows or selection were not applied");
    }
    Presentation stale = { .id = (gchar *)second, .variant = 0, .switchable = TRUE,
                           .text = (gchar *)"Stale", .status = (gchar *)"Stale", .has_text = TRUE };
    presentation_apply(&stale);
    gchar *shown = displayed_transcript();
    gboolean leaked = g_strcmp0(shown, "Stale") == 0;
    g_free(shown);
    if (leaked) return fail(error, capacity, "an unselected record's text was displayed");
    Presentation current = { .id = (gchar *)first, .variant = 0, .switchable = TRUE,
                             .text = (gchar *)"Processed text", .status = (gchar *)"Shown", .has_text = TRUE };
    presentation_apply(&current);
    char buffer[64];
    size_t required = 0;
    if (jsti_window_transcript_snapshot(buffer, sizeof buffer, &required) != 0 ||
        g_strcmp0(buffer, "Processed text") != 0 || jsti_window_transcript_variant() != 0) {
        return fail(error, capacity, "the displayed transcript snapshot did not match");
    }
    if (!gtk_widget_get_sensitive(GTK_WIDGET(ui.copy)) || !gtk_widget_get_visible(GTK_WIDGET(ui.version))) {
        return fail(error, capacity, "Copy or the version control stayed unavailable");
    }
    History *empty = history_copy(NULL, 0, "");
    history_apply(empty);
    history_free(empty);
    Update clear = { .status = (gchar *)"Self-test complete.", .transcript = (gchar *)"", .has_transcript = TRUE,
                     .state = JSTI_STATE_IDLE };
    update_apply(&clear);
    if (ui.selected_id != NULL || gtk_widget_get_sensitive(GTK_WIDGET(ui.copy))) {
        return fail(error, capacity, "clearing History left record actions enabled");
    }
    return 0;
}

/* Renders the window to a PNG for visual review in smoke tests. */
int32_t jsti_window_save_snapshot(const char *path, char *error, size_t capacity) {
    if (ui.window == NULL) return fail(error, capacity, "no window to capture");
    /* A root's own paintable is empty; capture its content instead. */
    GtkWidget *widget = adw_application_window_get_content(ADW_APPLICATION_WINDOW(ui.window));
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, snapshot, width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    int32_t result = -1;
    if (node != NULL) {
        GskRenderer *renderer = gtk_native_get_renderer(GTK_NATIVE(ui.window));
        GdkTexture *texture = gsk_renderer_render_texture(
            renderer, node, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
        if (texture != NULL && gdk_texture_save_to_png(texture, path)) result = 0;
        if (texture != NULL) g_object_unref(texture);
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    if (result != 0) jsti_set_error(error, capacity, "The window snapshot could not be saved (%dx%d, node %s).", width, height, node != NULL ? "rendered" : "empty");
    return result;
}
