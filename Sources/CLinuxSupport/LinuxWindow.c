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
    /* Navigation */
    AdwNavigationSplitView *split;
    GtkListBox *sidebar;
    GtkStack *pages;
    AdwWindowTitle *title;
    gint32 page;
    /* Record buttons: the header's and the dashboard hero's. */
    GtkButton *header_record;
    GtkButton *hero_record;
    GtkLabel *live_preview;
    GtkButton *dashboard_copy;
    GtkButton *history_import;
    /* Totals: dashboard hero chips, the Insights card and the History header. */
    GtkLabel *hero_sessions, *hero_time, *hero_spend;
    GtkLabel *insight_sessions, *insight_time, *insight_average, *insight_spend;
    GtkLabel *history_sessions, *history_errors, *history_average, *history_spend;
    /* Setup card on the dashboard. */
    GtkLabel *setup_microphone, *setup_model, *setup_shortcut, *setup_output;
    /* The selected History card's transcript and actions, moved into that card. */
    GtkWidget *detail;
    GtkWidget *history_empty;
    /* Voice Output page actions. */
    GtkButton *voice_read;
    GtkButton *voice_stop;
    AdwComboRow *appearance_row;
} UI;

static UI ui;

/* Read aloud: its History action and the voice picker in its own group. */
static struct {
    GtkButton *button;
    AdwComboRow *voice_row;
    GtkStringList *voices;
} read_aloud;

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

static const char *combo_text(AdwComboRow *row) {
    GObject *item = adw_combo_row_get_selected_item(row);
    return item != NULL ? gtk_string_object_get_string(GTK_STRING_OBJECT(item)) : NULL;
}

/* The dashboard's Setup card and the header subtitle echo the settings. */
static void refresh_setup(void) {
    const char *microphone = combo_text(ui.microphone_row);
    gtk_label_set_text(ui.setup_microphone, microphone != NULL ? microphone : "Default microphone");
    const char *model = combo_text(ui.model_row);
    gtk_label_set_text(ui.setup_model, model != NULL ? model : "No model selected");
    adw_window_title_set_subtitle(ui.title, model != NULL ? model : "");
    const char *output = combo_text(ui.output_row);
    gboolean restores = adw_combo_row_get_selected(ui.output_row) == 0 && adw_switch_row_get_active(ui.restore_row);
    gchar *text = g_strdup_printf("%s%s", output != NULL ? output : "", restores ? " · clipboard restored" : "");
    gtk_label_set_text(ui.setup_output, text);
    g_free(text);
    const char *hint = adw_action_row_get_subtitle(ui.shortcut_row);
    gtk_label_set_text(ui.setup_shortcut, hint != NULL && hint[0] != '\0' ? hint : "Checking the desktop…");
}

static void refresh_actions(void) {
    gboolean idle = ui.state == JSTI_STATE_IDLE;
    gchar *text = displayed_transcript();
    gboolean has_text = text != NULL && text[0] != '\0';
    g_free(text);
    gboolean has_record = ui.selected_id != NULL;
    gboolean presented = has_record && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy), has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.dashboard_copy), has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gtk_widget_set_visible(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gboolean recording = ui.state == JSTI_STATE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), ui.state != JSTI_STATE_WORKING);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.header_record), ui.state != JSTI_STATE_WORKING);
    gtk_button_set_label(ui.record, recording ? "Stop Recording"
                                    : ui.state == JSTI_STATE_WORKING ? "Transcribing…" : "Start Recording");
    adw_button_content_set_label(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                 recording ? "Stop" : "Record");
    adw_button_content_set_icon_name(ADW_BUTTON_CONTENT(gtk_button_get_child(ui.header_record)),
                                     recording ? "media-playback-stop-symbolic" : "audio-input-microphone-symbolic");
    if (recording) {
        gtk_widget_add_css_class(GTK_WIDGET(ui.record), "recording");
        gtk_widget_add_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    } else {
        gtk_widget_remove_css_class(GTK_WIDGET(ui.record), "recording");
        gtk_widget_remove_css_class(GTK_WIDGET(ui.header_record), "destructive-action");
    }
    /* While recording, the hero previews the words as they arrive. */
    gchar *preview = recording ? displayed_transcript() : NULL;
    gtk_label_set_text(ui.live_preview, preview != NULL && preview[0] != '\0' ? preview : "Listening…");
    gtk_widget_set_visible(GTK_WIDGET(ui.live_preview), recording);
    g_free(preview);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.retry), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.export_button), idle && presented && has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.open_audio), has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), has_record && (idle || ui.playback_state != 0));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop_play), has_record && ui.playback_state != 0);
    gtk_button_set_label(ui.play, ui.playback_state == 1 ? "Pause" : "Play");
    /* Speaks the presented record's displayed text, so it needs both. */
    gboolean voices = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) > 0;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.button), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_read), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), has_record && ui.playback_state != 0);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.voice_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.import_button), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_import), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.model_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.microphone_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.version), presented && ui.presented_switchable && idle);
    gtk_widget_set_visible(GTK_WIDGET(ui.version), presented && ui.presented_switchable);
    refresh_setup();
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
    refresh_setup();
    gint32 slot = selected_model_slot();
    if (slot >= 0) emit(JSTI_EVENT_SELECT_MODEL, "", slot);
}

static void on_azure_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_AZURE_RESOURCE, gtk_editable_get_text(GTK_EDITABLE(row)), 0);
}

static void on_microphone(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_setup();
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
    refresh_setup();
    emit(JSTI_EVENT_TEXT_OUTPUT, restore ? "restore" : "", (gint32)method);
}

static void apply_appearance(guint appearance) {
    static const AdwColorScheme schemes[] = { ADW_COLOR_SCHEME_DEFAULT, ADW_COLOR_SCHEME_FORCE_LIGHT,
                                              ADW_COLOR_SCHEME_FORCE_DARK };
    if (appearance < G_N_ELEMENTS(schemes)) {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), schemes[appearance]);
    }
}

static void on_appearance(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint appearance = adw_combo_row_get_selected(ui.appearance_row);
    apply_appearance(appearance);
    emit(JSTI_EVENT_APPEARANCE, "", (gint32)appearance);
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

/* The transcript and actions live in the selected History card, as the Mac
 * expands its selected row. The window holds its own reference, so moving
 * the detail between cards or rebuilding the list never destroys it. */
static void detach_detail(void) {
    GtkWidget *parent = gtk_widget_get_parent(ui.detail);
    if (parent != NULL) gtk_box_remove(GTK_BOX(parent), ui.detail);
}

static void attach_detail(GtkListBoxRow *row) {
    GtkWidget *card = row != NULL ? gtk_list_box_row_get_child(row) : NULL;
    if (card != NULL && gtk_widget_get_parent(ui.detail) == card) return;
    detach_detail();
    if (card != NULL) gtk_box_append(GTK_BOX(card), ui.detail);
}

static void on_history_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    attach_detail(row);
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

/* The host captures the displayed text with jsti_window_transcript_snapshot
 * while this event runs, so it is the text shown under this record. */
static void on_read_aloud(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id == NULL || g_strcmp0(ui.presented_id, ui.selected_id) != 0) return;
    emit(JSTI_EVENT_READ_ALOUD, ui.selected_id, 0);
}

static void on_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (position != GTK_INVALID_LIST_POSITION) emit(JSTI_EVENT_VOICE_OUTPUT, "", (gint32)position);
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
    jsti_hud_destroy();
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

/* The voice Read aloud uses; the list comes from jsti_window_set_voices. */
static GtkWidget *read_aloud_group(void) {
    GtkWidget *widget = group("Voice");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(widget),
        "Read aloud speaks the transcript shown for the selected recording with a Deepgram voice, using the "
        "saved Deepgram API key. Play, Pause and Stop control it.");
    read_aloud.voices = gtk_string_list_new(NULL);
    read_aloud.voice_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(read_aloud.voice_row), "Voice");
    adw_combo_row_set_model(read_aloud.voice_row, G_LIST_MODEL(read_aloud.voices));
    adw_combo_row_set_enable_search(read_aloud.voice_row, TRUE);
    g_signal_connect(read_aloud.voice_row, "notify::selected", G_CALLBACK(on_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), GTK_WIDGET(read_aloud.voice_row));
    return widget;
}

/* Sidebar entries in page order, with the Mac sidebar's tints. */
static const struct {
    const char *name;
    const char *title;
    const char *icon;
    const char *tint;
} page_info[JSTI_PAGE_COUNT] = {
    [JSTI_PAGE_DASHBOARD] = { "dashboard", "Dashboard", "view-grid-symbolic", "jsti-tint-lagoon" },
    [JSTI_PAGE_HISTORY] = { "history", "History", "document-open-recent-symbolic", "jsti-tint-accent" },
    [JSTI_PAGE_VOICE_OUTPUT] = { "voice-output", "Voice Output", "audio-speakers-symbolic", "jsti-tint-green" },
    [JSTI_PAGE_GENERAL] = { "general", "General", "emblem-system-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_TRANSCRIPTION] = { "transcription", "Transcription", "audio-input-microphone-symbolic",
                                  "jsti-tint-warm" },
    [JSTI_PAGE_POST_PROCESSING] = { "post-processing", "Post-processing", "starred-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_KEYBOARD] = { "keyboard", "Keyboard", "input-keyboard-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_CLOUD_SYNC] = { "icloud-sync", "iCloud Sync", "emblem-synchronizing-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_ABOUT] = { "about", "About", "help-about-symbolic", "jsti-tint-warm" },
};

static void show_page(gint32 page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return;
    ui.page = page;
    gtk_stack_set_visible_child_name(ui.pages, page_info[page].name);
    adw_window_title_set_title(ui.title, page_info[page].title);
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.sidebar, page);
    if (row != NULL && gtk_list_box_get_selected_row(ui.sidebar) != row) gtk_list_box_select_row(ui.sidebar, row);
    adw_navigation_split_view_set_show_content(ui.split, TRUE);
}

static void on_sidebar(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    if (row != NULL) show_page(gtk_list_box_row_get_index(row));
}

static void sidebar_header(GtkListBoxRow *row, GtkListBoxRow *before, gpointer data) {
    (void)before; (void)data;
    gint index = gtk_list_box_row_get_index(row);
    const char *heading = index == JSTI_PAGE_DASHBOARD ? "Speak" : index == JSTI_PAGE_GENERAL ? "Settings" : NULL;
    if (heading == NULL) {
        gtk_list_box_row_set_header(row, NULL);
        return;
    }
    GtkWidget *label = gtk_label_new(heading);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_add_css_class(label, "jsti-sidebar-heading");
    gtk_list_box_row_set_header(row, label);
}

static GtkWidget *build_sidebar(void) {
    ui.sidebar = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(ui.sidebar), "navigation-sidebar");
    gtk_widget_add_css_class(GTK_WIDGET(ui.sidebar), "jsti-sidebar");
    gtk_list_box_set_header_func(ui.sidebar, sidebar_header, NULL, NULL);
    for (gint32 page = 0; page < JSTI_PAGE_COUNT; page++) {
        GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
        GtkWidget *image = gtk_image_new_from_icon_name(page_info[page].icon);
        gtk_widget_add_css_class(image, page_info[page].tint);
        gtk_box_append(GTK_BOX(line), image);
        GtkWidget *label = gtk_label_new(page_info[page].title);
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_box_append(GTK_BOX(line), label);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), line);
        if (page >= JSTI_PAGE_GENERAL) gtk_widget_add_css_class(row, "jsti-settings-row");
        gtk_list_box_append(ui.sidebar, row);
    }
    g_signal_connect(ui.sidebar, "row-selected", G_CALLBACK(on_sidebar), NULL);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), GTK_WIDGET(ui.sidebar));
    GtkWidget *toolbar = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    GtkWidget *brand = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(brand), jsti_brand_icon_new(22));
    GtkWidget *name = gtk_label_new("Just Speak to It");
    gtk_widget_add_css_class(name, "heading");
    gtk_box_append(GTK_BOX(brand), name);
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), brand);
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), scroller);
    return toolbar;
}

static GtkWidget *settings_hero(const char *title, const char *subtitle) {
    return jsti_hero_new("settings", title, subtitle, NULL, NULL);
}

static void add_page(gint32 page, GtkWidget *widget) {
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
static GtkWidget *columns;

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
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(flow), 2);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 2);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow), 10);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow), 10);
    for (int index = 0; index < count; index++) gtk_flow_box_append(GTK_FLOW_BOX(flow), items[index]);
    for (GtkWidget *child = gtk_widget_get_first_child(flow); child != NULL; child = gtk_widget_get_next_sibling(child)) {
        gtk_widget_set_focusable(child, FALSE);
    }
    return flow;
}

static GtkWidget *build_dashboard(GtkTextBuffer *buffer) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *chips, *trailing;
    GtkWidget *hero = jsti_hero_new(
        NULL, "Speak Dashboard",
        "Ready to capture ideas instantly. Check your setup, follow your usage, and pick up your latest session.",
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
    gtk_box_append(GTK_BOX(body), transcript_view(buffer, 96));
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

static GtkWidget *build_history(GtkTextBuffer *buffer) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *chips, *trailing;
    GtkWidget *hero = jsti_hero_new(
        NULL, "Session History", "Search, replay and reuse past recordings and their transcripts.", &chips,
        &trailing);
    ui.history_import = GTK_BUTTON(gtk_button_new_with_label("Import…"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.history_import), "jsti-hero-button");
    g_signal_connect(ui.history_import, "clicked", G_CALLBACK(on_import), NULL);
    gtk_box_append(GTK_BOX(trailing), GTK_WIDGET(ui.history_import));
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
    ui.open_audio = GTK_BUTTON(gtk_button_new_with_label("Open audio"));
    g_signal_connect(ui.retry, "clicked", G_CALLBACK(on_retry), NULL);
    g_signal_connect(ui.export_button, "clicked", G_CALLBACK(on_export), NULL);
    g_signal_connect(ui.open_audio, "clicked", G_CALLBACK(on_open_audio), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(read_aloud.button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.retry));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.export_button));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.open_audio));
    gtk_box_append(GTK_BOX(ui.detail), actions);
    return page;
}

static GtkWidget *build_voice_output(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), jsti_hero_new(
        "voice", "Voice Output",
        "Hear any History transcript read back in a Deepgram Aura voice, through your own Deepgram key.", NULL,
        NULL));
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("audio-speakers-symbolic", "Read aloud", &body);
    gtk_box_append(GTK_BOX(body), read_aloud_group());
    GtkWidget *note = gtk_label_new(
        "Choose a recording in History, then read its transcript aloud here or from its card. Starting a "
        "recording, choosing another recording or pressing Stop ends it.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_box_append(GTK_BOX(body), note);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    ui.voice_stop = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(ui.voice_stop, "clicked", G_CALLBACK(on_stop_play), NULL);
    ui.voice_read = GTK_BUTTON(gtk_button_new_with_label("Read Selected Recording"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.voice_read), "suggested-action");
    g_signal_connect(ui.voice_read, "clicked", G_CALLBACK(on_read_aloud), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_stop));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_read));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), card);
    return page;
}

static GtkWidget *build_general(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "General", "Choose the microphone, where finished text goes, and how the app looks."));
    GtkWidget *microphone = group("Microphone");
    ui.microphone_names = gtk_string_list_new(NULL);
    ui.microphone_ids = g_ptr_array_new_with_free_func(g_free);
    ui.microphone_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.microphone_row), "Preferred microphone");
    adw_combo_row_set_model(ui.microphone_row, G_LIST_MODEL(ui.microphone_names));
    g_signal_connect(ui.microphone_row, "notify::selected", G_CALLBACK(on_microphone), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(microphone), GTK_WIDGET(ui.microphone_row));
    gtk_box_append(GTK_BOX(column), microphone);

    GtkWidget *output = group("Output");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(output),
        "Finished text goes to the app you were in when dictation started. Recording in this window offers "
        "Copy instead.");
    const char *methods[] = { "Paste into the focused app", "Copy to the clipboard only", NULL };
    ui.output_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.output_row), "Text output");
    adw_combo_row_set_model(ui.output_row, G_LIST_MODEL(gtk_string_list_new(methods)));
    g_signal_connect(ui.output_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.output_row));
    ui.restore_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.restore_row), "Restore the clipboard after pasting");
    adw_switch_row_set_active(ui.restore_row, TRUE);
    g_signal_connect(ui.restore_row, "notify::active", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.restore_row));
    gtk_box_append(GTK_BOX(column), output);

    GtkWidget *appearance = group("Appearance");
    const char *schemes[] = { "Follow the system", "Light", "Dark", NULL };
    ui.appearance_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.appearance_row), "Theme");
    adw_combo_row_set_model(ui.appearance_row, G_LIST_MODEL(gtk_string_list_new(schemes)));
    g_signal_connect(ui.appearance_row, "notify::selected", G_CALLBACK(on_appearance), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(appearance), GTK_WIDGET(ui.appearance_row));
    gtk_box_append(GTK_BOX(column), appearance);
    return page;
}

static GtkWidget *build_transcription(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Transcription", "Pick the speech model for new recordings, on this computer or with your own provider key."));
    GtkWidget *models = group("Model");
    ui.model_names = gtk_string_list_new(NULL);
    ui.model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.model_row), "Transcription model");
    adw_combo_row_set_model(ui.model_row, G_LIST_MODEL(ui.model_names));
    adw_combo_row_set_enable_search(ui.model_row, TRUE);
    g_signal_connect(ui.model_row, "notify::selected", G_CALLBACK(on_model), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.model_row));

    ui.key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.key_row), "API key for the selected provider");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(ui.key_row), TRUE);
    g_signal_connect(ui.key_row, "apply", G_CALLBACK(on_key_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.key_row));

    /* Recorded audio falls back to the key's region; live Azure needs this. */
    ui.azure_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.azure_row),
                                  "Azure Speech resource endpoint (https://…cognitiveservices.azure.com)");
    adw_entry_row_set_show_apply_button(ui.azure_row, TRUE);
    adw_entry_row_set_input_purpose(ui.azure_row, GTK_INPUT_PURPOSE_URL);
    g_signal_connect(ui.azure_row, "apply", G_CALLBACK(on_azure_apply), NULL);
    gtk_widget_set_visible(GTK_WIDGET(ui.azure_row), FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(ui.azure_row));

    GtkWidget *catalog = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(catalog, 8);
    ui.catalog_status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(ui.catalog_status, TRUE);
    gtk_label_set_xalign(ui.catalog_status, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(ui.catalog_status), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(ui.catalog_status), "dim-label");
    ui.catalog_refresh = GTK_BUTTON(gtk_button_new_with_label("Refresh models"));
    g_signal_connect(ui.catalog_refresh, "clicked", G_CALLBACK(on_refresh), NULL);
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_status));
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(ui.catalog_refresh));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), catalog);
    gtk_box_append(GTK_BOX(column), models);
    gtk_box_append(GTK_BOX(column), jsti_local_models_group_new());
    return page;
}

static GtkWidget *build_post_processing(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Post-processing", "Optionally polish transcripts with an OpenRouter model. The original is always kept."));
    GtkWidget *polish = group("Clean-up");
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
    gtk_widget_add_css_class(polish_apply, "suggested-action");
    gtk_widget_set_halign(polish_apply, GTK_ALIGN_END);
    gtk_widget_set_margin_top(polish_apply, 8);
    g_signal_connect(polish_apply, "clicked", G_CALLBACK(on_polish_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), polish_apply);
    gtk_box_append(GTK_BOX(column), polish);
    return page;
}

static GtkWidget *build_keyboard(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Keyboard", "Start and stop dictation from anywhere with a global shortcut."));
    GtkWidget *shortcut = group("Shortcut");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(shortcut),
        "Where the desktop offers no shortcut portal, bind the command justspeaktoit --toggle to a key in your "
        "desktop's keyboard settings.");
    ui.shortcut_row = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.shortcut_row), "Keyboard shortcut");
    adw_action_row_set_subtitle(ui.shortcut_row, "Checking the desktop…");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(ui.shortcut_row));
    const char *styles[] = { "Press to toggle", "Hold to record", "Double-tap to toggle",
                             "Hold, or double-tap to toggle", NULL };
    ui.style_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.style_row), "Activation");
    adw_combo_row_set_model(ui.style_row, G_LIST_MODEL(gtk_string_list_new(styles)));
    g_signal_connect(ui.style_row, "notify::selected", G_CALLBACK(on_style), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(ui.style_row));
    gtk_box_append(GTK_BOX(column), shortcut);
    return page;
}

static GtkWidget *build_cloud_sync(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "iCloud Sync", "Keep History in step with your Mac, through your own iCloud account."));
    gtk_box_append(GTK_BOX(column), jsti_cloud_sync_group_new());
    return page;
}

static void open_link(GtkButton *button, gpointer data) {
    (void)button;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(data);
    gtk_uri_launcher_launch(launcher, ui.window, NULL, NULL, NULL);
    g_object_unref(launcher);
}

static GtkWidget *link_button(const char *label, const char *uri) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_signal_connect(button, "clicked", G_CALLBACK(open_link), (gpointer)uri);
    return button;
}

static GtkWidget *build_about(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("help-about-symbolic", "About", &body);
    GtkWidget *identity = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 18);
    gtk_box_append(GTK_BOX(identity), jsti_brand_icon_new(72));
    GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
    GtkWidget *name = gtk_label_new("Just Speak to It");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_widget_add_css_class(name, "jsti-about-name");
    gtk_box_append(GTK_BOX(names), name);
    GtkWidget *tagline = gtk_label_new("Voice-to-text made simple. Linux developer preview.");
    gtk_label_set_xalign(GTK_LABEL(tagline), 0);
    gtk_widget_add_css_class(tagline, "dim-label");
    gtk_box_append(GTK_BOX(names), tagline);
    gtk_box_append(GTK_BOX(identity), names);
    gtk_box_append(GTK_BOX(body), identity);
    GtkWidget *note = gtk_label_new(
        "Open source under the MIT licence. Your audio goes only to the provider you choose, or stays on this "
        "computer with an on-device model.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_box_append(GTK_BOX(body), note);
    GtkWidget *links = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(links), link_button("View on GitHub", "https://github.com/crmitchelmore/justspeaktoit"));
    gtk_box_append(GTK_BOX(links), link_button(
        "Report an Issue", "https://github.com/crmitchelmore/justspeaktoit/issues/new"));
    gtk_box_append(GTK_BOX(links), link_button("Privacy Policy", "https://justspeaktoit.com/privacy"));
    gtk_box_append(GTK_BOX(body), links);
    gtk_box_append(GTK_BOX(column), card);
    return page;
}

static void build_window(void) {
    jsti_style_install();
    GtkWidget *window = adw_application_window_new(GTK_APPLICATION(ui.application));
    ui.window = GTK_WINDOW(window);
    gtk_window_set_title(ui.window, "Just Speak to It");
    gtk_window_set_default_size(ui.window, 1080, 760);
    gtk_widget_set_size_request(window, 360, 480);
    g_signal_connect(window, "close-request", G_CALLBACK(on_close_request), NULL);

    /* One transcript buffer: the dashboard and the selected History card show
     * the same displayed text, which Copy, Export and Read aloud act on. */
    GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
    ui.pages = GTK_STACK(gtk_stack_new());
    gtk_stack_set_transition_type(ui.pages, GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    GtkWidget *sidebar = build_sidebar();
    add_page(JSTI_PAGE_DASHBOARD, build_dashboard(buffer));
    add_page(JSTI_PAGE_HISTORY, build_history(buffer));
    add_page(JSTI_PAGE_VOICE_OUTPUT, build_voice_output());
    add_page(JSTI_PAGE_GENERAL, build_general());
    add_page(JSTI_PAGE_TRANSCRIPTION, build_transcription());
    add_page(JSTI_PAGE_POST_PROCESSING, build_post_processing());
    add_page(JSTI_PAGE_KEYBOARD, build_keyboard());
    add_page(JSTI_PAGE_CLOUD_SYNC, build_cloud_sync());
    add_page(JSTI_PAGE_ABOUT, build_about());
    g_object_unref(buffer);

    GtkWidget *content = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    ui.title = ADW_WINDOW_TITLE(adw_window_title_new("Dashboard", ""));
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), GTK_WIDGET(ui.title));
    ui.import_button = GTK_BUTTON(gtk_button_new_from_icon_name("document-open-symbolic"));
    gtk_widget_set_tooltip_text(GTK_WIDGET(ui.import_button), "Import audio…");
    g_signal_connect(ui.import_button, "clicked", G_CALLBACK(on_import), NULL);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), GTK_WIDGET(ui.import_button));
    ui.header_record = GTK_BUTTON(gtk_button_new());
    GtkWidget *record_content = adw_button_content_new();
    adw_button_content_set_icon_name(ADW_BUTTON_CONTENT(record_content), "audio-input-microphone-symbolic");
    adw_button_content_set_label(ADW_BUTTON_CONTENT(record_content), "Record");
    gtk_button_set_child(ui.header_record, record_content);
    gtk_widget_add_css_class(GTK_WIDGET(ui.header_record), "suggested-action");
    g_signal_connect(ui.header_record, "clicked", G_CALLBACK(on_record), NULL);
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), GTK_WIDGET(ui.header_record));
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(content), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(content), GTK_WIDGET(ui.pages));
    GtkWidget *statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(statusbar, "jsti-statusbar");
    ui.status = GTK_LABEL(gtk_label_new("Starting…"));
    gtk_label_set_wrap(ui.status, TRUE);
    gtk_label_set_xalign(ui.status, 0);
    gtk_label_set_selectable(ui.status, TRUE);
    gtk_widget_set_hexpand(GTK_WIDGET(ui.status), TRUE);
    gtk_box_append(GTK_BOX(statusbar), GTK_WIDGET(ui.status));
    adw_toolbar_view_add_bottom_bar(ADW_TOOLBAR_VIEW(content), statusbar);

    ui.split = ADW_NAVIGATION_SPLIT_VIEW(adw_navigation_split_view_new());
    adw_navigation_split_view_set_min_sidebar_width(ui.split, 210);
    adw_navigation_split_view_set_max_sidebar_width(ui.split, 280);
    adw_navigation_split_view_set_sidebar(ui.split, adw_navigation_page_new(sidebar, "Just Speak to It"));
    adw_navigation_split_view_set_content(ui.split, adw_navigation_page_new(content, "Just Speak to It"));
    /* Narrow windows show one pane at a time, as the Mac's compact layout does. */
    AdwBreakpoint *narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 640sp"));
    GValue collapsed = G_VALUE_INIT;
    g_value_init(&collapsed, G_TYPE_BOOLEAN);
    g_value_set_boolean(&collapsed, TRUE);
    adw_breakpoint_add_setter(narrow, G_OBJECT(ui.split), "collapsed", &collapsed);
    g_value_unset(&collapsed);
    adw_application_window_add_breakpoint(ADW_APPLICATION_WINDOW(window), narrow);
    AdwBreakpoint *stacked = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 900sp"));
    GValue vertical = G_VALUE_INIT;
    g_value_init(&vertical, GTK_TYPE_ORIENTATION);
    g_value_set_enum(&vertical, GTK_ORIENTATION_VERTICAL);
    adw_breakpoint_add_setter(stacked, G_OBJECT(columns), "orientation", &vertical);
    g_value_unset(&vertical);
    adw_application_window_add_breakpoint(ADW_APPLICATION_WINDOW(window), stacked);
    /* The content paints the window background, so snapshots of it are opaque. */
    gtk_widget_add_css_class(GTK_WIDGET(ui.split), "jsti-root");
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(window), GTK_WIDGET(ui.split));
    show_page(JSTI_PAGE_DASHBOARD);
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
    refresh_setup();
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
    refresh_setup();
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

typedef struct HistoryEntry {
    gchar *id, *created, *audio_length, *cost, *preview, *models, *context;
    gint32 tone;
} HistoryEntry;

typedef struct History {
    GArray *entries;
    gchar *selected;
    gboolean select;
} History;

static void history_entry_clear(gpointer pointer) {
    HistoryEntry *entry = pointer;
    g_free(entry->id);
    g_free(entry->created);
    g_free(entry->audio_length);
    g_free(entry->cost);
    g_free(entry->preview);
    g_free(entry->models);
    g_free(entry->context);
}

static void history_free(gpointer pointer) {
    History *history = pointer;
    g_array_unref(history->entries);
    g_free(history->selected);
    g_free(history);
}

/* One History card: badges, the transcript preview and the models line. */
static GtkWidget *history_card(const HistoryEntry *entry) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_add_css_class(card, "jsti-history-row");
    if (entry->tone == 1) gtk_widget_add_css_class(card, "failed");
    /* A row of badges whose values shorten before the card would widen. */
    GtkWidget *badges = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(badges), jsti_badge_new("created", "x-office-calendar-symbolic", "Created",
                                                             entry->created));
    if (entry->audio_length[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("audio", "audio-input-microphone-symbolic", "Audio",
                                                                 entry->audio_length));
    }
    if (entry->cost[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("cost", "emblem-ok-symbolic", "Cost", entry->cost));
    }
    if (entry->context[0] != '\0') {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("context", "avatar-default-symbolic", "Context",
                                                                 entry->context));
    }
    if (entry->tone == 1) {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("error", "dialog-warning-symbolic", "Error",
                                                                 "Needs attention"));
    } else if (entry->tone == 2) {
        gtk_box_append(GTK_BOX(badges), jsti_badge_new("error", "document-open-recent-symbolic", "Status",
                                                                 "Not transcribed"));
    }
    gtk_box_append(GTK_BOX(card), badges);
    GtkWidget *preview = gtk_label_new(entry->preview);
    gtk_label_set_xalign(GTK_LABEL(preview), 0);
    gtk_label_set_wrap(GTK_LABEL(preview), TRUE);
    gtk_label_set_lines(GTK_LABEL(preview), 2);
    gtk_label_set_ellipsize(GTK_LABEL(preview), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(preview, "jsti-history-preview");
    gtk_box_append(GTK_BOX(card), preview);
    GtkWidget *models = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *icon = gtk_image_new_from_icon_name("emblem-system-symbolic");
    gtk_widget_add_css_class(icon, "jsti-history-models");
    gtk_box_append(GTK_BOX(models), icon);
    GtkWidget *names = gtk_label_new(entry->models);
    gtk_label_set_xalign(GTK_LABEL(names), 0);
    gtk_label_set_ellipsize(GTK_LABEL(names), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(names, "jsti-history-models");
    gtk_box_append(GTK_BOX(models), names);
    gtk_box_append(GTK_BOX(card), models);
    return card;
}

static void history_apply(gpointer pointer) {
    History *history = pointer;
    ui.suppress = TRUE;
    detach_detail();
    gtk_list_box_remove_all(ui.history);
    g_ptr_array_set_size(ui.history_ids, 0);
    const char *keep = history->select ? history->selected : ui.selected_id;
    GtkListBoxRow *selected = NULL;
    for (guint index = 0; index < history->entries->len; index++) {
        const HistoryEntry *entry = &g_array_index(history->entries, HistoryEntry, index);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), history_card(entry));
        gtk_list_box_append(ui.history, row);
        g_ptr_array_add(ui.history_ids, g_strdup(entry->id));
        if (g_strcmp0(keep, entry->id) == 0) selected = GTK_LIST_BOX_ROW(row);
    }
    gtk_widget_set_visible(ui.history_empty, history->entries->len == 0);
    if (history->select) {
        g_free(ui.selected_id);
        ui.selected_id = g_strdup(history->selected != NULL && history->selected[0] != '\0' ? history->selected : NULL);
    }
    if (selected != NULL) {
        gtk_list_box_select_row(ui.history, selected);
        attach_detail(selected);
    } else {
        g_clear_pointer(&ui.selected_id, g_free);
        g_clear_pointer(&ui.presented_id, g_free);
    }
    ui.suppress = FALSE;
    refresh_actions();
}

static History *history_copy(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    History *history = g_new0(History, 1);
    history->entries = g_array_sized_new(FALSE, TRUE, sizeof(HistoryEntry), (guint)count);
    g_array_set_clear_func(history->entries, history_entry_clear);
    for (size_t index = 0; index < count; index++) {
        const JSTIHistoryRow *row = &rows[index];
        HistoryEntry entry = {
            .id = g_strdup(row->id), .created = g_strdup(row->created ? row->created : ""),
            .audio_length = g_strdup(row->audio_length ? row->audio_length : ""),
            .cost = g_strdup(row->cost ? row->cost : ""), .preview = g_strdup(row->preview ? row->preview : ""),
            .models = g_strdup(row->models ? row->models : ""),
            .context = g_strdup(row->context ? row->context : ""), .tone = row->tone,
        };
        g_array_append_val(history->entries, entry);
    }
    history->select = selected_id != NULL;
    history->selected = g_strdup(selected_id);
    return history;
}

int32_t jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id) {
    return post(history_apply, history_copy(rows, count, selected_id), history_free);
}

typedef struct Insights {
    gchar *all[5];
    gchar *visible[5];
} Insights;

static void insights_free(gpointer pointer) {
    Insights *insights = pointer;
    for (int index = 0; index < 5; index++) {
        g_free(insights->all[index]);
        g_free(insights->visible[index]);
    }
    g_free(insights);
}

static void insights_apply(gpointer pointer) {
    Insights *insights = pointer;
    /* Order: sessions, errors, recording time, average length, spend. */
    gtk_label_set_text(ui.hero_sessions, insights->all[0]);
    gtk_label_set_text(ui.hero_time, insights->all[2]);
    gtk_label_set_text(ui.hero_spend, insights->all[4]);
    gtk_label_set_text(ui.insight_sessions, insights->all[0]);
    gtk_label_set_text(ui.insight_time, insights->all[2]);
    gtk_label_set_text(ui.insight_average, insights->all[3]);
    gtk_label_set_text(ui.insight_spend, insights->all[4]);
    gtk_label_set_text(ui.history_sessions, insights->visible[0]);
    gtk_label_set_text(ui.history_errors, insights->visible[1]);
    gtk_label_set_text(ui.history_average, insights->visible[3]);
    gtk_label_set_text(ui.history_spend, insights->visible[4]);
}

static void insights_copy(gchar **target, const JSTIInsights *source) {
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

static void appearance_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.appearance_row, (guint)GPOINTER_TO_INT(data));
    apply_appearance((guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
}

int32_t jsti_window_set_appearance(int32_t appearance) {
    if (appearance < 0 || appearance > 2) return -1;
    return post(appearance_apply, GINT_TO_POINTER(appearance), NULL);
}

typedef struct HUD {
    gint32 phase;
    gchar *headline, *subheadline, *live;
} HUD;

static void hud_free(gpointer pointer) {
    HUD *state = pointer;
    g_free(state->headline);
    g_free(state->subheadline);
    g_free(state->live);
    g_free(state);
}

static void hud_apply(gpointer pointer) {
    HUD *state = pointer;
    jsti_hud_show(state->phase, state->headline, state->subheadline, state->live);
}

int32_t jsti_window_set_hud(int32_t phase, const char *headline, const char *subheadline, const char *live_text) {
    if (phase < 0 || phase > 6) return -1;
    const char *texts[] = { headline, subheadline, live_text };
    for (size_t index = 0; index < G_N_ELEMENTS(texts); ++index) {
        if (texts[index] != NULL && !g_utf8_validate(texts[index], -1, NULL)) return -1;
    }
    HUD *state = g_new0(HUD, 1);
    state->phase = phase;
    state->headline = g_strdup(headline != NULL ? headline : "");
    state->subheadline = g_strdup(subheadline != NULL ? subheadline : "");
    state->live = g_strdup(live_text != NULL ? live_text : "");
    return post(hud_apply, state, hud_free);
}

static void page_apply(gpointer data) { show_page(GPOINTER_TO_INT(data)); }

int32_t jsti_window_show_page(int32_t page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return -1;
    return post(page_apply, GINT_TO_POINTER(page), NULL);
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
    refresh_setup();
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

typedef struct Voices {
    GPtrArray *names;
    gint32 selected;
} Voices;

static void voices_free(gpointer pointer) {
    Voices *voices = pointer;
    g_ptr_array_unref(voices->names);
    g_free(voices);
}

static void voices_apply(gpointer pointer) {
    Voices *voices = pointer;
    ui.suppress = TRUE;
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices));
    g_ptr_array_add(voices->names, NULL);
    gtk_string_list_splice(read_aloud.voices, 0, existing, (const char *const *)voices->names->pdata);
    g_ptr_array_set_size(voices->names, voices->names->len - 1);
    if (voices->selected >= 0 && (guint)voices->selected < voices->names->len) {
        adw_combo_row_set_selected(read_aloud.voice_row, (guint)voices->selected);
    }
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_voices(const char *const *names, size_t count, int32_t selected) {
    if (count > 0 && names == NULL) return -1;
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(voices->names, g_strdup(names[index]));
    voices->selected = selected;
    return post(voices_apply, voices, voices_free);
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

/* The last event the Read aloud check observed instead of reporting it. */
static struct {
    gint32 event;
    gchar *text;
    gint32 index;
} observed;

static void observe_event(gint32 event, const char *text, gint32 index, void *context) {
    (void)context;
    observed.event = event;
    g_free(observed.text);
    observed.text = g_strdup(text);
    observed.index = index;
}

/* Read aloud follows the presented record: offered while its text is shown
 * and the window is idle, it reports that record, and the voice picker
 * reports the chosen position. */
static int32_t read_aloud_self_test(const char *record, char *error, size_t capacity) {
    if (g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) < 2) {
        return fail(error, capacity, "Read aloud offers fewer than two voices");
    }
    if (!gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.button))) {
        return fail(error, capacity, "Read aloud was unavailable for the presented record");
    }
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    g_signal_emit_by_name(read_aloud.button, "clicked");
    gboolean reported = observed.event == JSTI_EVENT_READ_ALOUD && g_strcmp0(observed.text, record) == 0;
    guint saved = adw_combo_row_get_selected(read_aloud.voice_row);
    guint other = saved == 0 ? 1 : 0;
    observed.event = 0;
    adw_combo_row_set_selected(read_aloud.voice_row, other);
    gboolean chosen = observed.event == JSTI_EVENT_VOICE_OUTPUT && observed.index == (gint32)other;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(read_aloud.voice_row, saved);
    ui.suppress = FALSE;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    if (!reported) return fail(error, capacity, "Read aloud did not report the presented record");
    if (!chosen) return fail(error, capacity, "the voice picker did not report the chosen voice");
    Update working = { .state = JSTI_STATE_WORKING };
    update_apply(&working);
    gboolean offered = gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.button));
    Update idle = { .state = JSTI_STATE_IDLE };
    update_apply(&idle);
    if (offered) return fail(error, capacity, "Read aloud stayed available while transcribing");
    return 0;
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
    if (jsti_cloud_sync_self_test(error, capacity) != 0) return -1;
    const char *first = "00000000-0000-0000-0000-000000000001";
    const char *second = "00000000-0000-0000-0000-000000000002";
    JSTIHistoryRow rows[] = {
        { first, "Today", "24.00", "$0.01", "First transcript", "Model A", "Profile: Email", 0 },
        { second, "Today", "", "", "Second transcript", "Model B", "", 1 },
    };
    History *history = history_copy(rows, G_N_ELEMENTS(rows), first);
    history_apply(history);
    history_free(history);
    if (ui.history_ids->len != 2 || g_strcmp0(ui.selected_id, first) != 0) {
        return fail(error, capacity, "History rows or selection were not applied");
    }
    /* The selected card holds the transcript and its actions. */
    GtkListBoxRow *first_row = gtk_list_box_get_row_at_index(ui.history, 0);
    if (gtk_widget_get_parent(ui.detail) != gtk_list_box_row_get_child(first_row)) {
        return fail(error, capacity, "the selected History card does not hold its transcript");
    }
    JSTIInsights totals = { "2", "1", "00m 24s", "00m 12s", "$0.01" };
    Insights *insights = g_new0(Insights, 1);
    insights_copy(insights->all, &totals);
    insights_copy(insights->visible, &totals);
    insights_apply(insights);
    insights_free(insights);
    if (g_strcmp0(gtk_label_get_text(ui.hero_sessions), "2") != 0
        || g_strcmp0(gtk_label_get_text(ui.history_errors), "1") != 0
        || g_strcmp0(gtk_label_get_text(ui.insight_average), "00m 12s") != 0) {
        return fail(error, capacity, "the History totals were not shown");
    }
    for (gint32 page = JSTI_PAGE_COUNT - 1; page >= 0; page--) {
        show_page(page);
        if (g_strcmp0(gtk_stack_get_visible_child_name(ui.pages), page_info[page].name) != 0
            || gtk_list_box_row_get_index(gtk_list_box_get_selected_row(ui.sidebar)) != page) {
            return fail(error, capacity, "a sidebar page could not be shown");
        }
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
    if (read_aloud_self_test(first, error, capacity) != 0) return -1;
    History *empty = history_copy(NULL, 0, "");
    history_apply(empty);
    history_free(empty);
    Update clear = { .status = (gchar *)"Self-test complete.", .transcript = (gchar *)"", .has_transcript = TRUE,
                     .state = JSTI_STATE_IDLE };
    update_apply(&clear);
    if (ui.selected_id != NULL || gtk_widget_get_sensitive(GTK_WIDGET(ui.copy))) {
        return fail(error, capacity, "clearing History left record actions enabled");
    }
    return jsti_hud_self_test(error, capacity);
}

/* ------------------------------------------------------ screenshot tour */

/* Renders `widget` at its allocated size into a PNG, over the window's
 * background colour when `opaque`. */
static int32_t save_widget_png(GtkWidget *widget, const char *path, gboolean opaque) {
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    if (width <= 0 || height <= 0) return -1;
    GtkSnapshot *snapshot = gtk_snapshot_new();
    if (opaque) {
        gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
        GdkRGBA background = dark ? (GdkRGBA){ 0.141, 0.141, 0.141, 1 } : (GdkRGBA){ 0.98, 0.98, 0.98, 1 };
        gtk_snapshot_append_color(snapshot, &background, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
    }
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
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
    return result;
}

typedef struct Tour {
    gchar *directory;
    gint32 step;
} Tour;

enum { TOUR_DARK_DASHBOARD = JSTI_PAGE_COUNT, TOUR_DARK_HISTORY, TOUR_RECORDING, TOUR_HUD_RECORDING,
       TOUR_HUD_COMPLETED, TOUR_DONE };

static gboolean tour_capture(gpointer data);

static void tour_show(Tour *tour) {
    if (tour->step < JSTI_PAGE_COUNT) {
        show_page(tour->step);
    } else if (tour->step == TOUR_DARK_DASHBOARD) {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_DASHBOARD);
    } else if (tour->step == TOUR_DARK_HISTORY) {
        show_page(JSTI_PAGE_HISTORY);
    } else if (tour->step == TOUR_HUD_RECORDING) {
        jsti_hud_show(1, "Recording", "Capturing audio",
                      "Could we move the catch-up to Friday? That gives us a little more time");
    } else if (tour->step == TOUR_HUD_COMPLETED) {
        jsti_hud_show(5, "Completed", "Saved. Pasted into the original window.", "");
    } else {
        /* Late, because it replaces the displayed transcript. */
        Update recording = { .transcript = (gchar *)"Could we move the catch-up to Friday? That gives us a little",
                             .has_transcript = TRUE, .state = JSTI_STATE_RECORDING,
                             .status = (gchar *)"Recording… Press Ctrl+Alt+Space again to stop." };
        update_apply(&recording);
        show_page(JSTI_PAGE_DASHBOARD);
    }
    g_timeout_add(700, tour_capture, tour);
}

static const char *tour_name(gint32 step) {
    switch (step) {
    case TOUR_RECORDING: return "dashboard-recording";
    case TOUR_HUD_RECORDING: return "hud-recording";
    case TOUR_HUD_COMPLETED: return "hud-completed";
    case TOUR_DARK_DASHBOARD: return "dashboard-dark";
    case TOUR_DARK_HISTORY: return "history-dark";
    default: return page_info[step].name;
    }
}

static gboolean tour_capture(gpointer data) {
    Tour *tour = data;
    if (ui.window == NULL) {
        g_free(tour->directory);
        g_free(tour);
        return G_SOURCE_REMOVE;
    }
    gchar *file = g_strdup_printf("%02d-%s.png", tour->step + 1, tour_name(tour->step));
    gchar *path = g_build_filename(tour->directory, file, NULL);
    char message[256] = { 0 };
    if (tour->step == TOUR_HUD_RECORDING || tour->step == TOUR_HUD_COMPLETED) {
        /* The HUD is its own window; X11 only. */
        GtkWidget *card = jsti_hud_card();
        if (card != NULL && save_widget_png(card, path, TRUE) != 0) g_printerr("The HUD %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) {
            tour_show(tour);
        } else {
            g_free(tour->directory);
            g_free(tour);
            gtk_window_close(ui.window);
        }
        return G_SOURCE_REMOVE;
    }
    if (jsti_window_save_snapshot(path, message, sizeof message) != 0) g_printerr("%s\n", message);
    g_free(path);
    g_free(file);
    /* The whole page too, below the fold, on the window's background. */
    GtkWidget *scroller = gtk_stack_get_visible_child(ui.pages);
    GtkWidget *viewport = GTK_IS_SCROLLED_WINDOW(scroller) ? gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scroller))
                                                           : NULL;
    GtkWidget *column = viewport != NULL ? gtk_widget_get_first_child(viewport) : NULL;
    if (column != NULL) {
        file = g_strdup_printf("%02d-%s-full.png", tour->step + 1, tour_name(tour->step));
        path = g_build_filename(tour->directory, file, NULL);
        if (save_widget_png(column, path, TRUE) != 0) g_printerr("The full page %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
    }
    tour->step++;
    if (tour->step < TOUR_DONE) {
        tour_show(tour);
    } else {
        g_free(tour->directory);
        g_free(tour);
        gtk_window_close(ui.window);
    }
    return G_SOURCE_REMOVE;
}

static void tour_start(gpointer data) { tour_show(data); }

int32_t jsti_window_screenshot_tour(const char *directory, char *error, size_t capacity) {
    if (directory == NULL || g_mkdir_with_parents(directory, 0700) != 0) {
        jsti_set_error(error, capacity, "The screenshot folder could not be created.");
        return -1;
    }
    Tour *tour = g_new0(Tour, 1);
    tour->directory = g_strdup(directory);
    /* The tour owns itself once started; post() frees nothing. */
    return post(tour_start, tour, NULL);
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
