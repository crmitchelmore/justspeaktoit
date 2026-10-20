#include "LinuxActionShortcutsInternal.h"

#include <adwaita.h>
#include <glib/gstdio.h>
#include <string.h>

#define JSTI_MAXIMUM_CONFIGURATION_FIELDS 64

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
    gboolean live;
} Slot;

typedef struct Models Models;
static void models_free(gpointer pointer);
static void on_model_filter(gboolean local, gboolean live);

static GMutex cleanup_lock;
static guint64 cleanup_ticket;
static gboolean cleanup_active, cleanup_posted;
static gchar *cleanup_text;
/* UI-thread only; preview text is never a Copy/export/read-aloud source. */
static gboolean cleanup_visible;

static void retire_cleanup_preview(void) {
    g_mutex_lock(&cleanup_lock);
    ++cleanup_ticket;
    cleanup_active = FALSE;
    g_clear_pointer(&cleanup_text, g_free);
    g_mutex_unlock(&cleanup_lock);
}

typedef struct UI {
    AdwApplication *application;
    GtkWindow *window;
    GtkLabel *about_details;
    GtkFlowBox *about_links;
    jsti_window_event_fn callback;
    void *context;
    gint32 flags;
    gboolean ready_sent;
    gboolean suppress;
    /* Started by the login item (--background): the window starts minimised. */
    gboolean start_minimized;
    /* Models: picker position -> global slot. */
    GtkStringList *model_names;
    GArray *model_slots;
    Models *model_catalog;
    gint32 preferred_model_slots[3];
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
    AdwPreferencesGroup *output_group;
    AdwComboRow *output_row;
    AdwComboRow *app_switch_row;
    GtkLabel *app_switch_help;
    gboolean app_switch_configured;
    AdwSwitchRow *restore_row;
    gboolean can_restore_clipboard;
    AdwActionRow *shortcut_row;
    AdwComboRow *style_row;
    /* Post-processing */
    AdwSwitchRow *polish_row;
    AdwComboRow *polish_model_row;
    GtkStringList *polish_models;
    AdwComboRow *polish_location_row;
    GPtrArray *polish_catalog;
    GArray *polish_slots;
    gint32 polish_local_index;
    gint32 polish_remote_selected;
    gint32 polish_local_selected;
    gchar *polish_local_notice;
    GtkTextView *polish_prompt_row;
    AdwPasswordEntryRow *polish_key_row;
    AdwSwitchRow *polish_directives_row;
    AdwSwitchRow *polish_tags_row;
    /* Recording */
    GtkButton *record;
    GtkButton *cancel;
    GtkLabel *status;
    GtkTextView *transcript;
    GtkButton *copy;
    GtkDropDown *version;
    gint32 state;
    gchar *tray_summary; /* Sessions, Recording Time and Spend for the status notifier */
    /* History */
    GtkSearchEntry *search;
    GtkWidget *history_filters;
    GtkButton *history_delete;
    GtkButton *history_clear;
    gchar *all_history_ids;
    GtkListBox *history;
    GPtrArray *history_ids;
    gchar *selected_id;
    gchar *presented_id;
    gint32 presented_variant;
    gboolean presented_switchable;
    GtkButton *retry;
    GtkButton *correction_results;
    GtkButton *export_button;
    GtkButton *open_audio;
    GtkButton *recordings_folder;
    GtkButton *recordings_choose;
    GtkButton *recordings_default;
    GCancellable *location_chooser;
    GtkButton *audio_cleanup;
    AdwSwitchRow *backup_audio;
    AdwSwitchRow *backup_profiles;
    GtkButton *backup_export;
    GtkButton *backup_inspect;
    GCancellable *backup_chooser;
    gboolean closing;
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
    GtkButton *voice_sources;
    AdwComboRow *appearance_row;
    AdwSwitchRow *login_row;
    AdwSwitchRow *automation_row;
    GtkWidget *configuration_columns[5];
} UI;

static UI ui;
static guint polish_remote_count = G_MAXUINT;
static GtkWidget *polish_local_group;
GtkWidget *jsti_vocabulary_page_new(int kind);
GtkWidget *jsti_vocabulary_learning_preferences(void);
int32_t jsti_vocabulary_self_test(char *error, size_t capacity);

static struct {
    GPtrArray *rows;
    GPtrArray *choices;
    GArray *booleans;
    GArray *overlay_settings;
    GArray *hands_free_settings;
    GArray *enabled_by_fields;
    GtkWidget *recovery_group;
    AdwComboRow *recovery_row;
    guint recovery_count;
    gchar *revision;
    JSTIConfigurationCallback callback;
    void *context;
} configuration;

/* Read aloud: its History action and the voice picker in its own group. */
static struct {
    GtkButton *button;
    AdwComboRow *voice_row;
    GtkStringList *voices;
    AdwComboRow *favorite_row;
    GtkStringList *favorite_names;
    GtkButton *favorite_button;
    GPtrArray *identifiers;
    GArray *favorite_ranks;
    GArray *favorite_indices;
    JSTIVoicePickerCallback picker_callback;
    void *picker_context;
    gboolean favorite_pending;
    gboolean favorite_executable;
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
    gboolean restores = ui.can_restore_clipboard && adw_combo_row_get_selected(ui.output_row) == 0 &&
                        adw_switch_row_get_active(ui.restore_row);
    gchar *text = g_strdup_printf("%s%s", output != NULL ? output : "", restores ? " · clipboard restored" : "");
    gtk_label_set_text(ui.setup_output, text);
    g_free(text);
    const char *hint = adw_action_row_get_subtitle(ui.shortcut_row);
    gtk_label_set_text(ui.setup_shortcut, hint != NULL && hint[0] != '\0' ? hint : "Checking the desktop…");
}

static void refresh_actions(void) {
    gboolean idle = ui.state == JSTI_STATE_IDLE;
    jsti_action_shortcut_editor_set_idle(idle);
    jsti_api_keys_set_idle(idle);
    gchar *text = displayed_transcript();
    gboolean has_text = text != NULL && text[0] != '\0';
    g_free(text);
    gboolean has_record = ui.selected_id != NULL;
    gboolean presented = has_record && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.copy), has_text && !cleanup_visible);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.dashboard_copy), has_text && !cleanup_visible);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gtk_widget_set_visible(GTK_WIDGET(ui.cancel), ui.state == JSTI_STATE_WORKING);
    gboolean recording = ui.state == JSTI_STATE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), ui.state != JSTI_STATE_WORKING);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.header_record), ui.state != JSTI_STATE_WORKING);
    gtk_button_set_label(ui.record, recording ? "Stop Recording"
                                    : ui.state == JSTI_STATE_WORKING ? "Working…" : "Start Recording");
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
    gtk_widget_set_sensitive(GTK_WIDGET(ui.correction_results), idle && presented);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.export_button), idle && presented && has_text);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.open_audio), has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.play), has_record && (idle || ui.playback_state != 0));
    gtk_widget_set_sensitive(GTK_WIDGET(ui.stop_play), has_record && ui.playback_state != 0);
    gtk_button_set_label(ui.play, ui.playback_state == 1 ? "Pause" : "Play");
    /* Speaks the presented record's displayed text, so it needs both. */
    gboolean voices = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) > 0;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.button), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_read), idle && presented && has_text && voices);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), !ui.closing);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_sources), idle && voices);
    jsti_voice_credentials_set_idle(idle);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.voice_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_row),
        idle && read_aloud.favorite_indices != NULL && read_aloud.favorite_indices->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button),
        idle && read_aloud.favorite_executable && !read_aloud.favorite_pending);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.import_button), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_import), idle);
    gtk_widget_set_sensitive(ui.history_filters, idle);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_delete), idle && has_record);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.history_clear),
        idle && ui.all_history_ids != NULL && ui.all_history_ids[0] != '\0');
    if (ui.audio_cleanup != NULL) gtk_widget_set_sensitive(GTK_WIDGET(ui.audio_cleanup), idle);
    if (ui.recordings_choose != NULL) {
        gtk_widget_set_sensitive(GTK_WIDGET(ui.recordings_choose), idle && ui.location_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.recordings_default), idle && ui.location_chooser == NULL);
    }
    if (ui.backup_audio != NULL) {
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_audio), idle && ui.backup_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_profiles), idle && ui.backup_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_export), idle && ui.backup_chooser == NULL);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.backup_inspect), idle && ui.backup_chooser == NULL);
    }
    gtk_widget_set_sensitive(GTK_WIDGET(ui.model_row), idle);
    jsti_model_filters_set_idle(idle);
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

static void show_page(gint32 page);

/* A command from the status notifier's menu (LinuxTray.c). */
void jsti_window_tray_command(int command) {
    if (ui.window == NULL) return;
    switch (command) {
    case 1:
        if (ui.state == JSTI_STATE_WORKING) emit(JSTI_EVENT_CANCEL, "", 0);
        else emit(JSTI_EVENT_TOGGLE_RECORDING, selected_microphone(), selected_model_slot());
        break;
    case 3: show_page(JSTI_PAGE_GENERAL); gtk_window_present(ui.window); break;
    case 4: gtk_window_close(ui.window); break;
    default: gtk_window_present(ui.window); break;
    }
}

static void on_cancel(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    retire_cleanup_preview();
    emit(JSTI_EVENT_CANCEL, "", 0);
}

static void on_copy(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (cleanup_visible) return;
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
    if (!ui.suppress && slot >= 0) {
        guint mode = jsti_model_filters_local() ? 2 : (jsti_model_filters_live() ? 1 : 0);
        ui.preferred_model_slots[mode] = slot;
    }
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
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), method == 0 && ui.can_restore_clipboard);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), method == 0 && ui.app_switch_configured);
    refresh_setup();
    if (ui.app_switch_configured) {
        gchar *payload = g_strdup_printf("%s\t%u", restore ? "restore" : "",
                                        adw_combo_row_get_selected(ui.app_switch_row));
        emit(JSTI_EVENT_TEXT_OUTPUT, payload, (gint32)method);
        g_free(payload);
    } else {
        emit(JSTI_EVENT_TEXT_OUTPUT, restore ? "restore" : "", (gint32)method);
    }
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

/* Launch at login. The switch waits, insensitive, for the state the desktop
 * reached, which jsti_window_set_login_item reports. */
static void on_login_item(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.login_row), FALSE);
    emit(JSTI_EVENT_LOGIN_ITEM, "", adw_switch_row_get_active(ui.login_row) ? 1 : 0);
}

static void on_automation(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.automation_row), FALSE);
    emit(JSTI_EVENT_AUTOMATION, "", adw_switch_row_get_active(ui.automation_row) ? 1 : 0);
}

static void on_style(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    emit(JSTI_EVENT_SHORTCUT_STYLE, "", (gint32)adw_combo_row_get_selected(ui.style_row));
}

static guint polish_remote_boundary(void) {
    guint count = ui.polish_catalog != NULL ? ui.polish_catalog->len : 0;
    guint remote = polish_remote_count == G_MAXUINT
        ? (ui.polish_local_index >= 0 ? (guint)ui.polish_local_index : count) : polish_remote_count;
    return MIN(count, remote);
}

static gint32 polish_selected_model(void) {
    guint row = adw_combo_row_get_selected(ui.polish_model_row);
    return ui.polish_slots != NULL && row < ui.polish_slots->len
        ? g_array_index(ui.polish_slots, gint32, row) : -1;
}

static gchar *polish_prompt_text(void) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(ui.polish_prompt_row);
    GtkTextIter first, last;
    gtk_text_buffer_get_bounds(buffer, &first, &last);
    return gtk_text_buffer_get_text(buffer, &first, &last, FALSE);
}

static void polish_update_model_controls(void) {
    guint location = adw_combo_row_get_selected(ui.polish_location_row);
    gint32 selected = polish_selected_model();
    gboolean local = location == 0;
    gboolean available = selected >= 0 && ui.polish_catalog != NULL &&
        (guint)selected < ui.polish_catalog->len && ((guint)selected >= polish_remote_boundary()) == local;
    gboolean rules = available && selected == ui.polish_local_index;
    gboolean instructions = available && !rules && location <= 1;
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_location_row), location > 1
        ? "The stored model is unavailable. Choose Local or Remote and a supported model before applying."
        : !available ? (local ? "Choose a supported local model before applying."
        : "The remembered remote model is unavailable. Choose a supported remote model before applying.")
        : rules ? ui.polish_local_notice
        : local ? "Runs privately in process. A verified GGUF model and pinned native runtime are required; no cloud or rules fallback."
        : "When enabled, transcript text and custom instructions are sent to OpenRouter. Charges may apply.");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.polish_model_row), location <= 1);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.polish_prompt_row), instructions);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.polish_key_row), available && location == 1);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.polish_directives_row), instructions);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.polish_tags_row), instructions);
    gtk_widget_set_visible(GTK_WIDGET(ui.polish_key_row), location == 1);
    if (polish_local_group != NULL) gtk_widget_set_visible(polish_local_group, local);
    if (location != 1) gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "");
}

static void polish_select_location(gint32 desired, gboolean choose_first) {
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    guint location = adw_combo_row_get_selected(ui.polish_location_row);
    gboolean local = location == 0;
    guint count = g_list_model_get_n_items(G_LIST_MODEL(ui.polish_models));
    gtk_string_list_splice(ui.polish_models, 0, count, NULL);
    g_array_set_size(ui.polish_slots, 0);
    guint selected = GTK_INVALID_LIST_POSITION;
    if (location <= 1 && ui.polish_catalog != NULL) {
        for (guint index = 0; index < ui.polish_catalog->len; index++) {
            if ((index >= polish_remote_boundary()) != local) continue;
            gint32 slot = (gint32)index;
            g_array_append_val(ui.polish_slots, slot);
            gtk_string_list_append(ui.polish_models, g_ptr_array_index(ui.polish_catalog, index));
            if (slot == desired || (choose_first && selected == GTK_INVALID_LIST_POSITION)) {
                selected = ui.polish_slots->len - 1;
            }
        }
    }
    adw_combo_row_set_selected(ui.polish_model_row, selected);
    if (selected < ui.polish_slots->len) {
        gint32 full = g_array_index(ui.polish_slots, gint32, selected);
        if (local) ui.polish_local_selected = full;
        else ui.polish_remote_selected = full;
    }
    polish_update_model_controls();
    ui.suppress = suppressed;
}

static void on_polish_location(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (!ui.suppress) polish_select_location(adw_combo_row_get_selected(ui.polish_location_row) == 0
        ? ui.polish_local_selected : ui.polish_remote_selected, FALSE);
}

static void on_polish_model(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gint32 selected = polish_selected_model();
    if (selected >= 0) {
        if ((guint)selected >= polish_remote_boundary()) ui.polish_local_selected = selected;
        else ui.polish_remote_selected = selected;
    }
    polish_update_model_controls();
}

static void on_polish_apply(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    guint row = adw_combo_row_get_selected(ui.polish_model_row);
    guint location = adw_combo_row_get_selected(ui.polish_location_row);
    if (row >= ui.polish_slots->len || location > 1) {
        adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_location_row),
            "Choose Local or Remote and a supported post-processing model before applying.");
        return;
    }
    gint32 model = g_array_index(ui.polish_slots, gint32, row);
    if (model < 0 || ui.polish_catalog == NULL || (guint)model >= ui.polish_catalog->len ||
        (((guint)model >= polish_remote_boundary()) != (location == 0))) {
        adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_location_row),
            "Choose a supported model in the selected source before applying.");
        return;
    }
    gint32 index = adw_switch_row_get_active(ui.polish_row) ? model : -1 - model;
    gchar *raw_prompt = polish_prompt_text();
    if (strlen(raw_prompt) > 65535) {
        g_free(raw_prompt);
        jsti_window_update("Instructions must be at most 65535 UTF-8 bytes.", NULL, -1);
        return;
    }
    gchar *prompt = g_uri_escape_string(raw_prompt, NULL, TRUE);
    g_free(raw_prompt);
    gchar *key = g_uri_escape_string(location == 1
        ? gtk_editable_get_text(GTK_EDITABLE(ui.polish_key_row)) : "", NULL, TRUE);
    gchar *text = g_strdup_printf("%s\t%s\t%d\t%d", prompt, key,
        adw_switch_row_get_active(ui.polish_directives_row) ? 1 : 0,
        adw_switch_row_get_active(ui.polish_tags_row) ? 1 : 0);
    emit(JSTI_EVENT_POST_PROCESSING, text, index);
    g_free(text);
    g_free(prompt);
    g_free(key);
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
    retire_cleanup_preview();
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
    retire_cleanup_preview();
    ui.presented_variant = (gint32)selected;
    emit(JSTI_EVENT_TRANSCRIPT_VERSION, ui.selected_id, (gint32)selected);
}

static void on_retry(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_RETRY_HISTORY, ui.selected_id, 0);
}

static void on_correction_results(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL && g_strcmp0(ui.presented_id, ui.selected_id) == 0)
        emit(72, ui.selected_id, 2);
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
    if (ui.suppress) return;
    read_aloud.favorite_pending = TRUE;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), FALSE);
    if (!ui.suppress) jsti_voice_credentials_selection_pending();
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (read_aloud.picker_callback != NULL) {
        if (read_aloud.identifiers != NULL && position < read_aloud.identifiers->len) {
            const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
            if (*identifier != '\0') read_aloud.picker_callback(0, identifier,
                read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
        }
        return;
    }
    if (position != GTK_INVALID_LIST_POSITION) emit(JSTI_EVENT_VOICE_OUTPUT, "", (gint32)position);
}

static void on_favorite_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress || read_aloud.favorite_indices == NULL) return;
    guint position = adw_combo_row_get_selected(read_aloud.favorite_row);
    if (position < read_aloud.favorite_indices->len) {
        guint index = g_array_index(read_aloud.favorite_indices, guint, position);
        if (adw_combo_row_get_selected(read_aloud.voice_row) != index) {
            adw_combo_row_set_selected(read_aloud.voice_row, index);
        }
    }
}

static void on_favorite_toggle(GtkButton *button, gpointer data) {
    (void)data;
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (ui.suppress || read_aloud.picker_callback == NULL || read_aloud.identifiers == NULL ||
        position >= read_aloud.identifiers->len) return;
    const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
    if (*identifier == '\0') return;
    gint32 rank = g_array_index(read_aloud.favorite_ranks, gint32, position);
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    read_aloud.favorite_pending = TRUE;
    read_aloud.picker_callback(rank >= 0 ? 2 : 1, identifier,
        read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
}

static void on_open_audio(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.selected_id != NULL) emit(JSTI_EVENT_OPEN_AUDIO, ui.selected_id, 0);
}

static void on_recordings_folder(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_RECORDINGS_FOLDER, "", 0);
}

typedef struct LocationChoice {
    GWeakRef parent;
    GCancellable *cancelled;
} LocationChoice;

static void recordings_location_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    LocationChoice *choice = data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, &error);
    GObject *parent = g_weak_ref_get(&choice->parent);
    gboolean active = parent != NULL && parent == G_OBJECT(ui.window) && !ui.closing &&
        ui.location_chooser == choice->cancelled && !g_cancellable_is_cancelled(choice->cancelled);
    if (ui.location_chooser == choice->cancelled) g_clear_object(&ui.location_chooser);
    if (active) {
        if (file != NULL) {
            gchar *path = g_file_get_path(file);
            if (path != NULL) emit(JSTI_EVENT_RECORDINGS_LOCATION, path, 0);
            else jsti_window_update("Choose a local folder. This portal did not provide a local path.", NULL, -1);
            g_free(path);
        } else if (error != NULL && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED)) {
            gchar *message = g_strdup_printf("Could not choose a recordings folder: %s", error->message);
            jsti_window_update(message, NULL, -1);
            g_free(message);
        }
        refresh_actions();
    }
    g_clear_error(&error);
    g_clear_object(&file);
    g_clear_object(&parent);
    g_weak_ref_clear(&choice->parent);
    g_object_unref(choice->cancelled);
    g_free(choice);
}

static void on_recordings_choose(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.closing || ui.state != 0 || ui.location_chooser != NULL) return;
    LocationChoice *choice = g_new0(LocationChoice, 1);
    g_weak_ref_init(&choice->parent, G_OBJECT(ui.window));
    choice->cancelled = g_cancellable_new();
    ui.location_chooser = g_object_ref(choice->cancelled);
    refresh_actions();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose where new recordings are saved (existing audio is not moved)");
    gtk_file_dialog_select_folder(dialog, ui.window, choice->cancelled, recordings_location_chosen, choice);
    g_object_unref(dialog);
}

static void on_recordings_default(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.closing || ui.state != 0 || ui.location_chooser != NULL) return;
    emit(JSTI_EVENT_RECORDINGS_LOCATION, "", 0);
}

static void on_audio_cleanup(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_AUDIO_CLEANUP, "", 0);
}

typedef struct BackupChoice {
    GWeakRef parent;
    GCancellable *cancelled;
    gint32 include_audio;
    gint32 include_profiles;
    gboolean inspect;
} BackupChoice;

static gboolean backup_choice_active(const BackupChoice *choice, GObject *parent) {
    return parent != NULL && parent == G_OBJECT(ui.window) && !ui.closing &&
        ui.backup_chooser == choice->cancelled && !g_cancellable_is_cancelled(choice->cancelled);
}

static void backup_emit_path(const BackupChoice *choice, const char *path) {
    emit(choice->inspect ? JSTI_EVENT_MIGRATION_INSPECT : JSTI_EVENT_MIGRATION_EXPORT,
         path, choice->inspect ? 0 : (choice->include_audio | choice->include_profiles));
}

static void backup_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    BackupChoice *choice = data;
    GError *error = NULL;
    GFile *file = choice->inspect ? gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error)
                                : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    GObject *parent = g_weak_ref_get(&choice->parent);
    gboolean active = backup_choice_active(choice, parent);
    if (ui.backup_chooser == choice->cancelled) g_clear_object(&ui.backup_chooser);
    if (active) {
        if (file != NULL) {
            gchar *path = g_file_get_path(file);
            if (path != NULL) backup_emit_path(choice, path);
            else jsti_window_update("Choose a local ZIP file. This portal did not provide a local path.", NULL, -1);
            g_free(path);
        } else if (error == NULL) {
            jsti_window_update("The backup picker returned no file or error. Choose a local ZIP path.",
                               NULL, -1);
        } else if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
                   !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED)) {
            gchar *message = g_strdup_printf("Could not choose backup file: %s", error->message);
            jsti_window_update(message, NULL, -1);
            g_free(message);
        }
        refresh_actions();
    }
    g_clear_error(&error);
    g_clear_object(&file);
    g_clear_object(&parent);
    g_weak_ref_clear(&choice->parent);
    g_object_unref(choice->cancelled);
    g_free(choice);
}

static void on_backup(GtkButton *button, gpointer data) {
    (void)button;
    if (ui.closing || ui.state != 0 || ui.backup_chooser != NULL) return;
    BackupChoice *choice = g_new0(BackupChoice, 1);
    g_weak_ref_init(&choice->parent, G_OBJECT(ui.window));
    choice->cancelled = g_cancellable_new();
    choice->include_audio = adw_switch_row_get_active(ui.backup_audio) ? 1 : 0;
    choice->include_profiles = adw_switch_row_get_active(ui.backup_profiles) ? 2 : 0;
    choice->inspect = GPOINTER_TO_INT(data) != 0;
    ui.backup_chooser = g_object_ref(choice->cancelled);
    refresh_actions();
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, choice->inspect ? "Inspect backup (no data will be imported)"
                                                    : "Save ZIP backup (existing files are never replaced)");
    if (!choice->inspect) gtk_file_dialog_set_initial_name(dialog, "JustSpeakToIt-History.zip");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "ZIP backups");
    gtk_file_filter_add_pattern(filter, "*.zip");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_set_default_filter(dialog, filter);
    if (choice->inspect) gtk_file_dialog_open(dialog, ui.window, choice->cancelled, backup_chosen, choice);
    else gtk_file_dialog_save(dialog, ui.window, choice->cancelled, backup_chosen, choice);
    g_object_unref(filters);
    g_object_unref(filter);
    g_object_unref(dialog);
}

static void audio_cleanup_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    const char *token = g_object_get_data(G_OBJECT(dialog), "jsti-audio-cleanup-token");
    emit(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE, token, g_strcmp0(response, "delete") == 0 ? 1 : 0);
    gtk_window_destroy(GTK_WINDOW(dialog));
}

static GtkWidget *audio_cleanup_dialog(const char *token, size_t count) {
    gchar *body = g_strdup_printf(
        "Permanently delete %zu saved audio file(s), including audio kept after deleting History entries? "
        "History entries and transcripts will be kept. Recordings saved after this confirmation "
        "will not be deleted. This cannot be undone.", count);
    GtkWidget *dialog = adw_message_dialog_new(ui.window, "Delete saved recordings?", body);
    g_free(body);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    g_object_set_data_full(G_OBJECT(dialog), "jsti-audio-cleanup-token", g_strdup(token), g_free);
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete audio", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    g_signal_connect(dialog, "response", G_CALLBACK(audio_cleanup_response), NULL);
    return dialog;
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
    retire_cleanup_preview();
    jsti_troubleshooting_close();
    jsti_api_keys_close();
    jsti_permissions_close();
    jsti_voice_sources_close();
    jsti_voice_credentials_close();
    jsti_action_shortcut_editor_close();
    ui.closing = TRUE;
    if (ui.backup_chooser != NULL) g_cancellable_cancel(ui.backup_chooser);
    g_clear_object(&ui.backup_chooser);
    if (ui.location_chooser != NULL) g_cancellable_cancel(ui.location_chooser);
    g_clear_object(&ui.location_chooser);
    jsti_hud_destroy();
    jsti_tray_stop();
    emit(JSTI_EVENT_CLOSING, "", 0);
    close_posts();
    if (ui.model_catalog != NULL) { models_free(ui.model_catalog); ui.model_catalog = NULL; }
    g_clear_pointer(&ui.all_history_ids, g_free);
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
    [JSTI_PAGE_CORRECTIONS] = { "corrections", "Corrections", "document-edit-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_PRONUNCIATION] = { "pronunciation", "Pronunciation", "accessories-dictionary-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_PROFILES] = { "profiles", "Profiles", "system-users-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_KEYBOARD] = { "keyboard", "Keyboard", "input-keyboard-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_CLOUD_SYNC] = { "icloud-sync", "iCloud Sync", "emblem-synchronizing-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_ABOUT] = { "about", "About", "help-about-symbolic", "jsti-tint-warm" },
};

static struct {
    gint digits[JSTI_PAGE_COUNT];
    GtkWidget *hints[JSTI_PAGE_COUNT];
    gboolean configured;
} sidebar_shortcuts;

static void show_page(gint32 page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return;
    if (ui.page != page) retire_cleanup_preview();
    ui.page = page;
    if (page == JSTI_PAGE_CORRECTIONS || page == JSTI_PAGE_PRONUNCIATION)
        emit(71, "", page == JSTI_PAGE_CORRECTIONS ? 0 : 1);
    if (page == JSTI_PAGE_PROFILES) emit(JSTI_EVENT_PROFILES, "refresh", 0);
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

static gboolean sidebar_navigate(guint keyval, GdkModifierType modifiers, GtkWidget *focused) {
    GdkModifierType relevant = modifiers & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK |
                                            GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    if (relevant != GDK_CONTROL_MASK || keyval < GDK_KEY_0 || keyval > GDK_KEY_9 ||
        !sidebar_shortcuts.configured || !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    for (GtkWidget *focus = focused; focus != NULL; focus = gtk_widget_get_parent(focus)) {
        if (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus) || GTK_IS_DROP_DOWN(focus)) return FALSE;
    }
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, page));
        if (sidebar_shortcuts.digits[page] == (gint)(keyval - GDK_KEY_0) &&
            gtk_widget_is_sensitive(row) && gtk_widget_get_visible(row)) {
            show_page(page);
            return TRUE;
        }
    }
    return FALSE;
}

static gboolean action_shortcut_run(gint run, const char *page, gint slot);

static gboolean sidebar_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                    GdkModifierType modifiers, gpointer data) {
    (void)data;
    GtkWidget *focused = gtk_window_get_focus(ui.window);
    if (sidebar_navigate(keyval, modifiers, focused)) return TRUE;
    if (ui.closing || !gtk_window_is_active(ui.window) ||
        !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    return jsti_action_shortcuts_key(controller, keyval, keycode, modifiers, focused, action_shortcut_run);
}

static void action_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)keyval; (void)modifiers; (void)data;
    jsti_action_shortcuts_release(keycode);
}

static void action_window_active(GObject *object, GParamSpec *spec, gpointer data) {
    (void)spec; (void)data;
    if (!gtk_window_is_active(GTK_WINDOW(object))) jsti_action_shortcuts_reset();
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
        gtk_widget_set_hexpand(label, TRUE);
        gtk_box_append(GTK_BOX(line), label);
        GtkWidget *hint = gtk_label_new("");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_accessible_update_state(GTK_ACCESSIBLE(hint), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
        sidebar_shortcuts.hints[page] = hint;
        gtk_widget_set_visible(hint, FALSE);
        gtk_box_append(GTK_BOX(line), hint);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, page_info[page].title, -1);
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

static void history_delete_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)data;
    const char *identifiers = g_object_get_data(G_OBJECT(dialog), "jsti-history-delete-ids");
    if (g_strcmp0(response, "keep-audio") == 0 || g_strcmp0(response, "delete-audio") == 0) {
        emit(JSTI_EVENT_HISTORY_DELETE, identifiers, g_strcmp0(response, "delete-audio") == 0 ? 1 : 0);
    }
    gtk_window_destroy(GTK_WINDOW(dialog));
}

static GtkWidget *history_delete_dialog(const char *identifiers, gboolean clear) {
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
    gboolean clear = button == ui.history_clear;
    const char *identifiers = clear ? ui.all_history_ids : ui.selected_id;
    if (ui.state != 0 || identifiers == NULL || identifiers[0] == '\0') return;
    gtk_window_present(GTK_WINDOW(history_delete_dialog(identifiers, clear)));
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
    ui.history_clear = GTK_BUTTON(gtk_button_new_with_label("Clear History…"));
    g_signal_connect(ui.history_clear, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_prepend(GTK_BOX(trailing), GTK_WIDGET(ui.history_clear));
    ui.history_filters = jsti_history_filters_button_new();
    gtk_box_prepend(GTK_BOX(trailing), ui.history_filters);
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
    GtkWidget *management = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(management, GTK_ALIGN_END);
    ui.correction_results = GTK_BUTTON(gtk_button_new_with_label("Correction results"));
    g_signal_connect(ui.correction_results, "clicked", G_CALLBACK(on_correction_results), NULL);
    ui.history_delete = GTK_BUTTON(gtk_button_new_with_label("Delete…"));
    g_signal_connect(ui.history_delete, "clicked", G_CALLBACK(on_history_delete), NULL);
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(ui.correction_results));
    gtk_box_append(GTK_BOX(management), GTK_WIDGET(ui.history_delete));
    gtk_box_append(GTK_BOX(ui.detail), management);
    return page;
}

static void on_voice_sources(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gboolean presented = ui.selected_id != NULL && g_strcmp0(ui.presented_id, ui.selected_id) == 0;
    gchar *snapshot = presented ? displayed_transcript() : g_strdup("");
    jsti_show_voice_sources(ui.window, presented ? ui.selected_id : "", snapshot);
    g_free(snapshot);
}

static GtkWidget *build_voice_output(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), jsti_hero_new(
        "voice", "Voice Output",
        "Read History, typed text, clipboard snapshots or imported text with your selected voice. "
        "Export lossless WAV audio.", NULL,
        NULL));
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("audio-speakers-symbolic", "Read aloud", &body);
    gtk_box_append(GTK_BOX(body), read_aloud_group());
    gtk_box_append(GTK_BOX(body), jsti_voice_credentials_group_new());
    GtkWidget *note = gtk_label_new(
        "Choose a recording in History, or open Text and export for typed/pasted text and an explicit clipboard "
        "snapshot. For external selected text, allow session access below and use a desktop shortcut after "
        "refocusing the external field. Recording, another playback or Stop ends voice output.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_box_append(GTK_BOX(body), note);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    ui.voice_stop = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(ui.voice_stop, "clicked", G_CALLBACK(on_stop_play), NULL);
    ui.voice_read = GTK_BUTTON(gtk_button_new_with_label("Read Selected Recording"));
    ui.voice_sources = GTK_BUTTON(gtk_button_new_with_label("Text and export..."));
    g_signal_connect(ui.voice_sources, "clicked", G_CALLBACK(on_voice_sources), NULL);
    gtk_widget_add_css_class(GTK_WIDGET(ui.voice_read), "suggested-action");
    g_signal_connect(ui.voice_read, "clicked", G_CALLBACK(on_read_aloud), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_stop));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_sources));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(ui.voice_read));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), card);
    gtk_box_append(GTK_BOX(column), jsti_selection_access_group_new());
    return page;
}

static GtkWidget *build_general(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[0] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "General", "Choose the microphone, where finished text goes, whether the app starts at login, and how "
        "it looks."));
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
    ui.output_group = ADW_PREFERENCES_GROUP(output);
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(output),
        "Checking paste and clipboard support for this desktop.");
    const char *methods[] = { "Paste into the focused app", "Copy to the clipboard only", NULL };
    ui.output_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.output_row), "Text output");
    adw_combo_row_set_model(ui.output_row, G_LIST_MODEL(gtk_string_list_new(methods)));
    g_signal_connect(ui.output_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.output_row));
    ui.restore_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.restore_row), "Restore the clipboard after pasting");
    adw_switch_row_set_active(ui.restore_row, TRUE);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.restore_row),
                               "Previous text only, while Just Speak to It still owns the X11 selection.");
    gtk_widget_set_visible(GTK_WIDGET(ui.restore_row), FALSE);
    g_signal_connect(ui.restore_row, "notify::active", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.restore_row));
    ui.app_switch_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.app_switch_row), "App-switch delivery");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), FALSE);
    g_signal_connect(ui.app_switch_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.app_switch_row));
    ui.app_switch_help = GTK_LABEL(gtk_label_new(NULL));
    gtk_label_set_wrap(ui.app_switch_help, TRUE);
    gtk_label_set_xalign(ui.app_switch_help, 0);
    gtk_widget_set_margin_top(GTK_WIDGET(ui.app_switch_help), 8);
    gtk_widget_set_margin_bottom(GTK_WIDGET(ui.app_switch_help), 8);
    gtk_widget_set_margin_start(GTK_WIDGET(ui.app_switch_help), 12);
    gtk_widget_set_margin_end(GTK_WIDGET(ui.app_switch_help), 12);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(ui.app_switch_help));
    gtk_box_append(GTK_BOX(column), output);
    gtk_box_append(GTK_BOX(column), jsti_api_keys_group_new(ui.window));

    GtkWidget *startup = group("Startup");
    ui.login_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.login_row), "Launch at login");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.login_row), "Checking the desktop's startup settings…");
    gtk_widget_set_sensitive(GTK_WIDGET(ui.login_row), FALSE);
    g_signal_connect(ui.login_row, "notify::active", G_CALLBACK(on_login_item), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(startup), GTK_WIDGET(ui.login_row));
    gtk_box_append(GTK_BOX(column), startup);

    GtkWidget *automation = group("Automation");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(automation),
        "The speak command uses a private, same-user local socket. Off by default. "
        "Imported preferences cannot grant access on this computer.");
    ui.automation_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.automation_row), "Allow local automation");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.automation_row), "Automation is off.");
    g_signal_connect(ui.automation_row, "notify::active", G_CALLBACK(on_automation), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(automation), GTK_WIDGET(ui.automation_row));
    gtk_box_append(GTK_BOX(column), automation);

    GtkWidget *appearance = group("Appearance");
    const char *schemes[] = { "Follow the system", "Light", "Dark", NULL };
    ui.appearance_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.appearance_row), "Theme");
    adw_combo_row_set_model(ui.appearance_row, G_LIST_MODEL(gtk_string_list_new(schemes)));
    g_signal_connect(ui.appearance_row, "notify::selected", G_CALLBACK(on_appearance), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(appearance), GTK_WIDGET(ui.appearance_row));
    gtk_box_append(GTK_BOX(column), appearance);
    GtkWidget *housekeeping = group("Housekeeping");
    GtkWidget *folder = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(folder), "Recording storage");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(folder), "Open the folder containing saved audio and History data.");
    ui.recordings_folder = GTK_BUTTON(gtk_button_new_with_mnemonic("_Open folder"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_folder), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_folder, "clicked", G_CALLBACK(on_recordings_folder), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(folder), GTK_WIDGET(ui.recordings_folder));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), folder);
    GtkWidget *location = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(location), "New recordings folder");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(location),
        "Save new audio in a local folder you choose. Existing recordings are never moved or deleted.");
    ui.recordings_choose = GTK_BUTTON(gtk_button_new_with_mnemonic("_Choose…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_choose), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_choose, "clicked", G_CALLBACK(on_recordings_choose), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(ui.recordings_choose));
    ui.recordings_default = GTK_BUTTON(gtk_button_new_with_mnemonic("Use _default"));
    gtk_widget_set_valign(GTK_WIDGET(ui.recordings_default), GTK_ALIGN_CENTER);
    g_signal_connect(ui.recordings_default, "clicked", G_CALLBACK(on_recordings_default), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(location), GTK_WIDGET(ui.recordings_default));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), location);
    GtkWidget *cleanup = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cleanup), "Saved recordings");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(cleanup), "Delete saved audio without removing History entries.");
    ui.audio_cleanup = GTK_BUTTON(gtk_button_new_with_mnemonic("Delete _audio…"));
    gtk_widget_add_css_class(GTK_WIDGET(ui.audio_cleanup), "destructive-action");
    gtk_widget_set_valign(GTK_WIDGET(ui.audio_cleanup), GTK_ALIGN_CENTER);
    g_signal_connect(ui.audio_cleanup, "clicked", G_CALLBACK(on_audio_cleanup), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(cleanup), GTK_WIDGET(ui.audio_cleanup));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(housekeeping), cleanup);
    gtk_box_append(GTK_BOX(column), housekeeping);
    GtkWidget *backup = group("Data backup");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(backup),
        "Save History text with optional saved audio and app profiles in a ZIP backup. "
        "ZIPs are not encrypted. Settings and credentials are not included; existing files are never replaced.");
    ui.backup_audio = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.backup_audio), "Include saved recording audio");
    adw_switch_row_set_active(ui.backup_audio, TRUE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(ui.backup_audio));
    ui.backup_profiles = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.backup_profiles), "Include app profiles");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.backup_profiles), "Includes per-app overrides and prompts.");
    adw_switch_row_set_active(ui.backup_profiles, FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), GTK_WIDGET(ui.backup_profiles));
    GtkWidget *backup_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(backup_row), "Save a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(backup_row),
        "Turn off both optional categories for a History-only backup.");
    ui.backup_export = GTK_BUTTON(gtk_button_new_with_mnemonic("Save _backup…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.backup_export), GTK_ALIGN_CENTER);
    g_signal_connect(ui.backup_export, "clicked", G_CALLBACK(on_backup), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(backup_row), GTK_WIDGET(ui.backup_export));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), backup_row);
    GtkWidget *inspect_row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(inspect_row), "Inspect a ZIP backup");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(inspect_row),
        "Review categories and archive notices without importing any data.");
    ui.backup_inspect = GTK_BUTTON(gtk_button_new_with_mnemonic("_Inspect…"));
    gtk_widget_set_valign(GTK_WIDGET(ui.backup_inspect), GTK_ALIGN_CENTER);
    g_signal_connect(ui.backup_inspect, "clicked", G_CALLBACK(on_backup), GINT_TO_POINTER(1));
    adw_action_row_add_suffix(ADW_ACTION_ROW(inspect_row), GTK_WIDGET(ui.backup_inspect));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(backup), inspect_row);
    gtk_box_append(GTK_BOX(column), backup);
    return page;
}

static void open_comparison(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.state == JSTI_STATE_IDLE) jsti_comparison_open(ui.window);
}

static GtkWidget *build_transcription(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[1] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Transcription", "Pick the speech model for new recordings, on this computer or with your own provider key."));
    GtkWidget *models = group("Model");
    jsti_model_filters_add(models, on_model_filter);
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
    GtkWidget *comparison = group("Compare Models");
    GtkWidget *compare = gtk_button_new_with_label("Compare Models…");
    g_signal_connect(compare, "clicked", G_CALLBACK(open_comparison), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(comparison), compare);
    gtk_box_append(GTK_BOX(column), comparison);
    return page;
}

static GtkWidget *build_post_processing(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[2] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Post-processing", "Clean up transcripts locally or through OpenRouter. The original is always kept."));
    GtkWidget *polish = group("Clean-up");
    ui.polish_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_row), "Enable post-processing");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_row));
    ui.polish_location_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_location_row), "Model source");
    const char *locations[] = {"Local", "Remote", NULL};
    GtkStringList *location_names = gtk_string_list_new(locations);
    adw_combo_row_set_model(ui.polish_location_row, G_LIST_MODEL(location_names));
    g_object_unref(location_names);
    adw_combo_row_set_selected(ui.polish_location_row, GTK_INVALID_LIST_POSITION);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_location_row));
    AdwActionRow *mode = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(mode), "Finished-transcript cleanup");
    adw_action_row_set_subtitle(mode,
        "Remote cleanup can stream previews when enabled in preferences. Local cleanup completes in one step.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(mode));
    ui.polish_models = gtk_string_list_new(NULL);
    ui.polish_slots = g_array_new(FALSE, FALSE, sizeof(gint32));
    ui.polish_local_index = -1;
    ui.polish_remote_selected = -1;
    ui.polish_local_selected = -1;
    ui.polish_model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_model_row), "Polishing model");
    adw_combo_row_set_model(ui.polish_model_row, G_LIST_MODEL(ui.polish_models));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_model_row));
    ui.polish_directives_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_directives_row), "Include personal lexicon directives");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_directives_row),
        "Use saved spelling and name instructions with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_directives_row));
    ui.polish_tags_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_tags_row), "Include lexicon context tags");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.polish_tags_row),
        "Use saved context tags with downloaded or remote language models.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_tags_row));
    GtkWidget *prompt_label = gtk_label_new("Custom system instructions (optional)");
    gtk_label_set_xalign(GTK_LABEL(prompt_label), 0);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_label);
    ui.polish_prompt_row = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(ui.polish_prompt_row, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_top_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_bottom_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_left_margin(ui.polish_prompt_row, 10);
    gtk_text_view_set_right_margin(ui.polish_prompt_row, 10);
    gtk_accessible_update_property(GTK_ACCESSIBLE(ui.polish_prompt_row),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Custom system instructions", -1);
    GtkWidget *prompt_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(prompt_scroll), 140);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(prompt_scroll), GTK_WIDGET(ui.polish_prompt_row));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), prompt_scroll);
    ui.polish_key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.polish_key_row), "New OpenRouter key (leave empty to keep)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), GTK_WIDGET(ui.polish_key_row));
    g_signal_connect(ui.polish_location_row, "notify::selected", G_CALLBACK(on_polish_location), NULL);
    g_signal_connect(ui.polish_model_row, "notify::selected", G_CALLBACK(on_polish_model), NULL);
    GtkWidget *polish_apply = gtk_button_new_with_label("Apply");
    gtk_widget_add_css_class(polish_apply, "suggested-action");
    gtk_widget_set_halign(polish_apply, GTK_ALIGN_END);
    gtk_widget_set_margin_top(polish_apply, 8);
    g_signal_connect(polish_apply, "clicked", G_CALLBACK(on_polish_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(polish), polish_apply);
    gtk_box_append(GTK_BOX(column), polish);
    polish_local_group = jsti_local_cleanup_group_new();
    gtk_widget_set_visible(polish_local_group, FALSE);
    gtk_box_append(GTK_BOX(column), polish_local_group);
    return page;
}

static GtkWidget *build_keyboard(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[3] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Keyboard", "Start and stop dictation from anywhere with a global shortcut."));
    GtkWidget *shortcut = group("Shortcut");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(shortcut),
        "Where the desktop offers no shortcut portal, bind the command justspeaktoit --toggle to a key in your "
        "desktop's keyboard settings. With the app already running, --speak-clipboard reads clipboard text aloud "
        "and --paste-last-history delivers the newest History text without raising this window. "
        "The running app also accepts --stop-speech, --pause-resume-speech and --quick-voice-1 "
        "(or --quick-voice-2 / --quick-voice-3).");
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
    gtk_box_append(GTK_BOX(column), jsti_action_shortcuts_group_new(ui.window));
    return page;
}

static GtkWidget *build_cloud_sync(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "iCloud Sync", "Keep History in step with your Mac, through your own iCloud account."));
    gtk_box_append(GTK_BOX(column), jsti_cloud_sync_group_new());
    return page;
}

static void open_link_finished(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        g_warning("Could not open the browser: %s", error->message);
        if (ui.window != NULL && !ui.closing) {
            gtk_label_set_text(ui.status, "Could not open your browser. Check your default browser settings.");
        }
        g_error_free(error);
    }
}

static void open_link(GtkButton *button, gpointer data) {
    (void)button;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(data);
    gtk_uri_launcher_launch(launcher, ui.window, NULL, open_link_finished, NULL);
    g_object_unref(launcher);
}

static GtkWidget *link_button(const char *label, const char *uri) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_object_set_data_full(G_OBJECT(button), "about-uri", g_strdup(uri), g_free);
    gtk_widget_set_tooltip_text(button, uri);
    g_signal_connect(button, "clicked", G_CALLBACK(open_link), g_object_get_data(G_OBJECT(button), "about-uri"));
    return button;
}

static void on_troubleshooting(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_troubleshooting_open(ui.window);
}

static void on_permissions(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_permissions_open(ui.window);
}

static void request_permissions(gpointer data) {
    (void)data;
    if (!ui.closing) jsti_permissions_open(ui.window);
}

int32_t jsti_window_request_permissions(void) { return jsti_window_post(request_permissions, NULL, NULL); }

static void request_api_keys(gpointer data) {
    (void)data;
    if (!ui.closing && ui.state == JSTI_STATE_IDLE) jsti_api_keys_open(ui.window);
    else (void)jsti_window_update("Finish the current operation before opening API Keys.", NULL, -1);
}

int32_t jsti_window_request_api_keys(void) { return jsti_window_post(request_api_keys, NULL, NULL); }

static gboolean action_shortcut_run(gint run, const char *page, gint slot) {
    if (ui.closing || !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    switch (run) {
    case 1:
        if (!gtk_widget_is_sensitive(GTK_WIDGET(ui.record))) return FALSE;
        on_record(NULL, NULL);
        return TRUE;
    case 2:
        for (gint index = 0; page != NULL && index < JSTI_PAGE_COUNT; ++index) {
            GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, index));
            if (g_strcmp0(page_info[index].name, page) != 0) continue;
            if (!gtk_widget_is_sensitive(row) || !gtk_widget_get_visible(row)) return FALSE;
            show_page(index);
            return TRUE;
        }
        return FALSE;
    case 3:
        if (!gtk_widget_is_sensitive(GTK_WIDGET(ui.voice_stop))) return FALSE;
        on_stop_play(NULL, NULL);
        return TRUE;
    case 4: on_troubleshooting(NULL, NULL); return TRUE;
    case 5:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        open_comparison(NULL, NULL);
        return TRUE;
    case 6:
        if (ui.state != JSTI_STATE_IDLE || slot < 1 || slot > 3) return FALSE;
        emit(JSTI_EVENT_QUICK_VOICE, "", slot);
        return TRUE;
    case 7:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_CLIPBOARD, "", 0);
        return TRUE;
    case 8:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEECH_PAUSE, "", 0);
        return TRUE;
    case 9:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_API_KEYS, "", 0);
        return TRUE;
    case 10:
        emit(JSTI_EVENT_PERMISSIONS, "", 0);
        return TRUE;
    case 11:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_PASTE_LAST_HISTORY, "", 0);
        return TRUE;
    case 12:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_SELECTED_TEXT, "", 0);
        return TRUE;
    default: return FALSE;
    }
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
    ui.about_details = GTK_LABEL(gtk_label_new("Build metadata has not been supplied by this host."));
    gtk_label_set_xalign(ui.about_details, 0);
    gtk_label_set_selectable(ui.about_details, TRUE);
    gtk_label_set_wrap(ui.about_details, TRUE);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(ui.about_details));
    ui.about_links = GTK_FLOW_BOX(gtk_flow_box_new());
    gtk_flow_box_set_selection_mode(ui.about_links, GTK_SELECTION_NONE);
    gtk_flow_box_set_min_children_per_line(ui.about_links, 1);
    gtk_flow_box_set_max_children_per_line(ui.about_links, 3);
    gtk_flow_box_set_row_spacing(ui.about_links, 8);
    gtk_flow_box_set_column_spacing(ui.about_links, 8);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(ui.about_links));
    GtkWidget *troubleshooting = gtk_button_new_with_mnemonic("_Troubleshooting");
    gtk_widget_set_halign(troubleshooting, GTK_ALIGN_START);
    g_signal_connect(troubleshooting, "clicked", G_CALLBACK(on_troubleshooting), NULL);
    gtk_box_append(GTK_BOX(body), troubleshooting);
    GtkWidget *permissions = gtk_button_new_with_mnemonic("_Permissions");
    gtk_widget_set_size_request(permissions, -1, 44);
    gtk_widget_set_halign(permissions, GTK_ALIGN_START);
    g_signal_connect(permissions, "clicked", G_CALLBACK(on_permissions), NULL);
    gtk_box_append(GTK_BOX(body), permissions);
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
    GtkEventController *navigation_keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(navigation_keys, GTK_PHASE_BUBBLE);
    g_signal_connect(navigation_keys, "key-pressed", G_CALLBACK(sidebar_key_pressed), NULL);
    gtk_widget_add_controller(window, navigation_keys);
    GtkEventController *releases = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(releases, GTK_PHASE_CAPTURE);
    g_signal_connect(releases, "key-released", G_CALLBACK(action_key_released), NULL);
    gtk_widget_add_controller(window, releases);
    g_signal_connect(window, "notify::is-active", G_CALLBACK(action_window_active), NULL);

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
    add_page(JSTI_PAGE_CORRECTIONS, jsti_vocabulary_page_new(0));
    ui.configuration_columns[4] = jsti_vocabulary_learning_preferences();
    add_page(JSTI_PAGE_PRONUNCIATION, jsti_vocabulary_page_new(1));
    add_page(JSTI_PAGE_PROFILES, jsti_profiles_page_new());
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
    jsti_app_icon_install();
    build_window();
    gtk_window_set_icon_name(ui.window, "com.justspeaktoit.JustSpeakToIt");
    jsti_hands_free_guard_start();
    jsti_tray_start();
    ui.suppress = TRUE;
    apply_models(initial_models.rows, initial_models.count, initial_models.selected);
    ui.suppress = FALSE;
    open_posts();
    if (ui.start_minimized) {
        /* Minimised before it is first shown, and shown without the focus
         * request present() makes, so nothing is taken from the login session. */
        gtk_window_minimize(ui.window);
        gtk_widget_set_visible(GTK_WIDGET(ui.window), TRUE);
    } else {
        gtk_window_present(ui.window);
    }
    if (!ui.ready_sent) {
        ui.ready_sent = TRUE;
        /* The smoke test inspects and captures a laid-out, drawn window. */
        if (ui.flags & JSTI_WINDOW_SMOKE_TEST) g_timeout_add(750, emit_ready, NULL);
        else emit(JSTI_EVENT_READY, "", 0);
    }
}

typedef struct WindowCommand {
    gint run, slot;
    gboolean background, unknown_argument;
} WindowCommand;

static gboolean parse_window_command(gint argc, const gchar *const *argv, WindowCommand *command) {
    const struct { const gchar *argument; gint run, slot; } actions[] = {
        { JSTI_TOGGLE_ARGUMENT, 1, 0 }, { JSTI_SPEAK_CLIPBOARD_ARGUMENT, 7, 0 },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, 11, 0 },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, 12, 0 },
        { JSTI_STOP_SPEECH_ARGUMENT, 3, 0 }, { JSTI_PAUSE_SPEECH_ARGUMENT, 8, 0 },
        { JSTI_QUICK_VOICE_1_ARGUMENT, 6, 1 }, { JSTI_QUICK_VOICE_2_ARGUMENT, 6, 2 },
        { JSTI_QUICK_VOICE_3_ARGUMENT, 6, 3 }
    };
    *command = (WindowCommand){ 0 };
    for (gint index = 1; index < argc; ++index) {
        gboolean known = g_strcmp0(argv[index], JSTI_LOGIN_LAUNCH_ARGUMENT) == 0;
        if (known) command->background = TRUE;
        for (guint action = 0; action < G_N_ELEMENTS(actions); ++action) {
            if (g_strcmp0(argv[index], actions[action].argument) != 0) continue;
            known = TRUE;
            if (command->run != 0 &&
                (command->run != actions[action].run || command->slot != actions[action].slot)) return FALSE;
            command->run = actions[action].run;
            command->slot = actions[action].slot;
        }
        if (!known) command->unknown_argument = TRUE;
    }
    return TRUE;
}

static gboolean is_forwardable_command(gint run, gint slot) {
    if (run == 6) return slot >= 1 && slot <= 3;
    return slot == 0 && (run == 3 || run == 7 || run == 8 || run == 11 || run == 12);
}

static gboolean parse_action_command(int argc, const gchar *const *argv, WindowCommand *command) {
    return argc >= 1 && argv != NULL && parse_window_command(argc, argv, command) &&
        command->run != 0 && !command->unknown_argument;
}

int32_t jsti_window_validate_action_command(int argc, char **argv, char *error, size_t capacity) {
    WindowCommand command;
    if (!parse_action_command(argc, (const gchar *const *)argv, &command)) {
        jsti_set_error(error, capacity, "Choose exactly one supported desktop action command.");
        return -1;
    }
    return 0;
}

/* 0 means admitted, not completed; 2 requires the running app, 3 means unavailable now. */
static gint forward_window_command(gint run, gint slot, gboolean remote) {
    if (!remote || ui.window == NULL) return 2;
    if (!is_forwardable_command(run, slot)) return 3;
    return action_shortcut_run(run, "", slot) ? 0 : 3;
}

static int reject_local_action(GApplication *application, GApplicationCommandLine *line, gpointer data) {
    (void)application; (void)data;
    g_application_command_line_printerr(line, "Open JustSpeakToIt before using this action command.\n");
    return 2;
}

int32_t jsti_window_forward_action(const char *app_id, int argc, char **argv, char *error, size_t capacity) {
    WindowCommand command;
    if (app_id == NULL || !g_application_id_is_valid(app_id) ||
        !parse_action_command(argc, (const gchar *const *)argv, &command) ||
        !is_forwardable_command(command.run, command.slot)) {
        jsti_set_error(error, capacity, "Choose exactly one supported desktop action command.");
        return -1;
    }
    GApplication *client = g_application_new(app_id, G_APPLICATION_HANDLES_COMMAND_LINE);
    g_signal_connect(client, "command-line", G_CALLBACK(reject_local_action), NULL);
    gint status = g_application_run(client, argc, argv);
    g_object_unref(client);
    if (status != 0) {
        jsti_set_error(error, capacity, "The desktop action was refused (status %d).", status);
        return -1;
    }
    return 0;
}

static int on_command_line(GApplication *application, GApplicationCommandLine *line, gpointer data) {
    (void)data;
    gint argc = 0;
    gchar **argv = g_application_command_line_get_arguments(line, &argc);
    WindowCommand command;
    gboolean parsed = parse_window_command(argc, (const gchar *const *)argv, &command);
    g_strfreev(argv);
    if (!parsed) {
        g_application_command_line_printerr(line, "Choose only one action command per invocation.\n");
        return 2;
    }
    if (command.run != 0 && command.unknown_argument) {
        g_application_command_line_printerr(line, "Unsupported option for this desktop action command.\n");
        return 2;
    }
    gboolean remote = g_application_command_line_get_is_remote(line);
    if (command.run != 0 && command.run != 1) {
        gint status = forward_window_command(command.run, command.slot, remote);
        if (status == 2)
            g_application_command_line_printerr(line, "Open JustSpeakToIt before using this action command.\n");
        else if (status != 0 && command.run == 3)
            g_application_command_line_printerr(line, "Playback Stop is unavailable while a dialog is open or the app is closing.\n");
        else if (status != 0)
            g_application_command_line_printerr(line, "Finish the current operation or close dialogs first.\n");
        return status;
    }
    if (!remote || ui.window == NULL) {
        if (ui.window == NULL) ui.start_minimized = command.background && command.run == 0;
        g_application_activate(application);
    }
    /* A remote --toggle drives the running app without raising its window, so
     * focus stays on the field that should receive the text; a second login
     * launch leaves the running app as it is. */
    if (command.run == 1) emit(JSTI_EVENT_COMMAND_TOGGLE, selected_microphone(), selected_model_slot());
    else if (remote && !command.background) gtk_window_present(ui.window);
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
    /* NON_UNIQUE still exports an object path. Keep the smoke window's path
     * separate from the private command fixture's real application identity. */
    gchar *fixture_id = (flags & JSTI_WINDOW_SMOKE_TEST) &&
        g_strcmp0(g_getenv("JSTI_COMMAND_FORWARDING_CHECK"), "1") == 0
        ? g_strconcat(app_id, ".CommandFixture", NULL) : NULL;
    ui.application = adw_application_new(fixture_id != NULL ? fixture_id : app_id, application_flags);
    g_free(fixture_id);
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
    jsti_hands_free_guard_stop();
    close_posts();
    ui.callback = NULL;
    read_aloud.picker_callback = NULL;
    read_aloud.picker_context = NULL;
    g_clear_pointer(&read_aloud.identifiers, g_ptr_array_unref);
    g_clear_pointer(&read_aloud.favorite_ranks, g_array_unref);
    g_clear_pointer(&read_aloud.favorite_indices, g_array_unref);
    g_clear_object(&read_aloud.voices);
    g_clear_object(&read_aloud.favorite_names);
    configuration.callback = NULL;
    configuration.context = NULL;
    g_clear_pointer(&configuration.revision, g_free);
    g_clear_pointer(&configuration.rows, g_ptr_array_unref);
    g_clear_pointer(&configuration.choices, g_ptr_array_unref);
    g_clear_pointer(&configuration.booleans, g_array_unref);
    g_clear_pointer(&configuration.overlay_settings, g_array_unref);
    g_clear_pointer(&configuration.hands_free_settings, g_array_unref);
    configuration.recovery_group = NULL;
    configuration.recovery_row = NULL;
    configuration.recovery_count = 0;
    g_clear_pointer(&ui.polish_catalog, g_ptr_array_unref);
    g_clear_pointer(&ui.polish_slots, g_array_unref);
    g_clear_pointer(&ui.polish_local_notice, g_free);
    g_clear_object(&ui.application);
    ui.window = NULL;
    jsti_app_icon_clear();
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
        cleanup_visible = FALSE;
        set_transcript(update->transcript);
        /* Global text is not bound to a record. */
        g_clear_pointer(&ui.presented_id, g_free);
    }
    if (update->state >= 0) ui.state = update->state;
    refresh_actions();
    jsti_tray_set_state(ui.state, ui.tray_summary);
}

static void cleanup_preview_apply(gpointer pointer) {
    (void)pointer;
    g_mutex_lock(&cleanup_lock);
    cleanup_posted = FALSE;
    if (cleanup_active && cleanup_text != NULL && !ui.closing && ui.state == JSTI_STATE_WORKING &&
        (ui.page == JSTI_PAGE_DASHBOARD || ui.page == JSTI_PAGE_HISTORY)) {
        set_transcript(cleanup_text);
        cleanup_visible = TRUE;
        gtk_label_set_text(ui.status, "Streaming cleanup preview. The original is saved in History.");
        g_clear_pointer(&ui.presented_id, g_free);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.copy), FALSE);
        gtk_widget_set_sensitive(GTK_WIDGET(ui.dashboard_copy), FALSE);
    }
    g_clear_pointer(&cleanup_text, g_free);
    g_mutex_unlock(&cleanup_lock);
}

uint64_t jsti_window_begin_cleanup_preview(void) {
    g_mutex_lock(&cleanup_lock);
    if (++cleanup_ticket == 0) ++cleanup_ticket;
    cleanup_active = TRUE;
    g_clear_pointer(&cleanup_text, g_free);
    guint64 ticket = cleanup_ticket;
    g_mutex_unlock(&cleanup_lock);
    return ticket;
}

void jsti_window_end_cleanup_preview(uint64_t ticket) {
    g_mutex_lock(&cleanup_lock);
    if (ticket == cleanup_ticket) {
        ++cleanup_ticket;
        cleanup_active = FALSE;
        g_clear_pointer(&cleanup_text, g_free);
    }
    g_mutex_unlock(&cleanup_lock);
}

int32_t jsti_window_cleanup_preview(const char *text, uint64_t ticket) {
    if (text == NULL || strlen(text) > 65536 || !g_utf8_validate(text, -1, NULL)) return -1;
    g_mutex_lock(&post_lock);
    gboolean closed = window_closed;
    g_mutex_unlock(&post_lock);
    if (closed) return 1;
    g_mutex_lock(&cleanup_lock);
    if (!cleanup_active || ticket != cleanup_ticket) {
        g_mutex_unlock(&cleanup_lock);
        return 1;
    }
    g_free(cleanup_text);
    cleanup_text = g_strdup(text);
    gboolean submit = !cleanup_posted;
    cleanup_posted = TRUE;
    g_mutex_unlock(&cleanup_lock);
    if (!submit) return 0;
    int32_t result = post(cleanup_preview_apply, NULL, NULL);
    if (result != 0) {
        g_mutex_lock(&cleanup_lock);
        cleanup_posted = FALSE;
        g_clear_pointer(&cleanup_text, g_free);
        g_mutex_unlock(&cleanup_lock);
    }
    return result;
}

int32_t jsti_window_update(const char *status, const char *transcript, int32_t state) {
    Update *update = g_new0(Update, 1);
    update->status = g_strdup(status);
    update->transcript = g_strdup(transcript);
    update->has_transcript = transcript != NULL;
    update->state = state;
    return post(update_apply, update, update_free);
}

struct Models {
    GArray *slots;
    GPtrArray *names;
    gint32 selected;
    gchar *status;
    gboolean refreshing;
};

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
        Slot slot = { .id = g_strdup(rows[index].id), .global = (gint32)index, .live = rows[index].is_live != 0 };
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

static void filter_models(gint32 keep) {
    Models *models = ui.model_catalog;
    if (models == NULL) return;
    gboolean local = jsti_model_filters_local(), live = jsti_model_filters_live();
    ui.suppress = TRUE;
    if (ui.model_slots != NULL) {
        for (guint index = 0; index < ui.model_slots->len; index++) g_free(g_array_index(ui.model_slots, Slot, index).id);
        g_array_unref(ui.model_slots);
    }
    ui.model_slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    GPtrArray *names = g_ptr_array_new();
    guint position = GTK_INVALID_LIST_POSITION;
    for (guint index = 0; index < models->slots->len; index++) {
        Slot slot = g_array_index(models->slots, Slot, index);
        if (g_str_has_prefix(slot.id, "local/") != local || slot.live != live) continue;
        Slot copy = { .id = g_strdup(slot.id), .global = slot.global, .live = slot.live };
        g_array_append_val(ui.model_slots, copy);
        g_ptr_array_add(names, g_ptr_array_index(models->names, index));
        if (slot.global == keep) position = ui.model_slots->len - 1;
    }
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(ui.model_names));
    g_ptr_array_add(names, NULL);
    gtk_string_list_splice(ui.model_names, 0, existing, (const char *const *)names->pdata);
    g_ptr_array_unref(names);
    adw_combo_row_set_selected(ui.model_row, position != GTK_INVALID_LIST_POSITION ? position :
                               (ui.model_slots->len > 0 ? 0 : GTK_INVALID_LIST_POSITION));
    refresh_azure_row();
    ui.suppress = FALSE;
    refresh_setup();
}

static void on_model_filter(gboolean local, gboolean live) {
    guint mode = local ? 2 : (live ? 1 : 0);
    filter_models(ui.preferred_model_slots[mode]);
    gint32 selected = selected_model_slot();
    if (selected >= 0) {
        ui.preferred_model_slots[mode] = selected;
        emit(JSTI_EVENT_SELECT_MODEL, "", selected);
    }
}

static void models_apply(gpointer pointer) {
    Models *models = pointer;
    gint32 keep = models->selected >= 0 ? models->selected : selected_model_slot();
    if (ui.model_catalog != NULL) models_free(ui.model_catalog);
    ui.model_catalog = g_new0(Models, 1);
    ui.model_catalog->slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    ui.model_catalog->names = g_ptr_array_new_with_free_func(g_free);
    for (guint index = 0; index < models->slots->len; index++) {
        Slot slot = g_array_index(models->slots, Slot, index);
        Slot copy = { .id = g_strdup(slot.id), .global = slot.global, .live = slot.live };
        g_array_append_val(ui.model_catalog->slots, copy);
        g_ptr_array_add(ui.model_catalog->names, g_strdup(g_ptr_array_index(models->names, index)));
        if (slot.global == keep) {
            gboolean local = g_str_has_prefix(slot.id, "local/");
            jsti_model_filters_select(local, slot.live);
            ui.preferred_model_slots[local ? 2 : (slot.live ? 1 : 0)] = keep;
        }
    }
    filter_models(keep);
    if (models->status != NULL) gtk_label_set_text(ui.catalog_status, models->status);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.catalog_refresh), !models->refreshing);
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
    const char *query = gtk_editable_get_text(GTK_EDITABLE(ui.search));
    gtk_label_set_text(GTK_LABEL(ui.history_empty), query[0] || jsti_history_filters_active()
        ? "No saved recordings match this search or filter."
        : "No history yet. Press Record to capture your first session.");
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

static void history_management_apply(gpointer pointer) {
    g_free(ui.all_history_ids);
    ui.all_history_ids = g_strdup(pointer);
    refresh_actions();
}

int32_t jsti_window_set_history_management(const char *identifiers) {
    if (identifiers == NULL || !g_utf8_validate(identifiers, -1, NULL)) return -1;
    return post(history_management_apply, g_strdup(identifiers), g_free);
}

typedef struct AudioCleanupConfirmation {
    gchar *token;
    size_t count;
} AudioCleanupConfirmation;

static void audio_cleanup_confirmation_free(gpointer pointer) {
    AudioCleanupConfirmation *confirmation = pointer;
    g_free(confirmation->token);
    g_free(confirmation);
}

static void audio_cleanup_confirmation_apply(gpointer pointer) {
    AudioCleanupConfirmation *confirmation = pointer;
    if (ui.window == NULL) return;
    if (!gtk_widget_get_sensitive(GTK_WIDGET(ui.audio_cleanup))) {
        emit(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE, confirmation->token, 0);
        return;
    }
    gtk_window_present(GTK_WINDOW(audio_cleanup_dialog(confirmation->token, confirmation->count)));
}

int32_t jsti_window_confirm_audio_cleanup(const char *token, size_t count) {
    if (token == NULL || !g_uuid_string_is_valid(token) || count == 0) return -1;
    AudioCleanupConfirmation *confirmation = g_new0(AudioCleanupConfirmation, 1);
    confirmation->token = g_strdup(token);
    confirmation->count = count;
    return post(audio_cleanup_confirmation_apply, confirmation, audio_cleanup_confirmation_free);
}

static GtkWidget *migration_report_dialog(const char *text) {
    GtkWidget *dialog = adw_message_dialog_new(ui.window, "Backup inspection (read only)", text);
    adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dialog), "close", "Close");
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "close");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "close");
    g_signal_connect_swapped(dialog, "response", G_CALLBACK(gtk_window_destroy), dialog);
    return dialog;
}

static void migration_report_apply(gpointer pointer) {
    if (ui.window != NULL && !ui.closing) gtk_window_present(GTK_WINDOW(migration_report_dialog(pointer)));
}

int32_t jsti_window_show_migration_report(const char *text) {
    if (text == NULL || text[0] == '\0' || !g_utf8_validate(text, -1, NULL)) return -1;
    return post(migration_report_apply, g_strdup(text), g_free);
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
    /* The status notifier's menu shows the dashboard's totals, as the Mac's menu bar extra does. */
    g_free(ui.tray_summary);
    ui.tray_summary = g_strcmp0(insights->all[0], "0") == 0
        ? g_strdup("No sessions yet")
        : g_strdup_printf("%s %s · %s · %s", insights->all[0],
                          g_strcmp0(insights->all[0], "1") == 0 ? "session" : "sessions", insights->all[2],
                          insights->all[4]);
    jsti_tray_set_state(ui.state, ui.tray_summary);
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

typedef struct AboutInformation {
    gchar *details;
    gchar **titles;
    gchar **urls;
} AboutInformation;

static void about_information_free(gpointer pointer) {
    AboutInformation *information = pointer;
    g_free(information->details);
    g_strfreev(information->titles);
    g_strfreev(information->urls);
    g_free(information);
}

static void about_information_apply(gpointer pointer) {
    AboutInformation *information = pointer;
    gtk_label_set_text(ui.about_details, information->details);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(ui.about_links))) != NULL)
        gtk_flow_box_remove(ui.about_links, child);
    for (guint i = 0; information->titles[i] != NULL; ++i)
        gtk_flow_box_insert(ui.about_links, link_button(information->titles[i], information->urls[i]), -1);
}

int32_t jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count) {
    if (details == NULL || links == NULL || count == 0 || count > 8 || strlen(details) > 4096 ||
        !g_utf8_validate(details, -1, NULL) || details[0] == '\0') return -1;
    for (size_t i = 0; i < count; ++i) {
        if (links[i].title == NULL || links[i].url == NULL || strlen(links[i].title) > 128 ||
            strlen(links[i].url) > 2048 || !g_utf8_validate(links[i].title, -1, NULL) ||
            !g_utf8_validate(links[i].url, -1, NULL) || links[i].title[0] == '\0' ||
            strpbrk(links[i].title, "\r\n\t") != NULL || !g_str_has_prefix(links[i].url, "https://") ||
            strlen(links[i].url) <= 8 || strpbrk(links[i].url, " \r\n\t") != NULL) return -1;
    }
    AboutInformation *information = g_new0(AboutInformation, 1);
    information->details = g_strdup(details);
    information->titles = g_new0(gchar *, count + 1);
    information->urls = g_new0(gchar *, count + 1);
    for (size_t i = 0; i < count; ++i) {
        information->titles[i] = g_strdup(links[i].title);
        information->urls[i] = g_strdup(links[i].url);
    }
    return post(about_information_apply, information, about_information_free);
}

static void post_processing_enabled_apply(gpointer pointer) {
    gboolean suppress = ui.suppress;
    ui.suppress = TRUE;
    adw_switch_row_set_active(ui.polish_row, *(gint32 *)pointer != 0);
    ui.suppress = suppress;
}

int32_t jsti_window_set_post_processing_enabled(int32_t enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    gint32 *value = g_new(gint32, 1);
    *value = enabled;
    return post(post_processing_enabled_apply, value, g_free);
}

int32_t jsti_window_set_appearance(int32_t appearance) {
    if (appearance < 0 || appearance > 2) return -1;
    return post(appearance_apply, GINT_TO_POINTER(appearance), NULL);
}

typedef struct LoginItem {
    gint32 state;
    gchar *detail;
} LoginItem;

static void login_item_free(gpointer pointer) {
    LoginItem *item = pointer;
    g_free(item->detail);
    g_free(item);
}

/* The shared DesktopLoginItemState: 0 off, 1 on, 2 off by the system,
 * 3 on by policy, 4 unavailable. Only 0 and 1 can be changed here. */
static void login_item_apply(gpointer pointer) {
    LoginItem *item = pointer;
    ui.suppress = TRUE;
    adw_switch_row_set_active(ui.login_row, item->state == 1 || item->state == 3);
    ui.suppress = FALSE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.login_row), item->state == 0 || item->state == 1);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.login_row), item->detail);
}

int32_t jsti_window_set_login_item(int32_t state, const char *detail) {
    if (state < 0 || state > 4 || detail == NULL || !g_utf8_validate(detail, -1, NULL)) return -1;
    LoginItem *item = g_new0(LoginItem, 1);
    item->state = state;
    item->detail = g_strdup(detail);
    return post(login_item_apply, item, login_item_free);
}

static void automation_apply(gpointer pointer) {
    LoginItem *item = pointer;
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    adw_switch_row_set_active(ui.automation_row, item->state != 0);
    ui.suppress = suppressed;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.automation_row), TRUE);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(ui.automation_row), item->detail);
}

int32_t jsti_window_set_automation(int32_t enabled, const char *detail) {
    if ((enabled != 0 && enabled != 1) || detail == NULL || !g_utf8_validate(detail, -1, NULL)) return -1;
    LoginItem *item = g_new0(LoginItem, 1);
    item->state = enabled;
    item->detail = g_strdup(detail);
    return post(automation_apply, item, login_item_free);
}

typedef struct HUD {
    gint32 phase;
    gint32 display_milliseconds;
    gboolean compact;
    gboolean expanded;
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
    jsti_hud_show_layout(state->phase, state->headline, state->subheadline, state->live,
                          state->display_milliseconds, state->compact, state->expanded);
}

int32_t jsti_window_set_hud(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                            int32_t display_milliseconds, int32_t compact) {
    return jsti_window_set_hud_layout(phase, headline, subheadline, live_text, display_milliseconds, compact, 0);
}

int32_t jsti_window_set_hud_layout(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                                   int32_t display_milliseconds, int32_t compact, int32_t expanded) {
    if (phase < 0 || phase > 6 || display_milliseconds < 0 || display_milliseconds > 60000 ||
        (compact != 0 && compact != 1) || (expanded != 0 && expanded != 1)) return -1;
    const char *texts[] = { headline, subheadline, live_text };
    for (size_t index = 0; index < G_N_ELEMENTS(texts); ++index) {
        if (texts[index] != NULL && !g_utf8_validate(texts[index], -1, NULL)) return -1;
    }
    HUD *state = g_new0(HUD, 1);
    state->phase = phase;
    state->display_milliseconds = display_milliseconds;
    state->compact = compact != 0;
    state->expanded = expanded != 0 && compact == 0;
    state->headline = g_strdup(headline != NULL ? headline : "");
    state->subheadline = g_strdup(subheadline != NULL ? subheadline : "");
    state->live = g_strdup(live_text != NULL ? live_text : "");
    return post(hud_apply, state, hud_free);
}

static void page_apply(gpointer data) { show_page(GPOINTER_TO_INT(data)); }

typedef struct {
    gint digits[JSTI_PAGE_COUNT];
    gchar *hints[JSTI_PAGE_COUNT];
    gboolean show_hints;
} SidebarUpdate;

static void sidebar_update_free(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) g_free(update->hints[page]);
    g_free(update);
}

static void sidebar_update_apply(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        sidebar_shortcuts.digits[page] = update->digits[page];
        GtkWidget *hint = sidebar_shortcuts.hints[page];
        const gchar *text = update->hints[page] != NULL ? update->hints[page] : "";
        gtk_label_set_text(GTK_LABEL(hint), text);
        gtk_widget_set_visible(hint, update->show_hints && text[0] != '\0');
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.sidebar, page);
        gchar *description = update->show_hints && text[0] != '\0' ? g_strdup_printf("Shortcut: %s.", text) : g_strdup("");
        gtk_accessible_update_property(GTK_ACCESSIBLE(row),
            GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
        g_free(description);
    }
    sidebar_shortcuts.configured = TRUE;
}

static void density_apply(gpointer pointer) {
    jsti_visual_density_apply(GTK_WIDGET(ui.window), pointer);
}

int32_t jsti_window_set_visual_density(JSTIVisualDensity density) {
    if ((density.compact != 0 && density.compact != 1) ||
        density.minimum_row_height < 30 || density.minimum_row_height > 64) return -1;
    const gint spacing[] = { density.page_padding, density.section_spacing, density.card_padding,
        density.content_spacing, density.inline_spacing, density.group_spacing };
    for (guint index = 0; index < G_N_ELEMENTS(spacing); ++index)
        if (spacing[index] < 0 || spacing[index] > 128) return -1;
    JSTIVisualDensity *update = g_new(JSTIVisualDensity, 1);
    *update = density;
    return post(density_apply, update, g_free);
}

int32_t jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int32_t show_hints) {
    if (bindings == NULL || count > 10 || (show_hints != 0 && show_hints != 1)) return -1;
    SidebarUpdate *update = g_new0(SidebarUpdate, 1);
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) update->digits[page] = -1;
    gboolean used[10] = { FALSE };
    for (size_t index = 0; index < count; ++index) {
        const JSTISidebarShortcut *binding = &bindings[index];
        gchar expected[8];
        g_snprintf(expected, sizeof(expected), "Ctrl+%d", binding->digit);
        if (binding->destination == NULL || binding->digit < 0 || binding->digit > 9 ||
            used[binding->digit] || g_strcmp0(binding->hint, expected) != 0) {
            sidebar_update_free(update);
            return -1;
        }
        used[binding->digit] = TRUE;
        for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
            if (g_strcmp0(page_info[page].name, binding->destination) != 0) continue;
            if (update->digits[page] != -1) { sidebar_update_free(update); return -1; }
            update->digits[page] = binding->digit;
            update->hints[page] = g_strdup(binding->hint);
        }
    }
    update->show_hints = show_hints != 0;
    return post(sidebar_update_apply, update, sidebar_update_free);
}

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
    cleanup_visible = FALSE;
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
    gboolean can_restore;
    gchar *hint;
    gchar *policy_title;
    gchar *policy_labels;
    gchar *policy_help;
    gint32 policy_selection;
} TextOutput;

static void text_output_free(gpointer pointer) {
    TextOutput *output = pointer;
    g_free(output->hint);
    g_free(output->policy_title);
    g_free(output->policy_labels);
    g_free(output->policy_help);
    g_free(output);
}

static void text_output_apply(gpointer pointer) {
    TextOutput *output = pointer;
    ui.suppress = TRUE;
    ui.can_restore_clipboard = output->can_restore;
    if (output->policy_labels != NULL) {
        gchar **labels = g_strsplit(output->policy_labels, "\n", -1);
        GtkStringList *model = gtk_string_list_new((const char *const *)labels);
        adw_combo_row_set_model(ui.app_switch_row, G_LIST_MODEL(model));
        g_object_unref(model);
        g_strfreev(labels);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.app_switch_row), output->policy_title);
        gtk_label_set_text(ui.app_switch_help, output->policy_help);
        adw_combo_row_set_selected(ui.app_switch_row, output->policy_selection);
        ui.app_switch_configured = TRUE;
    }
    adw_combo_row_set_selected(ui.output_row, output->method == 1 ? 1 : 0);
    adw_switch_row_set_active(ui.restore_row, output->restore);
    gtk_widget_set_visible(GTK_WIDGET(ui.restore_row), output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.restore_row), output->method != 1 && output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.app_switch_row), output->method != 1 && ui.app_switch_configured);
    gboolean explicit_policy = ui.app_switch_configured && adw_combo_row_get_selected(ui.app_switch_row) != 0;
    adw_preferences_group_set_description(ui.output_group, explicit_policy ?
        "The saved app-switch policy is enforced. Unsupported or uncertain destinations copy only; "
        "the delivery support explanation below describes this desktop's limits." : output->can_restore ?
        "Finished text goes to the app you were in when dictation started. Recording in this window offers "
        "Copy instead." :
        "Wayland pastes into the app focused at delivery and cannot confirm when it consumes the paste, "
        "so the transcript stays on the clipboard. Your X11 restoration preference is retained. "
        "Recording in this window offers Copy instead.");
    if (output->hint != NULL) adw_action_row_set_subtitle(ui.shortcut_row, output->hint);
    ui.suppress = FALSE;
    refresh_setup();
}

int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard,
                                   int32_t can_restore_clipboard, const char *shortcut_hint) {
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    return post(text_output_apply, output, text_output_free);
}

int32_t jsti_window_set_text_output_policy(
    int32_t method, int32_t restore_clipboard, int32_t can_restore_clipboard, const char *shortcut_hint,
    const char *policy_title, const char *policy_labels, int32_t policy_selection, const char *policy_help) {
    if (method < 0 || method > 1 || policy_title == NULL || *policy_title == '\0' || policy_labels == NULL ||
        policy_help == NULL || !g_utf8_validate(policy_title, -1, NULL) ||
        !g_utf8_validate(policy_labels, -1, NULL) || !g_utf8_validate(policy_help, -1, NULL)) return -1;
    gchar **labels = g_strsplit(policy_labels, "\n", -1);
    guint count = g_strv_length(labels);
    gboolean valid = count > 0 && policy_selection >= 0 && (guint)policy_selection < count;
    for (guint index = 0; index < count; index++) valid = valid && *labels[index] != '\0';
    g_strfreev(labels);
    if (!valid) return -1;
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    output->policy_title = g_strdup(policy_title);
    output->policy_labels = g_strdup(policy_labels);
    output->policy_help = g_strdup(policy_help);
    output->policy_selection = policy_selection;
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
    gboolean include_directives;
    gboolean include_tags;
    gint32 selected;
    gint32 local_index;
    gint32 remembered_remote_index;
    gchar *local_notice;
    gchar *prompt;
} Polish;

static void polish_free(gpointer pointer) {
    Polish *polish = pointer;
    g_ptr_array_unref(polish->models);
    g_free(polish->prompt);
    g_free(polish->local_notice);
    g_free(polish);
}

static void polish_apply(gpointer pointer) {
    Polish *polish = pointer;
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    gint32 local_selected = ui.polish_local_selected;
    gboolean retain_local = local_selected >= polish->local_index && ui.polish_catalog != NULL &&
        (guint)local_selected < ui.polish_catalog->len && (guint)local_selected < polish->models->len &&
        g_strcmp0(g_ptr_array_index(ui.polish_catalog, local_selected),
                  g_ptr_array_index(polish->models, local_selected)) == 0;
    g_clear_pointer(&ui.polish_catalog, g_ptr_array_unref);
    ui.polish_catalog = g_ptr_array_ref(polish->models);
    ui.polish_local_index = polish->local_index;
    polish_remote_count = (guint)polish->local_index;
    g_free(ui.polish_local_notice);
    ui.polish_local_notice = g_strdup(polish->local_notice);
    ui.polish_remote_selected = polish->selected >= 0 && polish->selected < polish->local_index
        ? polish->selected : polish->remembered_remote_index;
    ui.polish_local_selected = polish->selected >= polish->local_index ? polish->selected
        : retain_local ? local_selected : polish->local_index;
    adw_combo_row_set_selected(ui.polish_location_row, polish->selected < 0
        ? GTK_INVALID_LIST_POSITION : (guint)polish->selected >= polish_remote_boundary() ? 0 : 1);
    polish_select_location(polish->selected, FALSE);
    adw_switch_row_set_active(ui.polish_row, polish->enabled);
    adw_switch_row_set_active(ui.polish_directives_row, polish->include_directives);
    adw_switch_row_set_active(ui.polish_tags_row, polish->include_tags);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(ui.polish_prompt_row),
        polish->prompt != NULL ? polish->prompt : "", -1);
    ui.suppress = suppressed;
}

static void cleanup_sources_apply(gpointer pointer) {
    const guint count = GPOINTER_TO_UINT(pointer);
    if (ui.polish_catalog == NULL || count > ui.polish_catalog->len ||
        ui.polish_local_index < 0 || count != (guint)ui.polish_local_index) {
        jsti_window_update("The post-processing source boundary is inconsistent with its model choices.", NULL, -1);
        return;
    }
    gint32 selected = polish_selected_model();
    polish_remote_count = count;
    polish_select_location(selected, FALSE);
}

int32_t jsti_window_set_cleanup_sources(size_t count) {
    if (count > 10000) return -1;
    return post(cleanup_sources_apply, GUINT_TO_POINTER((guint)count), NULL);
}

int32_t jsti_window_set_post_processing(
    const char *const *models, size_t count, int32_t enabled, int32_t selected,
    int32_t local_index, int32_t remembered_remote_index, const char *local_notice,
    int32_t include_directives, int32_t include_tags, const char *prompt) {
    if (models == NULL || count == 0 || count > 10000 || (enabled != 0 && enabled != 1) ||
        selected < -1 || (selected >= 0 && (size_t)selected >= count) ||
        local_index < 0 || (size_t)local_index >= count || local_notice == NULL || *local_notice == '\0' ||
        remembered_remote_index < -1 || remembered_remote_index >= local_index ||
        !g_utf8_validate(local_notice, -1, NULL) || prompt == NULL ||
        !g_utf8_validate(prompt, -1, NULL) || strlen(prompt) > 65535 ||
        (include_directives != 0 && include_directives != 1) || (include_tags != 0 && include_tags != 1)) return -1;
    for (size_t index = 0; index < count; index++) {
        if (models[index] == NULL || !g_utf8_validate(models[index], -1, NULL)) return -1;
    }
    Polish *polish = g_new0(Polish, 1);
    polish->models = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(polish->models, g_strdup(models[index]));
    polish->enabled = enabled != 0;
    polish->include_directives = include_directives != 0;
    polish->include_tags = include_tags != 0;
    polish->selected = selected;
    polish->prompt = g_strdup(prompt);
    polish->local_index = local_index;
    polish->remembered_remote_index = remembered_remote_index;
    polish->local_notice = g_strdup(local_notice);
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

typedef struct ConfigurationUpdate {
    GPtrArray *titles, *values, *groups, *recovered, *choices;
    GArray *booleans;
    GArray *overlay_settings;
    GArray *hands_free_settings;
    GArray *enabled_by_fields;
    JSTIConfigurationCallback callback;
    void *context;
    gchar *revision;
} ConfigurationUpdate;

static void configuration_problem(const char *message) {
    gtk_label_set_text(ui.status, message);
}

static void configuration_submit(gint32 action, const char *const *values, gsize count) {
    char error[1024] = {0};
    if (configuration.callback == NULL) {
        configuration_problem("Configuration controls are unavailable.");
    } else if (configuration.callback(action, values, count, configuration.context, error, sizeof(error)) != 0) {
        configuration_problem(error[0] ? error : "Configuration could not be applied.");
    }
}

static void on_configuration_apply(GtkButton *button, gpointer data) {
    (void)button;
    if (ui.state != JSTI_STATE_IDLE) {
        configuration_problem("Finish dictation before changing configuration.");
        return;
    }
    GPtrArray *values = g_ptr_array_new_with_free_func(g_free);
    gint32 action = GPOINTER_TO_INT(data);
    for (guint i = 0; i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        gboolean boolean = g_array_index(configuration.booleans, gboolean, i);
        const char *choices = g_ptr_array_index(configuration.choices, i);
        if (choices[0] != '\0') {
            gchar **lines = g_strsplit(choices, "\n", -1);
            guint selected = adw_combo_row_get_selected(ADW_COMBO_ROW(row));
            if (selected >= g_strv_length(lines)) {
                g_strfreev(lines);
                g_ptr_array_unref(values);
                configuration_problem("Choose a value for each preference first.");
                return;
            }
            g_ptr_array_add(values, g_strndup(lines[selected], strchr(lines[selected], '\t') - lines[selected]));
            g_strfreev(lines);
            continue;
        }
        g_ptr_array_add(values, g_strdup(boolean
            ? (adw_switch_row_get_active(ADW_SWITCH_ROW(row)) ? "1" : "0")
            : gtk_editable_get_text(GTK_EDITABLE(row))));
    }
    if (action == 3) {
        guint selected = adw_combo_row_get_selected(configuration.recovery_row);
        if (selected >= configuration.recovery_count) {
            configuration_problem("Choose a recovered keyword edit first.");
            g_ptr_array_unref(values);
            return;
        }
        GtkStringList *model = GTK_STRING_LIST(adw_combo_row_get_model(configuration.recovery_row));
        g_ptr_array_add(values, g_strdup(gtk_string_list_get_string(model, selected)));
    }
    if (configuration.revision != NULL)
        g_ptr_array_add(values, g_strdup(configuration.revision));
    configuration_submit(action, (const char *const *)values->pdata, values->len);
    g_ptr_array_unref(values);
}

static void configuration_file_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    gint32 action = GPOINTER_TO_INT(data);
    GError *error = NULL;
    GFile *file = action == 1 ? gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error)
                             : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL) {
            const char *values[] = {path};
            configuration_submit(action, values, 1);
        } else configuration_problem("Choose a local configuration file.");
        g_free(path);
        g_object_unref(file);
    } else if (error != NULL && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
        configuration_problem(error->message);
    }
    g_clear_error(&error);
}

static void on_configuration_file(GtkButton *button, gpointer data) {
    (void)button;
    gint32 action = GPOINTER_TO_INT(data);
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, action == 1 ? "Import portable preferences" : "Export portable preferences");
    if (action == 2) gtk_file_dialog_set_initial_name(dialog, "Dictation-preferences.json");
    if (action == 1) gtk_file_dialog_open(dialog, ui.window, NULL, configuration_file_chosen, data);
    else gtk_file_dialog_save(dialog, ui.window, NULL, configuration_file_chosen, data);
    g_object_unref(dialog);
}

static void configuration_update_free(gpointer data) {
    ConfigurationUpdate *update = data;
    g_ptr_array_unref(update->titles);
    g_ptr_array_unref(update->values);
    g_ptr_array_unref(update->groups);
    g_ptr_array_unref(update->recovered);
    g_ptr_array_unref(update->choices);
    g_array_unref(update->booleans);
    g_array_unref(update->overlay_settings);
    g_array_unref(update->hands_free_settings);
    g_array_unref(update->enabled_by_fields);
    g_free(update->revision);
    g_free(update);
}

static void configuration_hands_free_availability(GtkWidget *row, gboolean enabled) {
    gboolean ready = jsti_window_hands_free_guard_ready() != 0;
    gtk_widget_set_sensitive(row, ready || enabled);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), ready ? NULL : enabled ?
        "Monitoring unavailable. Turn off saved hands-free mode to restore manual shortcuts." :
        "Unavailable: native session lock/sleep monitoring is required. Manual recording still works.");
}

static void configuration_dependencies(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        gint32 enabling = g_array_index(configuration.enabled_by_fields, gint32, i);
        if (enabling == -1) {
            GtkWidget *row = g_ptr_array_index(configuration.rows, i);
            gtk_widget_set_sensitive(row, FALSE);
            adw_action_row_set_subtitle(ADW_ACTION_ROW(row),
                "Unavailable on this host: no confirmed editable field/span readback. Retained for transfer.");
            continue;
        }
        if (!enabling) continue;
        AdwSwitchRow *control = ADW_SWITCH_ROW(g_ptr_array_index(configuration.rows, enabling - 1));
        gtk_widget_set_sensitive(g_ptr_array_index(configuration.rows, i), adw_switch_row_get_active(control));
    }
}

static void configuration_apply(gpointer data) {
    ConfigurationUpdate *update = data;
    configuration.callback = update->callback;
    configuration.context = update->context;
    g_free(configuration.revision);
    configuration.revision = g_strdup(update->revision);
    if (configuration.rows == NULL) {
        configuration.rows = g_ptr_array_new();
        configuration.choices = g_ptr_array_ref(update->choices);
        configuration.booleans = g_array_ref(update->booleans);
        configuration.overlay_settings = g_array_ref(update->overlay_settings);
        configuration.hands_free_settings = g_array_ref(update->hands_free_settings);
        configuration.enabled_by_fields = g_array_ref(update->enabled_by_fields);
        GtkWidget *groups[5];
        for (guint i = 0; i < G_N_ELEMENTS(groups); ++i) {
            groups[i] = group(i == 4 ? "Correction learning" : "Dictation preferences");
            adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(groups[i]),
                i == 4 ? "Apply saves all preference fields. Enabling learning does not grant local session permission."
                : "Apply saves all preference fields. Provider-specific options only affect supported routes.");
            gtk_box_append(GTK_BOX(ui.configuration_columns[i]), groups[i]);
        }
        if (!jsti_hud_overlay_supported())
            adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(groups[0]),
                "Wayland uses desktop notifications, not a positioned recording overlay. "
                "Overlay-only preferences are retained for X11 but hidden here; your desktop controls notification expiry.");
        for (guint i = 0; i < update->titles->len; ++i) {
            const char *section = g_ptr_array_index(update->groups, i);
            guint slot = g_strcmp0(section, "Transcription") == 0 ? 1 :
                g_strcmp0(section, "Post-processing") == 0 ? 2 : g_strcmp0(section, "Keyboard") == 0 ? 3 :
                g_strcmp0(section, "Corrections") == 0 ? 4 : 0;
            gboolean boolean = g_array_index(update->booleans, gboolean, i);
            const char *choices = g_ptr_array_index(update->choices, i);
            GtkWidget *row = boolean ? adw_switch_row_new() :
                choices[0] != '\0' ? adw_combo_row_new() : adw_entry_row_new();
            if (choices[0] != '\0') {
                gchar **lines = g_strsplit(choices, "\n", -1);
                GtkStringList *model = gtk_string_list_new(NULL);
                for (guint choice = 0; lines[choice] != NULL; ++choice)
                    gtk_string_list_append(model, strchr(lines[choice], '\t') + 1);
                adw_combo_row_set_model(ADW_COMBO_ROW(row), G_LIST_MODEL(model));
                g_object_unref(model);
                g_strfreev(lines);
            }
            adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(update->titles, i));
            adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[slot]), row);
            if (g_array_index(update->overlay_settings, gboolean, i) && !jsti_hud_overlay_supported())
                gtk_widget_set_visible(row, FALSE);
            g_ptr_array_add(configuration.rows, row);
            if (boolean) g_signal_connect(row, "notify::active", G_CALLBACK(configuration_dependencies), NULL);
        }
        for (guint i = 0; i < G_N_ELEMENTS(groups); ++i) {
            GtkWidget *apply = gtk_button_new_with_label("Apply preferences");
            gtk_widget_set_halign(apply, GTK_ALIGN_END);
            g_signal_connect(apply, "clicked", G_CALLBACK(on_configuration_apply), NULL);
            adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[i]), apply);
        }
        GtkWidget *sound_previews = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *preview_start = gtk_button_new_with_label("Save & preview start");
        GtkWidget *preview_stop = gtk_button_new_with_label("Save & preview stop");
        g_signal_connect(preview_start, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(4));
        g_signal_connect(preview_stop, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(5));
        gtk_box_append(GTK_BOX(sound_previews), preview_start);
        gtk_box_append(GTK_BOX(sound_previews), preview_stop);
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[0]), sound_previews);
        configuration.recovery_group = group("Recovered keyword edits");
        adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(configuration.recovery_group),
            "A deliberate clear remains active. Restore only the edit you choose; it is added to your current list.");
        configuration.recovery_row = ADW_COMBO_ROW(adw_combo_row_new());
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(configuration.recovery_row), "Recovered keyword edit");
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(configuration.recovery_group),
            GTK_WIDGET(configuration.recovery_row));
        GtkWidget *restore = gtk_button_new_with_label("Restore selected keywords");
        gtk_widget_set_halign(restore, GTK_ALIGN_END);
        g_signal_connect(restore, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(3));
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(configuration.recovery_group), restore);
        gtk_box_append(GTK_BOX(ui.configuration_columns[1]), configuration.recovery_group);
        GtkWidget *transfer = group("Portable configuration");
        adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(transfer),
            "Transfers portable preferences, not keys, models, device paths or service permissions. "
            "This JSON format is not a macOS backup archive. Unsupported entries are preserved, not applied.");
        GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *import = gtk_button_new_with_label("Import preferences...");
        GtkWidget *export = gtk_button_new_with_label("Export preferences...");
        g_signal_connect(import, "clicked", G_CALLBACK(on_configuration_file), GINT_TO_POINTER(1));
        g_signal_connect(export, "clicked", G_CALLBACK(on_configuration_file), GINT_TO_POINTER(2));
        gtk_box_append(GTK_BOX(buttons), import);
        gtk_box_append(GTK_BOX(buttons), export);
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(transfer), buttons);
        gtk_box_append(GTK_BOX(ui.configuration_columns[0]), transfer);
    }
    for (guint i = 0; i < update->values->len && i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(update->titles, i));
        const char *value = g_ptr_array_index(update->values, i);
        if (g_array_index(configuration.booleans, gboolean, i))
            adw_switch_row_set_active(ADW_SWITCH_ROW(row), g_strcmp0(value, "1") == 0);
        else if (ADW_IS_COMBO_ROW(row)) {
            gchar **lines = g_strsplit(g_ptr_array_index(configuration.choices, i), "\n", -1);
            for (guint choice = 0; lines[choice] != NULL; ++choice) {
                const char *tab = strchr(lines[choice], '\t');
                if (strlen(value) == (size_t)(tab - lines[choice]) && strncmp(value, lines[choice], tab - lines[choice]) == 0)
                    adw_combo_row_set_selected(ADW_COMBO_ROW(row), choice);
            }
            g_strfreev(lines);
        } else gtk_editable_set_text(GTK_EDITABLE(row), value);
        if (g_array_index(configuration.hands_free_settings, gboolean, i))
            configuration_hands_free_availability(row, g_strcmp0(value, "1") == 0);
    }
    configuration_dependencies(NULL, NULL, NULL);
    GtkStringList *recovered = gtk_string_list_new(NULL);
    for (guint i = 0; i < update->recovered->len; ++i)
        gtk_string_list_append(recovered, g_ptr_array_index(update->recovered, i));
    adw_combo_row_set_model(configuration.recovery_row, G_LIST_MODEL(recovered));
    g_object_unref(recovered);
    configuration.recovery_count = update->recovered->len;
    gtk_widget_set_visible(configuration.recovery_group, configuration.recovery_count > 0);
    if (configuration.revision != NULL) {
        const char *values[] = {configuration.revision};
        configuration_submit(6, values, 1);
    }
}

static gboolean configuration_choices_valid(const char *choices, const char *value) {
    if (choices == NULL || value == NULL || choices[0] == '\0' ||
        !g_utf8_validate(choices, -1, NULL) || strlen(choices) > 65535) return FALSE;
    gchar **lines = g_strsplit(choices, "\n", -1);
    gboolean valid = g_strv_length(lines) <= 32, found = FALSE;
    for (guint choice = 0; valid && lines[choice] != NULL; ++choice) {
        const char *tab = strchr(lines[choice], '\t');
        if (tab == NULL || tab[1] == '\0' || strchr(tab + 1, '\t') != NULL) {
            valid = FALSE;
            break;
        }
        const size_t length = (size_t)(tab - lines[choice]);
        for (guint previous = 0; previous < choice; ++previous) {
            const char *previous_tab = strchr(lines[previous], '\t');
            if ((size_t)(previous_tab - lines[previous]) == length &&
                strncmp(lines[previous], lines[choice], length) == 0) {
                valid = FALSE;
                break;
            }
        }
        found |= strlen(value) == length && strncmp(value, lines[choice], length) == 0;
    }
    g_strfreev(lines);
    return valid && found;
}

static int32_t set_configuration(const JSTIConfigurationField *fields, size_t count,
                                      const char *const *recovered_keywords, size_t recovered_count,
                                      JSTIConfigurationCallback callback, void *context, const char *revision) {
    if (fields == NULL || count == 0 || count > JSTI_MAXIMUM_CONFIGURATION_FIELDS ||
        callback == NULL || recovered_count > 1000 ||
        (recovered_count > 0 && recovered_keywords == NULL) ||
        (revision != NULL && (revision[0] == '\0' || strlen(revision) > 64))) return -1;
    ConfigurationUpdate *update = g_new0(ConfigurationUpdate, 1);
    update->titles = g_ptr_array_new_with_free_func(g_free);
    update->values = g_ptr_array_new_with_free_func(g_free);
    update->groups = g_ptr_array_new_with_free_func(g_free);
    update->recovered = g_ptr_array_new_with_free_func(g_free);
    update->choices = g_ptr_array_new_with_free_func(g_free);
    update->booleans = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->overlay_settings = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->hands_free_settings = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->enabled_by_fields = g_array_new(FALSE, FALSE, sizeof(gint32));
    update->callback = callback;
    update->context = context;
    update->revision = g_strdup(revision);
    for (size_t i = 0; i < recovered_count; ++i) {
        if (recovered_keywords[i] == NULL || !g_utf8_validate(recovered_keywords[i], -1, NULL) ||
            strlen(recovered_keywords[i]) > 65535) {
            configuration_update_free(update);
            return -1;
        }
        g_ptr_array_add(update->recovered, g_strdup(recovered_keywords[i]));
    }
    for (size_t i = 0; i < count; ++i) {
        const gint32 enabling = fields[i].enabled_by_field;
        if (enabling < -1 || (enabling > 0 && ((size_t)enabling > count ||
            (size_t)enabling == i + 1 || fields[enabling - 1].is_boolean != 1))) {
            configuration_update_free(update);
            return -1;
        }
        g_array_append_val(update->enabled_by_fields, enabling);
        if (!fields[i].title || !fields[i].value || !fields[i].group ||
            !g_utf8_validate(fields[i].value, -1, NULL) || strlen(fields[i].value) > 65535 ||
            (fields[i].requires_hud_overlay != 0 && fields[i].requires_hud_overlay != 1) ||
            (fields[i].requires_hands_free_guard != 0 && fields[i].requires_hands_free_guard != 1) ||
            (fields[i].requires_hands_free_guard && fields[i].is_boolean != 1)) {
            configuration_update_free(update);
            return -1;
        }
        const char *choices = fields[i].choices != NULL ? fields[i].choices : "";
        if (!g_utf8_validate(choices, -1, NULL) || strlen(choices) > 65535 ||
            (choices[0] != '\0' && fields[i].is_boolean != 0)) {
            configuration_update_free(update);
            return -1;
        }
        if (choices[0] != '\0' && !configuration_choices_valid(choices, fields[i].value)) {
            configuration_update_free(update);
            return -1;
        }
        g_ptr_array_add(update->choices, g_strdup(choices));
        g_ptr_array_add(update->titles, g_strdup(fields[i].title));
        g_ptr_array_add(update->values, g_strdup(fields[i].value));
        g_ptr_array_add(update->groups, g_strdup(fields[i].group));
        gboolean boolean = fields[i].is_boolean != 0;
        g_array_append_val(update->booleans, boolean);
        gboolean overlay_setting = fields[i].requires_hud_overlay != 0;
        g_array_append_val(update->overlay_settings, overlay_setting);
        gboolean hands_free_setting = fields[i].requires_hands_free_guard != 0;
        g_array_append_val(update->hands_free_settings, hands_free_setting);
    }
    return post(configuration_apply, update, configuration_update_free);
}

int32_t jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recovered_count, JSTIConfigurationCallback callback, void *context) {
    return set_configuration(fields, count, recovered, recovered_count, callback, context, NULL);
}

int32_t jsti_window_set_configuration_revision(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recovered_count, JSTIConfigurationCallback callback,
    void *context, const char *revision) {
    return revision != NULL ? set_configuration(fields, count, recovered, recovered_count, callback, context, revision) : -1;
}

typedef struct {
    size_t index;
    gchar *title;
} ConfigurationTitleUpdate;

static void configuration_title_free(gpointer data) {
    ConfigurationTitleUpdate *update = data;
    g_free(update->title);
    g_free(update);
}

static void configuration_title_apply(gpointer data) {
    ConfigurationTitleUpdate *update = data;
    if (configuration.rows == NULL) return;
    if (update->index >= configuration.rows->len) {
        configuration_problem("The Voice language field could not be found.");
        return;
    }
    adw_preferences_row_set_title(
        ADW_PREFERENCES_ROW(g_ptr_array_index(configuration.rows, update->index)), update->title);
}

int32_t jsti_window_set_configuration_field_title(size_t index, const char *title) {
    if (index >= JSTI_MAXIMUM_CONFIGURATION_FIELDS || title == NULL || title[0] == '\0' ||
        !g_utf8_validate(title, -1, NULL) || strlen(title) > 256) return -1;
    ConfigurationTitleUpdate *update = g_new0(ConfigurationTitleUpdate, 1);
    update->index = index;
    update->title = g_strdup(title);
    return post(configuration_title_apply, update, configuration_title_free);
}

typedef struct { size_t index; gboolean enabled; } ConfigurationAvailabilityUpdate;
static void configuration_availability_apply(gpointer data) {
    ConfigurationAvailabilityUpdate *update = data;
    if (configuration.rows == NULL) return;
    if (update->index >= configuration.rows->len ||
        g_array_index(configuration.enabled_by_fields, gint32, update->index) != 0) {
        configuration_problem("The Voice quality field availability could not be updated.");
        return;
    }
    gtk_widget_set_sensitive(g_ptr_array_index(configuration.rows, update->index), update->enabled);
}
int32_t jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled) {
    if (index >= JSTI_MAXIMUM_CONFIGURATION_FIELDS || (enabled != 0 && enabled != 1)) return -1;
    ConfigurationAvailabilityUpdate *update = g_new0(ConfigurationAvailabilityUpdate, 1);
    update->index = index; update->enabled = enabled;
    return post(configuration_availability_apply, update, g_free);
}

/* The locale/language field is no longer guaranteed to occupy row 0 (visual
 * density can precede it); the self-test discovers the real index and
 * threads it through here via the existing untyped context pointer. */
typedef struct {
    guint calls;
    guint language_index;
    guint empty_choice_index;
} ConfigurationSelfTestContext;

static const char auto_clean_choices[] = "instant\tInstant\nlivePolish\tAuto-Clean";

typedef struct { guint index; guint calls; } AutoCleanConfigurationTest;

static gboolean configuration_test_revision(const char *const *values, size_t *count) {
    if (configuration.revision == NULL) return TRUE;
    if (*count == 0 || g_strcmp0(values[*count - 1], configuration.revision) != 0) return FALSE;
    --*count;
    return TRUE;
}

static int32_t configuration_auto_clean_callback(
    int32_t action, const char *const *values, size_t count, void *context, char *error, size_t capacity
) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    AutoCleanConfigurationTest *test = context;
    const guint index = test->index;
    if (action != 0 || count != configuration.rows->len || index + 4 >= count ||
        g_strcmp0(values[index], "instant") != 0 ||
        g_strcmp0(values[index + 1], "fixture/model") != 0 ||
        g_strcmp0(values[index + 2], "250") != 0 ||
        g_strcmp0(values[index + 3], "3") != 0 ||
        g_strcmp0(values[index + 4], "0") != 0) return -1;
    ++test->calls;
    return 0;
}

static gboolean configuration_auto_clean_self_test(void) {
    guint index = configuration.rows->len;
    for (guint i = 0; i < configuration.rows->len; ++i)
        if (g_strcmp0(g_ptr_array_index(configuration.choices, i), auto_clean_choices) == 0) {
            index = i;
            break;
        }
    if (index + 4 >= configuration.rows->len || configuration.rows->len <= 32) return FALSE;
    AdwComboRow *speed = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, index));
    GtkWidget *model = g_ptr_array_index(configuration.rows, index + 1);
    GtkWidget *debounce = g_ptr_array_index(configuration.rows, index + 2);
    GtkWidget *delta = g_ptr_array_index(configuration.rows, index + 3);
    GtkWidget *skip = g_ptr_array_index(configuration.rows, index + 4);
    if (!ADW_IS_ENTRY_ROW(model) || !ADW_IS_ENTRY_ROW(debounce) ||
        !ADW_IS_ENTRY_ROW(delta) || !ADW_IS_SWITCH_ROW(skip) ||
        g_list_model_get_n_items(adw_combo_row_get_model(speed)) != 2) return FALSE;
    const guint saved_speed = adw_combo_row_get_selected(speed);
    gchar *saved_model = g_strdup(gtk_editable_get_text(GTK_EDITABLE(model)));
    gchar *saved_debounce = g_strdup(gtk_editable_get_text(GTK_EDITABLE(debounce)));
    gchar *saved_delta = g_strdup(gtk_editable_get_text(GTK_EDITABLE(delta)));
    const gboolean saved_skip = adw_switch_row_get_active(ADW_SWITCH_ROW(skip));
    JSTIConfigurationCallback callback = configuration.callback;
    void *context = configuration.context;
    AutoCleanConfigurationTest test = { .index = index, .calls = 0 };
    configuration.callback = configuration_auto_clean_callback;
    configuration.context = &test;
    adw_combo_row_set_selected(speed, 0);
    gtk_editable_set_text(GTK_EDITABLE(model), "fixture/model");
    gtk_editable_set_text(GTK_EDITABLE(debounce), "250");
    gtk_editable_set_text(GTK_EDITABLE(delta), "3");
    adw_switch_row_set_active(ADW_SWITCH_ROW(skip), FALSE);
    on_configuration_apply(NULL, NULL);
    adw_combo_row_set_selected(speed, saved_speed);
    gtk_editable_set_text(GTK_EDITABLE(model), saved_model);
    gtk_editable_set_text(GTK_EDITABLE(debounce), saved_debounce);
    gtk_editable_set_text(GTK_EDITABLE(delta), saved_delta);
    adw_switch_row_set_active(ADW_SWITCH_ROW(skip), saved_skip);
    g_free(saved_model); g_free(saved_debounce); g_free(saved_delta);
    configuration.callback = callback;
    configuration.context = context;
    return test.calls == 1;
}

static gboolean configuration_empty_choice_self_test(void) {
    const char *choices = "\tLegacy fixture\n retained \tExplicit fixture";
    gboolean valid = configuration_choices_valid(choices, "") &&
        configuration_choices_valid(choices, " retained ") && !configuration_choices_valid(choices, "retained");
    const char *invalid[] = {
        "\tLegacy\n\tDuplicate empty", "\tLegacy\nretained\tFirst\nretained\tDuplicate", "\t",
        "\tLegacy\textra", "Missing separator", "\tLegacy\nretained\t", "\tLegacy\n", "\xff\tInvalid"
    };
    for (guint index = 0; index < G_N_ELEMENTS(invalid); ++index)
        valid = !configuration_choices_valid(invalid[index], "") && valid;
    valid = !configuration_choices_valid(choices, "not-listed") && valid;
    GString *bounded = g_string_new("\tLegacy fixture");
    for (guint index = 1; index < 32; ++index) g_string_append_printf(bounded, "\nvalue%u\tChoice", index);
    valid = configuration_choices_valid(bounded->str, "") && valid;
    g_string_append(bounded, "\nextra\tThirty-third choice");
    valid = !configuration_choices_valid(bounded->str, "") && valid;
    g_string_set_size(bounded, 65536);
    memset(bounded->str, 'x', bounded->len);
    valid = !configuration_choices_valid(bounded->str, "") && valid;
    g_string_free(bounded, TRUE);
    return valid;
}

static int32_t configuration_test_callback(int32_t action, const char *const *values, size_t count,
                                          void *context, char *error, size_t capacity) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    ConfigurationSelfTestContext *test_context = context;
    if (test_context->language_index >= count) return -1;
    if (g_strcmp0(values[test_context->language_index], "fr_FR") != 0) return -1;
    if ((action == 0 || action == 4 || action == 5) && count != configuration.rows->len) return -1;
    if (action == 3 && (count != configuration.rows->len + 1 ||
        g_strcmp0(values[count - 1], "Second recoverable edit") != 0)) return -1;
    if (action != 0 && action != 3 && action != 4 && action != 5) return -1;
    for (guint i = 0; i < configuration.rows->len; ++i)
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] != '\0') {
            const char *choices = g_ptr_array_index(configuration.choices, i);
            gchar **lines = g_strsplit(choices, "\n", -1);
            const guint selected_index = test_context->empty_choice_index == i ? 0 : 1;
            const char *line = g_strv_length(lines) > selected_index ? lines[selected_index] : NULL;
            const char *tab = line != NULL ? strchr(line, '\t') : NULL;
            const gboolean selected = tab != NULL && strlen(values[i]) == (size_t)(tab - line) &&
                strncmp(values[i], line, tab - line) == 0;
            g_strfreev(lines);
            if (!selected) {
                g_printerr("Configuration self-test: field %u did not emit choice %u.\n", i, selected_index);
                return -1;
            }
        }
    ++test_context->calls;
    return 0;
}

typedef struct { guint intent; guint approval; guint calls; gboolean approved; } WarmApprovalConfigurationTest;

static int32_t configuration_warm_approval_callback(
    int32_t action, const char *const *values, size_t count, void *context, char *error, size_t capacity
) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    WarmApprovalConfigurationTest *test = context;
    if (action != 0 || count != configuration.rows->len || test->intent >= count || test->approval >= count ||
        g_strcmp0(values[test->intent], "1") != 0 ||
        g_strcmp0(values[test->approval], test->approved ? "1" : "0") != 0) return -1;
    ++test->calls;
    return 0;
}

static gboolean configuration_warm_approval_self_test(void) {
    WarmApprovalConfigurationTest test = {
        .intent = configuration.rows->len, .approval = configuration.rows->len, .calls = 0, .approved = FALSE
    };
    for (guint index = 0; index < configuration.rows->len; ++index) {
        const char *title = adw_preferences_row_get_title(
            ADW_PREFERENCES_ROW(g_ptr_array_index(configuration.rows, index)));
        if (g_strcmp0(title, "Prepare completed-only OpenRouter cleanup (not live/streaming)") == 0)
            test.intent = index;
        if (g_strcmp0(title, "Approve probes this session, only after successful capture") == 0)
            test.approval = index;
    }
    if (test.intent >= configuration.rows->len || test.approval >= configuration.rows->len) return FALSE;
    GtkWidget *intent = g_ptr_array_index(configuration.rows, test.intent);
    GtkWidget *approval = g_ptr_array_index(configuration.rows, test.approval);
    if (!ADW_IS_SWITCH_ROW(intent) || !ADW_IS_SWITCH_ROW(approval) ||
        g_array_index(configuration.enabled_by_fields, gint32, test.approval) != (gint32)test.intent + 1)
        return FALSE;
    const gboolean saved_intent = adw_switch_row_get_active(ADW_SWITCH_ROW(intent));
    const gboolean saved_approval = adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    JSTIConfigurationCallback saved_callback = configuration.callback;
    void *saved_context = configuration.context;
    configuration.callback = configuration_warm_approval_callback;
    configuration.context = &test;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), FALSE);
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), FALSE);
    gboolean valid = !gtk_widget_get_sensitive(approval) &&
        !adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), TRUE);
    valid = valid && gtk_widget_get_sensitive(approval) &&
        !adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    on_configuration_apply(NULL, NULL);
    valid = valid && test.calls == 1;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), TRUE);
    test.approved = TRUE;
    on_configuration_apply(NULL, NULL);
    valid = valid && test.calls == 2;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), saved_approval);
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), saved_intent);
    configuration.callback = saved_callback;
    configuration.context = saved_context;
    return valid;
}

static gboolean configuration_self_test(void) {
    if (!configuration_empty_choice_self_test()) return FALSE;
    if (configuration.rows == NULL || configuration.rows->len < 10 ||
        configuration.rows->len != configuration.booleans->len ||
        configuration.rows->len != configuration.overlay_settings->len ||
        configuration.rows->len != configuration.hands_free_settings->len) return FALSE;
    GtkWidget *corrections = gtk_stack_get_child_by_name(ui.pages, "corrections");
    if (ui.configuration_columns[4] == NULL || corrections == NULL ||
        !gtk_widget_is_ancestor(ui.configuration_columns[4], corrections)) return FALSE;
    gboolean found_learning_switch = FALSE, found_learning_threshold = FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        if (!gtk_widget_is_ancestor(row, ui.configuration_columns[4])) continue;
        if (gtk_widget_is_ancestor(row, ui.configuration_columns[0])) return FALSE;
        found_learning_switch |= ADW_IS_SWITCH_ROW(row);
        found_learning_threshold |= ADW_IS_ENTRY_ROW(row);
    }
    if (!found_learning_switch || !found_learning_threshold) return FALSE;
    gboolean found_dependency = FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        gint32 enabling = g_array_index(configuration.enabled_by_fields, gint32, i);
        if (enabling == -1 && gtk_widget_get_sensitive(g_ptr_array_index(configuration.rows, i)))
            return FALSE;
        if (enabling <= 0) continue;
        found_dependency = TRUE;
        AdwSwitchRow *control = ADW_SWITCH_ROW(g_ptr_array_index(configuration.rows, enabling - 1));
        GtkWidget *dependent = g_ptr_array_index(configuration.rows, i);
        gboolean saved = adw_switch_row_get_active(control);
        const gboolean is_switch = ADW_IS_SWITCH_ROW(dependent), is_choice = ADW_IS_COMBO_ROW(dependent);
        if (!is_switch && !is_choice && !GTK_IS_EDITABLE(dependent)) return FALSE;
        const gboolean saved_switch = is_switch && adw_switch_row_get_active(ADW_SWITCH_ROW(dependent));
        const guint saved_choice = is_choice ? adw_combo_row_get_selected(ADW_COMBO_ROW(dependent)) : 0;
        gchar *text = !is_switch && !is_choice ? g_strdup(gtk_editable_get_text(GTK_EDITABLE(dependent))) : NULL;
        adw_switch_row_set_active(control, FALSE);
        gboolean disabled = !gtk_widget_get_sensitive(dependent);
        adw_switch_row_set_active(control, TRUE);
        gboolean enabled = gtk_widget_get_sensitive(dependent);
        gboolean retained = is_switch ? saved_switch == adw_switch_row_get_active(ADW_SWITCH_ROW(dependent)) :
            is_choice ? saved_choice == adw_combo_row_get_selected(ADW_COMBO_ROW(dependent)) :
            g_strcmp0(text, gtk_editable_get_text(GTK_EDITABLE(dependent))) == 0;
        adw_switch_row_set_active(control, saved);
        g_free(text);
        if (!disabled || !enabled || !retained) {
            g_printerr("Configuration self-test: dependency for field %u lost availability or its value.\n", i);
            return FALSE;
        }
    }
    if (!found_dependency) return FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (g_array_index(configuration.overlay_settings, gboolean, i) &&
            gtk_widget_get_visible(g_ptr_array_index(configuration.rows, i)) != jsti_hud_overlay_supported())
            return FALSE;
        if (g_array_index(configuration.hands_free_settings, gboolean, i)) {
            GtkWidget *row = g_ptr_array_index(configuration.rows, i);
            gboolean enabled = adw_switch_row_get_active(ADW_SWITCH_ROW(row));
            if (gtk_widget_get_sensitive(row) != (jsti_window_hands_free_guard_ready() != 0 || enabled))
                return FALSE;
            configuration_hands_free_availability(row, TRUE);
            if (!gtk_widget_get_sensitive(row)) return FALSE;
            configuration_hands_free_availability(row, FALSE);
            if (gtk_widget_get_sensitive(row) != (jsti_window_hands_free_guard_ready() != 0)) return FALSE;
            configuration_hands_free_availability(row, enabled);
        }
    }
    JSTIConfigurationCallback callback = configuration.callback;
    void *context = configuration.context;
    /* Row ordering mirrors DesktopConfiguration.fields, which can insert
     * non-editable rows (e.g. visual density) ahead of the locale entry row;
     * find the real AdwEntryRow rather than assuming it is always row 0. */
    guint language_index = configuration.rows->len;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (ADW_IS_ENTRY_ROW(g_ptr_array_index(configuration.rows, i))) { language_index = i; break; }
    }
    if (language_index >= configuration.rows->len) return FALSE;
    AdwEntryRow *language = ADW_ENTRY_ROW(g_ptr_array_index(configuration.rows, language_index));
    gchar *saved = g_strdup(gtk_editable_get_text(GTK_EDITABLE(language)));
    ConfigurationSelfTestContext test_context = {
        .calls = 0, .language_index = language_index, .empty_choice_index = G_MAXUINT
    };
    AdwComboRow *choice_row = NULL;
    guint optional_choice_count = 0;
    GArray *original_choices = g_array_new(FALSE, FALSE, sizeof(guint));
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] == '\0') continue;
        choice_row = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i));
        const char *choices = g_ptr_array_index(configuration.choices, i);
        if (choices[0] == '\t') ++optional_choice_count;
        guint count = g_list_model_get_n_items(adw_combo_row_get_model(choice_row));
        gchar **lines = g_strsplit(choices, "\n", -1);
        const guint expected_count = g_strv_length(lines);
        g_strfreev(lines);
        if (count < 2 || count != expected_count) {
            g_printerr("Configuration self-test: field %u has %u choices; expected %u.\n", i, count, expected_count);
            g_array_unref(original_choices); return FALSE;
        }
        guint original_choice = adw_combo_row_get_selected(choice_row);
        g_array_append_val(original_choices, original_choice);
        adw_combo_row_set_selected(choice_row, 1);
    }
    if (choice_row == NULL) { g_array_unref(original_choices); return FALSE; }
    configuration.callback = configuration_test_callback;
    configuration.context = &test_context;
    gtk_editable_set_text(GTK_EDITABLE(language), "fr_FR");
    gchar *saved_title = g_strdup(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(language)));
    gchar gemini_title[] = "Gemini voice language";
    ConfigurationTitleUpdate title_update = { .index = language_index, .title = gemini_title };
    configuration_title_apply(&title_update);
    const gboolean title_preserved =
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(language)), gemini_title) == 0 &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0 &&
        jsti_window_set_configuration_field_title(JSTI_MAXIMUM_CONFIGURATION_FIELDS, "Invalid") < 0 &&
        jsti_window_set_configuration_field_title(language_index, NULL) < 0 &&
        jsti_window_set_configuration_field_title(language_index, "") < 0 &&
        jsti_window_set_configuration_field_enabled(JSTI_MAXIMUM_CONFIGURATION_FIELDS, 1) < 0 &&
        jsti_window_set_configuration_field_enabled(language_index, 2) < 0;
    ConfigurationAvailabilityUpdate availability = { .index = language_index, .enabled = FALSE };
    configuration_availability_apply(&availability);
    gboolean availability_preserved = !gtk_widget_get_sensitive(GTK_WIDGET(language)) &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0;
    availability.enabled = TRUE; configuration_availability_apply(&availability);
    availability_preserved = availability_preserved && gtk_widget_get_sensitive(GTK_WIDGET(language)) &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0;
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(language), saved_title);
    g_free(saved_title);
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] != '\t') continue;
        AdwComboRow *optional_choice_row = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i));
        test_context.empty_choice_index = i;
        adw_combo_row_set_selected(optional_choice_row, 0);
        on_configuration_apply(NULL, NULL);
        adw_combo_row_set_selected(optional_choice_row, 1);
        test_context.empty_choice_index = G_MAXUINT;
    }
    on_configuration_apply(NULL, NULL);
    on_configuration_apply(NULL, GINT_TO_POINTER(4));
    on_configuration_apply(NULL, GINT_TO_POINTER(5));
    GListModel *saved_model = adw_combo_row_get_model(configuration.recovery_row);
    g_object_ref(saved_model);
    guint saved_count = configuration.recovery_count;
    guint saved_selection = adw_combo_row_get_selected(configuration.recovery_row);
    const char *edits[] = {"First recoverable edit", "Second recoverable edit", NULL};
    GtkStringList *recovered = gtk_string_list_new(edits);
    adw_combo_row_set_model(configuration.recovery_row, G_LIST_MODEL(recovered));
    g_object_unref(recovered);
    configuration.recovery_count = 2;
    adw_combo_row_set_selected(configuration.recovery_row, 1);
    on_configuration_apply(NULL, GINT_TO_POINTER(3));
    adw_combo_row_set_model(configuration.recovery_row, saved_model);
    adw_combo_row_set_selected(configuration.recovery_row, saved_selection);
    configuration.recovery_count = saved_count;
    guint choice_index = 0;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] == '\0') continue;
        adw_combo_row_set_selected(ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i)),
            g_array_index(original_choices, guint, choice_index++));
    }
    g_array_unref(original_choices);
    g_object_unref(saved_model);
    gtk_editable_set_text(GTK_EDITABLE(language), saved);
    g_free(saved);
    configuration.callback = callback;
    configuration.context = context;
    if (test_context.calls != optional_choice_count + 4 || !title_preserved || !availability_preserved) {
        g_printerr("Configuration self-test: calls %u/%u, title %d, availability %d.\n",
            test_context.calls, optional_choice_count + 4, title_preserved, availability_preserved);
        return FALSE;
    }
    if (!configuration_auto_clean_self_test()) {
        g_printerr("Configuration self-test: Auto-Clean Apply did not preserve all fields.\n");
        return FALSE;
    }
    if (!configuration_warm_approval_self_test()) {
        g_printerr("Configuration self-test: session warm-up approval did not preserve intent and consent.\n");
        return FALSE;
    }
    return TRUE;
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
    GPtrArray *identifiers;
    GArray *favorite_ranks;
    JSTIVoicePickerCallback callback;
    void *context;
} Voices;

static void voices_free(gpointer pointer) {
    Voices *voices = pointer;
    g_ptr_array_unref(voices->names);
    if (voices->identifiers != NULL) g_ptr_array_unref(voices->identifiers);
    if (voices->favorite_ranks != NULL) g_array_unref(voices->favorite_ranks);
    g_free(voices);
}

static void voices_apply(gpointer pointer) {
    Voices *voices = pointer;
    guint old = adw_combo_row_get_selected(read_aloud.voice_row);
    const char *previous = read_aloud.identifiers != NULL && old < read_aloud.identifiers->len
        ? g_ptr_array_index(read_aloud.identifiers, old) : NULL;
    const char *next = voices->identifiers != NULL && voices->selected >= 0 &&
        (guint)voices->selected < voices->identifiers->len
        ? g_ptr_array_index(voices->identifiers, (guint)voices->selected) : NULL;
    if (previous == NULL || next == NULL || g_strcmp0(previous, next) != 0) {
        jsti_voice_credentials_selection_changed();
    }
    ui.suppress = TRUE;
    if (read_aloud.identifiers != NULL) g_ptr_array_unref(read_aloud.identifiers);
    if (read_aloud.favorite_ranks != NULL) g_array_unref(read_aloud.favorite_ranks);
    if (read_aloud.favorite_indices != NULL) g_array_unref(read_aloud.favorite_indices);
    read_aloud.identifiers = voices->identifiers != NULL ? g_ptr_array_ref(voices->identifiers) : NULL;
    read_aloud.favorite_ranks = voices->favorite_ranks != NULL ? g_array_ref(voices->favorite_ranks) : NULL;
    read_aloud.picker_callback = voices->callback;
    read_aloud.picker_context = voices->context;
    read_aloud.favorite_indices = g_array_new(FALSE, FALSE, sizeof(guint));
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices));
    g_ptr_array_add(voices->names, NULL);
    gtk_string_list_splice(read_aloud.voices, 0, existing, (const char *const *)voices->names->pdata);
    g_ptr_array_set_size(voices->names, voices->names->len - 1);
    if (voices->selected >= 0 && (guint)voices->selected < voices->names->len) {
        adw_combo_row_set_selected(read_aloud.voice_row, (guint)voices->selected);
    }
    gtk_string_list_splice(read_aloud.favorite_names, 0,
        g_list_model_get_n_items(G_LIST_MODEL(read_aloud.favorite_names)), NULL);
    guint favorite_selected = GTK_INVALID_LIST_POSITION;
    for (guint rank = 0; rank < voices->names->len && voices->favorite_ranks != NULL; ++rank) {
        for (guint index = 0; index < voices->names->len; ++index) {
            if (g_array_index(voices->favorite_ranks, gint32, index) != (gint32)rank) continue;
            if ((gint32)index == voices->selected) favorite_selected = read_aloud.favorite_indices->len;
            g_array_append_val(read_aloud.favorite_indices, index);
            gtk_string_list_append(read_aloud.favorite_names, g_ptr_array_index(voices->names, index));
        }
    }
    gboolean has_favorites = read_aloud.favorite_indices->len > 0;
    if (!has_favorites) gtk_string_list_append(read_aloud.favorite_names, "No available favorites - add a voice below");
    adw_combo_row_set_selected(read_aloud.favorite_row, favorite_selected);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_row), has_favorites);
    gboolean executable = next != NULL && *next != '\0';
    read_aloud.favorite_executable = executable && voices->callback != NULL;
    read_aloud.favorite_pending = FALSE;
    gboolean favorite = executable &&
        g_array_index(voices->favorite_ranks, gint32, voices->selected) >= 0;
    gtk_button_set_label(read_aloud.favorite_button, favorite ? "Remove from favorites" : "Add to favorites");
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), executable && voices->callback != NULL);
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_voice_picker(const char *const *names, const char *const *ids,
    const int32_t *favorite_ranks, size_t count, int32_t selected,
    JSTIVoicePickerCallback callback, void *context) {
    if (names == NULL || ids == NULL || favorite_ranks == NULL || callback == NULL ||
        count == 0 || count > 1024 || selected < 0 || (size_t)selected >= count) return -1;
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    voices->identifiers = g_ptr_array_new_with_free_func(g_free);
    voices->favorite_ranks = g_array_new(FALSE, FALSE, sizeof(gint32));
    for (size_t index = 0; index < count; ++index) {
        if (names[index] == NULL || ids[index] == NULL || !g_utf8_validate(names[index], -1, NULL) ||
            !g_utf8_validate(ids[index], -1, NULL) || strlen(names[index]) > 1024 || strlen(ids[index]) > 260 ||
            favorite_ranks[index] < -1 || favorite_ranks[index] >= (gint32)count ||
            (*ids[index] == '\0' && favorite_ranks[index] != -1)) {
            voices_free(voices); return -1;
        }
        for (size_t prior = 0; prior < index; ++prior) {
            if (strcmp(ids[prior], ids[index]) == 0 ||
                (favorite_ranks[index] >= 0 && favorite_ranks[prior] == favorite_ranks[index])) {
                voices_free(voices); return -1;
            }
        }
        g_ptr_array_add(voices->names, g_strdup(names[index]));
        g_ptr_array_add(voices->identifiers, g_strdup(ids[index]));
        g_array_append_val(voices->favorite_ranks, favorite_ranks[index]);
    }
    voices->selected = selected;
    voices->callback = callback;
    voices->context = context;
    return post(voices_apply, voices, voices_free);
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
    JSTIVoicePickerCallback picker_callback = read_aloud.picker_callback;
    read_aloud.picker_callback = NULL;
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
    read_aloud.picker_callback = picker_callback;
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

static struct { gint action; guint calls; gchar *identifier; } favorite_observed;
static void observe_favorite(gint32 action, const char *identifier, void *context) {
    (void)context;
    favorite_observed.action = action;
    ++favorite_observed.calls;
    g_free(favorite_observed.identifier);
    favorite_observed.identifier = g_strdup(identifier);
}

static int32_t voice_favorites_self_test(char *error, size_t capacity) {
    Voices original = {0};
    original.names = g_ptr_array_new_with_free_func(g_free);
    for (guint index = 0; index < g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)); ++index) {
        g_ptr_array_add(original.names, g_strdup(gtk_string_list_get_string(read_aloud.voices, index)));
    }
    original.selected = (gint32)adw_combo_row_get_selected(read_aloud.voice_row);
    original.identifiers = read_aloud.identifiers != NULL ? g_ptr_array_ref(read_aloud.identifiers) : NULL;
    original.favorite_ranks = read_aloud.favorite_ranks != NULL ? g_array_ref(read_aloud.favorite_ranks) : NULL;
    original.callback = read_aloud.picker_callback;
    original.context = read_aloud.picker_context;
    Voices fixture = {0};
    fixture.names = g_ptr_array_new_with_free_func(g_free);
    fixture.identifiers = g_ptr_array_new_with_free_func(g_free);
    fixture.favorite_ranks = g_array_new(FALSE, FALSE, sizeof(gint32));
    fixture.selected = 0;
    fixture.callback = observe_favorite;
    const gchar *ids[] = {"synthetic/alpha", "synthetic/beta", ""};
    const gchar *names[] = {"Alpha voice", "Beta voice", "Unavailable stored voice"};
    for (guint index = 0; index < 3; ++index) {
        gint32 rank = index == 1 ? 0 : -1;
        g_ptr_array_add(fixture.names, g_strdup(names[index]));
        g_ptr_array_add(fixture.identifiers, g_strdup(ids[index]));
        g_array_append_val(fixture.favorite_ranks, rank);
    }
    favorite_observed.calls = 0;
    voices_apply(&fixture);
    gboolean okay = favorite_observed.calls == 0 && read_aloud.favorite_indices->len == 1 &&
        g_array_index(read_aloud.favorite_indices, guint, 0) == 1;
    adw_combo_row_set_selected(read_aloud.favorite_row, 0);
    okay = okay && favorite_observed.calls == 1 && favorite_observed.action == 0 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    /* A host acknowledgement, not an optimistic UI write, updates button state. */
    fixture.selected = 1;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud.favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 2 && favorite_observed.action == 2 &&
        g_strcmp0(favorite_observed.identifier, ids[1]) == 0;
    fixture.selected = 0;
    voices_apply(&fixture);
    g_signal_emit_by_name(read_aloud.favorite_button, "clicked");
    okay = okay && favorite_observed.calls == 3 && favorite_observed.action == 1 &&
        g_strcmp0(favorite_observed.identifier, ids[0]) == 0;
    fixture.selected = 2;
    g_array_index(fixture.favorite_ranks, gint32, 1) = -1;
    voices_apply(&fixture);
    okay = okay && !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.favorite_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(read_aloud.favorite_button)) && favorite_observed.calls == 3;
    voices_apply(&original);
    g_ptr_array_unref(original.names);
    if (original.identifiers != NULL) g_ptr_array_unref(original.identifiers);
    if (original.favorite_ranks != NULL) g_array_unref(original.favorite_ranks);
    g_ptr_array_unref(fixture.names);
    g_ptr_array_unref(fixture.identifiers);
    g_array_unref(fixture.favorite_ranks);
    g_clear_pointer(&favorite_observed.identifier, g_free);
    return okay ? 0 : fail(error, capacity, "Favorite voices lost identity, empty state, or add/remove routing");
}

/* Launch at login shows what the host reports, is fixed while the system
 * decides it, and reports the user's switch once, then waits for the answer. */
static int32_t login_item_self_test(char *error, size_t capacity) {
    LoginItem blocked = { .state = 2, .detail = (gchar *)"Turned off in Settings." };
    login_item_apply(&blocked);
    if (adw_switch_row_get_active(ui.login_row) || gtk_widget_get_sensitive(GTK_WIDGET(ui.login_row))
        || g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(ui.login_row)), blocked.detail) != 0) {
        return fail(error, capacity, "Launch at login did not show a state the system decides");
    }
    LoginItem off = { .state = 0, .detail = (gchar *)"Start minimised." };
    login_item_apply(&off);
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    adw_switch_row_set_active(ui.login_row, TRUE);
    gboolean reported = observed.event == JSTI_EVENT_LOGIN_ITEM && observed.index == 1;
    gboolean waiting = !gtk_widget_get_sensitive(GTK_WIDGET(ui.login_row));
    observed.event = 0;
    LoginItem on = { .state = 1, .detail = (gchar *)"Start minimised." };
    login_item_apply(&on);
    gboolean quiet = observed.event == 0;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    if (!reported || !waiting) return fail(error, capacity, "Launch at login did not report the switch");
    if (!quiet || !adw_switch_row_get_active(ui.login_row) || !gtk_widget_get_sensitive(GTK_WIDGET(ui.login_row))) {
        return fail(error, capacity, "Launch at login did not show the state reached");
    }
    login_item_apply(&off);
    return 0;
}

static void text_output_capture(int32_t event, const char *text, int32_t index, void *context) {
    gchar *expected = ui.app_switch_configured
        ? g_strdup_printf("restore\t%u", adw_combo_row_get_selected(ui.app_switch_row)) : g_strdup("restore");
    if (event == JSTI_EVENT_TEXT_OUTPUT && index == 1 && g_strcmp0(text, expected) == 0)
        ++*(guint *)context;
    g_free(expected);
}

static int32_t automation_self_test(char *error, size_t capacity) {
    LoginItem off = { .state = 0, .detail = (gchar *)"Imported request pending local consent." };
    automation_apply(&off);
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    adw_switch_row_set_active(ui.automation_row, TRUE);
    gboolean pending = observed.event == JSTI_EVENT_AUTOMATION && observed.index == 1
        && !gtk_widget_get_sensitive(GTK_WIDGET(ui.automation_row));
    observed.event = 0;
    LoginItem failed = { .state = 0, .detail = (gchar *)"Automation could not start." };
    automation_apply(&failed);
    gboolean actual = observed.event == 0 && !adw_switch_row_get_active(ui.automation_row)
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.automation_row))
        && g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(ui.automation_row)), failed.detail) == 0;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    automation_apply(&off);
    return pending && actual ? 0 : fail(error, capacity, "Automation did not show its actual state or failure");
}

static gboolean app_switch_output_self_test(void) {
    GListModel *model = adw_combo_row_get_model(ui.app_switch_row);
    if (model != NULL) g_object_ref(model);
    guint selection = adw_combo_row_get_selected(ui.app_switch_row);
    gboolean configured = ui.app_switch_configured;
    gchar *title = g_strdup(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(ui.app_switch_row)));
    gchar *help = g_strdup(gtk_label_get_text(ui.app_switch_help));
    TextOutput original = {
        .method = (gint32)adw_combo_row_get_selected(ui.output_row),
        .restore = adw_switch_row_get_active(ui.restore_row), .can_restore = ui.can_restore_clipboard
    };
    TextOutput policy = {
        .method = 0, .restore = TRUE, .can_restore = FALSE,
        .policy_title = (gchar *)"Fixture destination", .policy_labels = (gchar *)"Legacy\nOriginal\nCurrent\nCopy",
        .policy_help = (gchar *)"Wayland copies explicit intent only.", .policy_selection = 2
    };
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    observed.event = 0;
    text_output_apply(&policy);
    gboolean valid = observed.event == 0 && adw_combo_row_get_selected(ui.app_switch_row) == 2 &&
        g_list_model_get_n_items(adw_combo_row_get_model(ui.app_switch_row)) == 4 &&
        gtk_label_get_wrap(ui.app_switch_help) &&
        g_strcmp0(gtk_label_get_text(ui.app_switch_help), policy.policy_help) == 0;
    adw_combo_row_set_selected(ui.app_switch_row, 3);
    valid = valid && observed.event == JSTI_EVENT_TEXT_OUTPUT && observed.index == 0 &&
        g_strcmp0(observed.text, "restore\t3") == 0;
    policy.method = 1;
    policy.policy_selection = 3;
    observed.event = 0;
    text_output_apply(&policy);
    valid = valid && observed.event == 0 && !gtk_widget_get_sensitive(GTK_WIDGET(ui.app_switch_row)) &&
        adw_combo_row_get_selected(ui.app_switch_row) == 3;
    ui.suppress = TRUE;
    adw_combo_row_set_model(ui.app_switch_row, model);
    if (model != NULL) g_object_unref(model);
    adw_combo_row_set_selected(ui.app_switch_row, selection);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(ui.app_switch_row), title);
    gtk_label_set_text(ui.app_switch_help, help);
    ui.app_switch_configured = configured;
    ui.suppress = FALSE;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    g_free(title);
    g_free(help);
    text_output_apply(&original);
    return valid;
}

static gboolean text_output_self_test(void) {
    guint original_policy = adw_combo_row_get_selected(ui.app_switch_row);
    if (ui.app_switch_configured) {
        ui.suppress = TRUE;
        adw_combo_row_set_selected(ui.app_switch_row, 0);
        ui.suppress = FALSE;
    }
    TextOutput original = {
        .method = (gint32)adw_combo_row_get_selected(ui.output_row),
        .restore = adw_switch_row_get_active(ui.restore_row),
        .can_restore = ui.can_restore_clipboard,
        .hint = g_strdup(adw_action_row_get_subtitle(ui.shortcut_row))
    };
    TextOutput unsupported = { .method = 0, .restore = TRUE, .can_restore = FALSE };
    text_output_apply(&unsupported);
    gboolean valid = !gtk_widget_get_visible(GTK_WIDGET(ui.restore_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.restore_row)) && adw_switch_row_get_active(ui.restore_row) &&
        gtk_widget_get_visible(GTK_WIDGET(ui.output_group)) &&
        strstr(adw_preferences_group_get_description(ui.output_group), "Wayland") != NULL &&
        strstr(gtk_label_get_text(ui.setup_output), "restored") == NULL;
    guint calls = 0;
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    ui.callback = text_output_capture;
    ui.context = &calls;
    adw_combo_row_set_selected(ui.output_row, 1);
    valid = valid && calls == 1 && adw_switch_row_get_active(ui.restore_row);
    ui.callback = callback;
    ui.context = context;
    TextOutput supported = { .method = 0, .restore = TRUE, .can_restore = TRUE };
    text_output_apply(&supported);
    valid = valid && gtk_widget_get_visible(GTK_WIDGET(ui.restore_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(ui.restore_row)) &&
        strstr(gtk_label_get_text(ui.setup_output), "restored") != NULL;
    supported.method = 1;
    text_output_apply(&supported);
    valid = valid && !gtk_widget_get_sensitive(GTK_WIDGET(ui.restore_row)) &&
        adw_switch_row_get_active(ui.restore_row) && strstr(gtk_label_get_text(ui.setup_output), "restored") == NULL;
    text_output_apply(&original);
    gboolean policy_valid = app_switch_output_self_test();
    if (ui.app_switch_configured) {
        ui.suppress = TRUE;
        adw_combo_row_set_selected(ui.app_switch_row, original_policy);
        ui.suppress = FALSE;
        text_output_apply(&original);
    }
    g_free(original.hint);
    return valid && policy_valid;
}

static gboolean sidebar_navigation_self_test(void) {
    SidebarUpdate saved = { 0 }, fixture = { 0 };
    const gint original_page = ui.page;
    const gboolean configured = sidebar_shortcuts.configured;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        saved.digits[page] = sidebar_shortcuts.digits[page];
        saved.hints[page] = g_strdup(gtk_label_get_text(GTK_LABEL(sidebar_shortcuts.hints[page])));
        fixture.digits[page] = -1;
    }
    saved.show_hints = gtk_widget_get_visible(sidebar_shortcuts.hints[JSTI_PAGE_DASHBOARD]);
    fixture.digits[JSTI_PAGE_DASHBOARD] = 1;
    fixture.hints[JSTI_PAGE_DASHBOARD] = (gchar *)"Ctrl+1";
    fixture.digits[JSTI_PAGE_PROFILES] = 9;
    fixture.hints[JSTI_PAGE_PROFILES] = (gchar *)"Ctrl+9";
    fixture.show_hints = TRUE;
    sidebar_update_apply(&fixture);
    GtkWidget *hint = sidebar_shortcuts.hints[JSTI_PAGE_DASHBOARD];
    gboolean okay = gtk_widget_get_visible(hint) &&
        g_strcmp0(gtk_label_get_text(GTK_LABEL(hint)), "Ctrl+1") == 0;
    show_page(JSTI_PAGE_HISTORY);
    okay = okay && sidebar_navigate(GDK_KEY_9, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_PROFILES;
    show_page(JSTI_PAGE_HISTORY);
    const GdkModifierType blocked[] = { 0, GDK_CONTROL_MASK | GDK_SHIFT_MASK, GDK_CONTROL_MASK | GDK_ALT_MASK,
                                       GDK_CONTROL_MASK | GDK_SUPER_MASK };
    for (guint i = 0; i < G_N_ELEMENTS(blocked); ++i)
        okay = okay && !sidebar_navigate(GDK_KEY_1, blocked[i], NULL) && ui.page == JSTI_PAGE_HISTORY;
    GtkWidget *entry = gtk_entry_new();
    g_object_ref_sink(entry);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, entry) && ui.page == JSTI_PAGE_HISTORY;
    g_object_unref(entry);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, GTK_WIDGET(ui.transcript));
    GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, JSTI_PAGE_DASHBOARD));
    gtk_widget_set_sensitive(row, FALSE);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_HISTORY;
    gtk_widget_set_sensitive(row, TRUE);
    fixture.show_hints = FALSE;
    sidebar_update_apply(&fixture);
    okay = okay && !gtk_widget_get_visible(hint) &&
        sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_DASHBOARD;
    const JSTISidebarShortcut invalid[] = { { "dashboard", 1, "Ctrl+1" }, { "history", 1, "Ctrl+1" } };
    okay = okay && jsti_window_set_sidebar_shortcuts(invalid, 2, 1) == -1;
    sidebar_update_apply(&saved);
    sidebar_shortcuts.configured = configured;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) g_free(saved.hints[page]);
    show_page(original_page);
    return okay;
}

typedef struct ActionShortcutCapture {
    gint32 event, slot;
    guint calls;
} ActionShortcutCapture;

static void action_shortcut_capture(gint32 event, const char *text, gint32 slot, void *context) {
    (void)text;
    ActionShortcutCapture *capture = context;
    capture->event = event;
    capture->slot = slot;
    ++capture->calls;
}

static gboolean action_execution_self_test(void) {
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint original_page = ui.page, original_state = ui.state;
    gboolean window_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gboolean record_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.record));
    gboolean stop_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.voice_stop));
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    gboolean okay = TRUE;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page)
        okay = okay && action_shortcut_run(2, page_info[page].name, 0) && ui.page == page;
    GtkWidget *history = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, JSTI_PAGE_HISTORY));
    gboolean history_sensitive = gtk_widget_get_sensitive(history);
    gtk_widget_set_sensitive(history, FALSE);
    okay = okay && !action_shortcut_run(2, "history", 0);
    gtk_widget_set_sensitive(history, history_sensitive);
    capture.calls = 0;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), TRUE);
    okay = okay && action_shortcut_run(1, "", 0) && capture.calls == 1 &&
        capture.event == JSTI_EVENT_TOGGLE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), FALSE);
    okay = okay && !action_shortcut_run(1, "", 0) && capture.calls == 1;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), TRUE);
    okay = okay && action_shortcut_run(3, "", 0) && capture.calls == 2 &&
        capture.event == JSTI_EVENT_PLAYBACK_STOP;
    ui.state = JSTI_STATE_IDLE;
    for (gint slot = 1; slot <= 3; ++slot)
        okay = okay && action_shortcut_run(6, "", slot) && capture.event == JSTI_EVENT_QUICK_VOICE &&
            capture.slot == slot && capture.calls == (guint)(2 + slot);
    okay = okay && !action_shortcut_run(6, "", 0) && !action_shortcut_run(6, "", 4);
    okay = okay && action_shortcut_run(7, "", 0) && capture.event == JSTI_EVENT_SPEAK_CLIPBOARD &&
        capture.slot == 0 && capture.calls == 6;
    okay = okay && action_shortcut_run(8, "", 0) && capture.event == JSTI_EVENT_SPEECH_PAUSE &&
        capture.slot == 0 && capture.calls == 7;
    okay = okay && action_shortcut_run(9, "", 0) && capture.event == JSTI_EVENT_API_KEYS &&
        capture.slot == 0 && capture.calls == 8;
    okay = okay && action_shortcut_run(10, "", 0) && capture.event == JSTI_EVENT_PERMISSIONS &&
        capture.slot == 0 && capture.calls == 9;
    gint paste_page = ui.page;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), FALSE);
    gtk_widget_set_sensitive(history, FALSE);
    okay = okay && action_shortcut_run(11, "", 0) && capture.event == JSTI_EVENT_PASTE_LAST_HISTORY &&
        capture.slot == 0 && capture.calls == 10 && ui.page == paste_page;
    gtk_widget_set_sensitive(history, history_sensitive);
    okay = okay && !action_shortcut_run(12, "", 0) && capture.calls == 10;
    ui.state = JSTI_STATE_WORKING;
    okay = okay && !action_shortcut_run(6, "", 1) && !action_shortcut_run(5, "", 0) &&
        !action_shortcut_run(7, "", 0) && !action_shortcut_run(8, "", 0) &&
        !action_shortcut_run(9, "", 0) && !action_shortcut_run(11, "", 0) && capture.calls == 10;
    ui.state = JSTI_STATE_RECORDING;
    okay = okay && !action_shortcut_run(11, "", 0) && capture.calls == 10;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    ui.state = JSTI_STATE_IDLE;
    okay = okay && !action_shortcut_run(4, "", 0) && !action_shortcut_run(2, "about", 0) &&
        !action_shortcut_run(7, "", 0) && !action_shortcut_run(8, "", 0) &&
        !action_shortcut_run(9, "", 0) && !action_shortcut_run(10, "", 0) &&
        !action_shortcut_run(11, "", 0) && capture.calls == 10;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), window_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.record), record_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), stop_sensitive);
    ui.state = original_state;
    show_page(original_page);
    ui.callback = callback;
    ui.context = context;
    return okay;
}

static gboolean command_forwarding_self_test(void) {
    WindowCommand command;
    const gchar *background[] = { "justspeaktoit", JSTI_LOGIN_LAUNCH_ARGUMENT };
    const gchar *toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT };
    const gchar *clipboard[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *paste[] = { "justspeaktoit", JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT };
    const gchar *mixed[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *mixed_output[] = { "justspeaktoit", JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *unknown[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service" };
    const struct { const gchar *argument; gint run, slot, event; } controls[] = {
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, 12, 0, JSTI_EVENT_SPEAK_SELECTED_TEXT },
        { JSTI_STOP_SPEECH_ARGUMENT, 3, 0, JSTI_EVENT_PLAYBACK_STOP },
        { JSTI_PAUSE_SPEECH_ARGUMENT, 8, 0, JSTI_EVENT_SPEECH_PAUSE },
        { JSTI_QUICK_VOICE_1_ARGUMENT, 6, 1, JSTI_EVENT_QUICK_VOICE },
        { JSTI_QUICK_VOICE_2_ARGUMENT, 6, 2, JSTI_EVENT_QUICK_VOICE },
        { JSTI_QUICK_VOICE_3_ARGUMENT, 6, 3, JSTI_EVENT_QUICK_VOICE }
    };
    gboolean okay = parse_window_command(2, background, &command) && command.run == 0 && command.background;
    okay = okay && parse_window_command(3, toggle, &command) && command.run == 1 && command.background;
    okay = okay && parse_window_command(2, clipboard, &command) && command.run == 7 && !command.background;
    okay = okay && parse_window_command(3, paste, &command) && command.run == 11;
    okay = okay && !parse_window_command(3, mixed, &command) && !parse_window_command(3, mixed_output, &command);
    okay = okay && parse_window_command(3, unknown, &command) && command.unknown_argument;
    const gchar *toggle_unknown[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, "--typo" };
    okay = okay && parse_window_command(3, toggle_unknown, &command) && command.run == 1 &&
        command.unknown_argument && !parse_action_command(3, toggle_unknown, &command) &&
        parse_action_command(3, toggle, &command) && command.run == 1 && command.background &&
        !parse_action_command(2, background, &command) && !parse_action_command(0, NULL, &command);
    for (guint index = 0; index < G_N_ELEMENTS(controls); ++index) {
        const gchar *arguments[] = { "justspeaktoit", controls[index].argument };
        okay = okay && parse_window_command(2, arguments, &command) &&
            command.run == controls[index].run && command.slot == controls[index].slot &&
            is_forwardable_command(command.run, command.slot);
    }
    const gchar *mixed_slots[] = { "justspeaktoit", JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_2_ARGUMENT };
    okay = okay && !parse_window_command(3, mixed_slots, &command) && !is_forwardable_command(6, 0) &&
        !is_forwardable_command(6, 4) && !is_forwardable_command(1, 0) && !is_forwardable_command(3, 1);
    char *invalid[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service", NULL };
    char error[256] = { 0 };
    char *valid_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT, NULL };
    char *repeated_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_TOGGLE_ARGUMENT, NULL };
    char *invalid_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, "--gapplication-service", NULL };
    okay = okay && jsti_window_validate_action_command(3, valid_toggle, error, sizeof(error)) == 0 &&
        jsti_window_validate_action_command(3, repeated_toggle, error, sizeof(error)) == 0 &&
        jsti_window_validate_action_command(3, invalid_toggle, error, sizeof(error)) == -1 && error[0] != '\0';
    okay = okay && jsti_window_forward_action(
        "com.justspeaktoit.JustSpeakToIt", 3, invalid, error, sizeof(error)) == -1 && error[0] != '\0';
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint state = ui.state, page = ui.page;
    gboolean sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window)), closing = ui.closing;
    gboolean stop_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.voice_stop));
    GtkWindow *window = ui.window;
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    ui.state = JSTI_STATE_IDLE;
    ui.closing = FALSE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    okay = okay && forward_window_command(7, 0, TRUE) == 0 && capture.event == JSTI_EVENT_SPEAK_CLIPBOARD &&
        capture.calls == 1 && ui.page == page;
    okay = okay && forward_window_command(11, 0, TRUE) == 0 && capture.event == JSTI_EVENT_PASTE_LAST_HISTORY &&
        capture.calls == 2 && ui.page == page;
    okay = okay && forward_window_command(7, 0, FALSE) == 2 && forward_window_command(11, 0, FALSE) == 2;
    ui.window = NULL;
    okay = okay && forward_window_command(7, 0, TRUE) == 2 && forward_window_command(11, 0, TRUE) == 2;
    ui.window = window;
    ui.state = JSTI_STATE_WORKING;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    ui.state = JSTI_STATE_RECORDING;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    ui.state = JSTI_STATE_IDLE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.closing = TRUE;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3 &&
        capture.calls == 2;
    ui.closing = FALSE;
    ui.state = JSTI_STATE_IDLE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), TRUE);
    for (guint index = 0; index < G_N_ELEMENTS(controls); ++index) {
        capture = (ActionShortcutCapture){ 0 };
        gint run = controls[index].run, slot = controls[index].slot;
        okay = okay && forward_window_command(run, slot, TRUE) == 0 &&
            capture.calls == 1 && capture.event == controls[index].event &&
            capture.slot == slot && ui.page == page && forward_window_command(run, slot, FALSE) == 2;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
        okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
        ui.closing = TRUE;
        okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
        ui.closing = FALSE;
        if (run != 3) {
            ui.state = JSTI_STATE_WORKING;
            okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
            ui.state = JSTI_STATE_RECORDING;
            okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
            ui.state = JSTI_STATE_IDLE;
        }
    }
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), FALSE);
    okay = okay && forward_window_command(3, 0, TRUE) == 3;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), stop_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    ui.closing = closing;
    ui.state = state;
    ui.callback = callback;
    ui.context = context;
    return okay;
}

typedef struct CommandProcessResult {
    GMainLoop *loop;
    GSubprocess *child;
    gboolean completed, timed_out;
    gchar *diagnostic;
    GError *failure;
} CommandProcessResult;

static void command_process_finished(GObject *object, GAsyncResult *result, gpointer data) {
    CommandProcessResult *check = data;
    check->completed = g_subprocess_communicate_utf8_finish(
        G_SUBPROCESS(object), result, NULL, &check->diagnostic, &check->failure);
    g_main_loop_quit(check->loop);
}

static gboolean command_process_expired(gpointer data) {
    CommandProcessResult *check = data;
    check->timed_out = TRUE;
    g_subprocess_force_exit(check->child);
    return G_SOURCE_REMOVE;
}

static gboolean check_command_process(
    const gchar *const *arguments, const gchar *directory, gboolean success,
    const gchar *refusal, char *error, size_t capacity
) {
    GSubprocessLauncher *launcher = g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
    g_subprocess_launcher_setenv(launcher, "XDG_DATA_HOME", directory, TRUE);
    CommandProcessResult check = { 0 };
    check.child = g_subprocess_launcher_spawnv(launcher, arguments, &check.failure);
    g_object_unref(launcher);
    if (check.child == NULL) {
        jsti_set_error(error, capacity, "Could not start the command client: %s", check.failure->message);
        g_clear_error(&check.failure);
        return FALSE;
    }
    GMainContext *context = g_main_context_get_thread_default();
    check.loop = g_main_loop_new(context, FALSE);
    GSource *deadline = g_timeout_source_new_seconds(15);
    g_source_set_callback(deadline, command_process_expired, &check, NULL);
    g_source_attach(deadline, context);
    g_subprocess_communicate_utf8_async(check.child, NULL, NULL, command_process_finished, &check);
    g_main_loop_run(check.loop);
    g_source_destroy(deadline);
    g_source_unref(deadline);
    if (!check.completed) {
        g_subprocess_force_exit(check.child);
        g_subprocess_wait(check.child, NULL, NULL);
    }
    gboolean okay = check.completed && !check.timed_out && g_subprocess_get_if_exited(check.child) &&
        g_subprocess_get_successful(check.child) == success &&
        (refusal == NULL || (check.diagnostic != NULL && strstr(check.diagnostic, refusal) != NULL));
    if (!okay) jsti_set_error(error, capacity, "Command %s failed its process contract: %s%s",
        arguments[1], check.timed_out ? "timed out; " : "",
        check.failure != NULL ? check.failure->message :
            (check.diagnostic != NULL ? check.diagnostic : "unexpected process status"));
    g_clear_error(&check.failure);
    g_free(check.diagnostic);
    g_main_loop_unref(check.loop);
    g_object_unref(check.child);
    return okay;
}

static gboolean command_process_self_test(char *error, size_t capacity) {
    /* Opt in only from the harness's private session bus. No provider/Host event
     * is delivered: a private context serves the real handler with a test callback. */
    if (g_strcmp0(g_getenv("JSTI_COMMAND_FORWARDING_CHECK"), "1") != 0) return TRUE;
    if (!(ui.flags & JSTI_WINDOW_SMOKE_TEST)) {
        jsti_set_error(error, capacity, "Command process checks require the isolated smoke-test window.");
        return FALSE;
    }
    GMainContext *context = g_main_context_new();
    g_main_context_push_thread_default(context);
    GApplication *primary = g_application_new(
        "com.justspeaktoit.JustSpeakToIt", G_APPLICATION_HANDLES_COMMAND_LINE);
    g_signal_connect(primary, "command-line", G_CALLBACK(on_command_line), NULL);
    GError *failure = NULL;
    gboolean okay = g_application_register(primary, NULL, &failure);
    if (!okay || g_application_get_is_remote(primary)) {
        jsti_set_error(error, capacity, "Command fixture could not own its private application name: %s",
            failure != NULL ? failure->message : "another instance is running");
        g_clear_error(&failure);
        g_object_unref(primary);
        g_main_context_pop_thread_default(context);
        g_main_context_unref(context);
        return FALSE;
    }
    gchar *executable = g_file_read_link("/proc/self/exe", &failure);
    gchar *directory = executable != NULL ? g_dir_make_tmp("jsti-command-check-XXXXXX", &failure) : NULL;
    if (directory == NULL) {
        jsti_set_error(error, capacity, "Command fixture setup failed: %s", failure->message);
        g_clear_error(&failure);
        g_free(executable);
        g_object_unref(primary);
        g_main_context_pop_thread_default(context);
        g_main_context_unref(context);
        return FALSE;
    }
    jsti_window_event_fn callback = ui.callback;
    void *callback_context = ui.context;
    gint state = ui.state, page = ui.page;
    gboolean closing = ui.closing, sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gboolean visible = gtk_widget_get_visible(GTK_WIDGET(ui.window));
    gboolean stop_enabled = gtk_widget_get_sensitive(GTK_WIDGET(ui.voice_stop));
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    gtk_widget_set_visible(GTK_WIDGET(ui.window), FALSE);
    const struct {
        const gchar *argument, *second;
        gint state, event, slot;
        gboolean sensitive, closing;
        const gchar *refusal;
    } cases[] = {
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_SELECTED_TEXT, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, JSTI_SPEAK_SELECTED_TEXT_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_SELECTED_TEXT, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, "--typo",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_CLIPBOARD, 0, TRUE, FALSE, NULL },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_PASTE_LAST_HISTORY, 0, TRUE, FALSE, NULL },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_PASTE_LAST_HISTORY, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_CLIPBOARD, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_WORKING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_RECORDING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, FALSE, FALSE, "Finish the current operation" },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, TRUE, TRUE, "Finish the current operation" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, "--typo",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, "--gapplication-service",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_WORKING, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_RECORDING, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, FALSE, FALSE, "Playback Stop is unavailable" },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, TRUE, TRUE, "Playback Stop is unavailable" },
        { JSTI_PAUSE_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEECH_PAUSE, 0, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_1_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 1, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_2_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 2, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_3_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 3, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_3_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_QUICK_VOICE_1_ARGUMENT, NULL, JSTI_STATE_WORKING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_PAUSE_SPEECH_ARGUMENT, NULL, JSTI_STATE_RECORDING, 0, 0, TRUE, FALSE, "Finish the current operation" }
    };
    for (guint index = 0; okay && index < G_N_ELEMENTS(cases); ++index) {
        const gchar *arguments[] = { executable, cases[index].argument, cases[index].second, NULL };
        capture = (ActionShortcutCapture){ 0 };
        ui.state = cases[index].state;
        ui.closing = cases[index].closing;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), cases[index].sensitive);
        refresh_actions();
        okay = check_command_process(arguments, directory, cases[index].event != 0, cases[index].refusal, error, capacity);
        if (okay && (capture.calls != (cases[index].event != 0 ? 1u : 0u) ||
            capture.event != cases[index].event || capture.slot != cases[index].slot || ui.page != page ||
            gtk_widget_get_visible(GTK_WIDGET(ui.window)))) {
            jsti_set_error(error, capacity, "Command fixture %u changed page/visibility or emitted the wrong event.", index);
            okay = FALSE;
        }
    }
    g_clear_object(&primary);
    const gchar *cold[] = {
        JSTI_SPEAK_SELECTED_TEXT_ARGUMENT,
        JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_STOP_SPEECH_ARGUMENT,
        JSTI_PAUSE_SPEECH_ARGUMENT, JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_2_ARGUMENT, JSTI_QUICK_VOICE_3_ARGUMENT
    };
    for (guint index = 0; okay && index < G_N_ELEMENTS(cold); ++index) {
        const gchar *arguments[] = { executable, cold[index], NULL };
        okay = check_command_process(arguments, directory, FALSE,
            "Open JustSpeakToIt before using this action command", error, capacity);
    }
    const gchar *cold_invalid[] = { "--typo", "--gapplication-service" };
    for (guint index = 0; okay && index < G_N_ELEMENTS(cold_invalid); ++index) {
        const gchar *arguments[] = { executable, JSTI_TOGGLE_ARGUMENT, cold_invalid[index], NULL };
        okay = check_command_process(arguments, directory, FALSE,
            "Choose exactly one supported desktop action command", error, capacity);
    }
    ui.state = state;
    ui.closing = closing;
    refresh_actions();
    ui.callback = callback;
    ui.context = callback_context;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.voice_stop), stop_enabled);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    gtk_widget_set_visible(GTK_WIDGET(ui.window), visible);
    GDir *contents = g_dir_open(directory, 0, &failure);
    gboolean empty = contents != NULL && g_dir_read_name(contents) == NULL;
    if (contents != NULL) g_dir_close(contents);
    if (!empty) {
        if (okay) jsti_set_error(
            error, capacity, "Command clients created data in %s or the fixture could not inspect it.", directory);
        g_printerr("Retaining command fixture directory for diagnosis: %s\n", directory);
        okay = FALSE;
    }
    g_clear_error(&failure);
    if (empty && g_rmdir(directory) != 0) {
        if (okay) jsti_set_error(error, capacity, "Could not remove the empty command fixture directory.");
        g_printerr("Could not remove command fixture directory: %s\n", directory);
        okay = FALSE;
    }
    g_free(directory);
    g_free(executable);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
    if (okay) g_print("Desktop commands: %u real client processes passed forwarding, refusal and store-isolation checks.\n",
        (guint)(G_N_ELEMENTS(cases) + G_N_ELEMENTS(cold) + G_N_ELEMENTS(cold_invalid)));
    return okay;
}

static gboolean post_processing_self_test(void) {
    if (ui.polish_catalog == NULL || ui.polish_local_notice == NULL) return FALSE;
    guint row = adw_combo_row_get_selected(ui.polish_model_row);
    Polish saved = {
        .models = g_ptr_array_ref(ui.polish_catalog),
        .enabled = adw_switch_row_get_active(ui.polish_row),
        .include_directives = adw_switch_row_get_active(ui.polish_directives_row),
        .include_tags = adw_switch_row_get_active(ui.polish_tags_row),
        .selected = row < ui.polish_slots->len ? g_array_index(ui.polish_slots, gint32, row) : -1,
        .local_index = ui.polish_local_index,
        .remembered_remote_index = ui.polish_remote_selected,
        .local_notice = g_strdup(ui.polish_local_notice),
        .prompt = polish_prompt_text()
    };
    guint saved_location = adw_combo_row_get_selected(ui.polish_location_row);
    guint saved_remote = polish_remote_count;
    gint32 saved_local = ui.polish_local_selected;
    GPtrArray *names = g_ptr_array_new();
    g_ptr_array_add(names, (gpointer)"Remote first");
    g_ptr_array_add(names, (gpointer)"Remote second");
    g_ptr_array_add(names, (gpointer)"Local Cleanup (Offline)");
    Polish fixture = {
        .models = names, .enabled = TRUE, .selected = 1, .local_index = 2,
        .remembered_remote_index = 1,
        .include_directives = FALSE, .include_tags = TRUE,
        .local_notice = (gchar *)"Built-in rules ignore custom instructions. No API key is needed.",
        .prompt = (gchar *)"Keep remote instructions."
    };
    jsti_window_event_fn callback = ui.callback;
    ui.callback = observe_event;
    polish_apply(&fixture);
    gboolean okay = adw_combo_row_get_selected(ui.polish_location_row) == 1 &&
        adw_combo_row_get_selected(ui.polish_model_row) == 1 &&
        g_list_model_get_n_items(G_LIST_MODEL(ui.polish_models)) == 2 &&
        gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_key_row)) &&
        !adw_switch_row_get_active(ui.polish_directives_row) && adw_switch_row_get_active(ui.polish_tags_row) &&
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(ui.polish_directives_row)),
            "Include personal lexicon directives") == 0 &&
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(ui.polish_tags_row)),
            "Include lexicon context tags") == 0;
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "synthetic-key");
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == JSTI_EVENT_POST_PROCESSING && observed.index == 1 &&
        g_strcmp0(observed.text, "Keep%20remote%20instructions.\tsynthetic-key\t0\t1") == 0;
    observed.event = 0;
    adw_combo_row_set_selected(ui.polish_location_row, 0);
    okay = okay && observed.event == 0 &&
        g_list_model_get_n_items(G_LIST_MODEL(ui.polish_models)) == 1 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_key_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_tags_row)) &&
        g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(ui.polish_location_row)), fixture.local_notice) == 0;
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "must-not-reach-callback");
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == 2 &&
        g_strcmp0(observed.text, "Keep%20remote%20instructions.\t\t0\t1") == 0;
    adw_switch_row_set_active(ui.polish_row, FALSE);
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == -3;
    fixture.selected = 2;
    polish_apply(&fixture);
    adw_combo_row_set_selected(ui.polish_location_row, 1);
    row = adw_combo_row_get_selected(ui.polish_model_row);
    okay = okay && row < ui.polish_slots->len && g_array_index(ui.polish_slots, gint32, row) == 1;
    fixture.remembered_remote_index = -1;
    polish_apply(&fixture);
    adw_combo_row_set_selected(ui.polish_location_row, 1);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 &&
        adw_combo_row_get_selected(ui.polish_model_row) == GTK_INVALID_LIST_POSITION;
    fixture.selected = -1;
    polish_apply(&fixture);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 &&
        adw_combo_row_get_selected(ui.polish_model_row) == GTK_INVALID_LIST_POSITION;
    const char *labels[] = {"Remote", "Local"};
    okay = okay && jsti_window_set_post_processing(labels, 2, 1, 0, 2, -1, fixture.local_notice, 1, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 2, 0, 1, -1, fixture.local_notice, 1, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 1, 0, 1, -1, fixture.local_notice, 2, 1, "") == -1 &&
        jsti_window_set_post_processing(labels, 2, 1, 0, 1, 1, fixture.local_notice, 1, 1, "") == -1;
    polish_apply(&saved);
    polish_remote_count = saved_remote;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.polish_location_row, saved_location);
    polish_select_location(saved.selected, FALSE);
    ui.polish_local_selected = saved_local;
    ui.suppress = FALSE;
    ui.callback = callback;
    g_clear_pointer(&observed.text, g_free);
    g_ptr_array_unref(names);
    g_ptr_array_unref(saved.models);
    g_free(saved.local_notice);
    g_free(saved.prompt);
    return okay;
}

static int32_t local_cleanup_sources_self_test(char *error, size_t capacity) {
    if (ui.polish_catalog == NULL || ui.polish_local_notice == NULL)
        return fail(error, capacity, "post-processing was not configured before its source fixture");
    Polish saved = {
        .models = g_ptr_array_ref(ui.polish_catalog),
        .enabled = adw_switch_row_get_active(ui.polish_row),
        .include_directives = adw_switch_row_get_active(ui.polish_directives_row),
        .include_tags = adw_switch_row_get_active(ui.polish_tags_row),
        .selected = polish_selected_model(), .local_index = ui.polish_local_index,
        .remembered_remote_index = ui.polish_remote_selected,
        .local_notice = g_strdup(ui.polish_local_notice), .prompt = polish_prompt_text()
    };
    const guint saved_location = adw_combo_row_get_selected(ui.polish_location_row);
    const guint saved_remote = polish_remote_count;
    const gint32 saved_local = ui.polish_local_selected;
    Polish fixture = {.models = g_ptr_array_new_with_free_func(g_free), .enabled = TRUE,
        .selected = 4, .local_index = 2, .remembered_remote_index = 1,
        .include_directives = FALSE, .include_tags = TRUE,
        .local_notice = "Built-in rules ignore custom instructions and context.",
        .prompt = "One stop after each word.\nExact\tsecond line."};
    const char *names[] = {"Remote A", "Remote B", "Built-in rules", "Local A", "Local B"};
    for (size_t i = 0; i < G_N_ELEMENTS(names); ++i) g_ptr_array_add(fixture.models, g_strdup(names[i]));
    polish_apply(&fixture);
    polish_remote_count = G_MAXUINT;
    cleanup_sources_apply(GUINT_TO_POINTER(2));
    gboolean okay = adw_combo_row_get_selected(ui.polish_location_row) == 0
        && adw_combo_row_get_selected(ui.polish_model_row) == 2 && polish_selected_model() == 4
        && g_list_model_get_n_items(G_LIST_MODEL(ui.polish_models)) == 3
        && !gtk_widget_get_visible(GTK_WIDGET(ui.polish_key_row))
        && gtk_widget_get_visible(polish_local_group)
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_prompt_row))
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_directives_row))
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_tags_row));
    gchar *actual_prompt = polish_prompt_text();
    okay = okay && g_strcmp0(actual_prompt, fixture.prompt) == 0;
    jsti_window_event_fn saved_callback = ui.callback;
    ui.callback = observe_event;
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "must-not-reach-local-callback");
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == JSTI_EVENT_POST_PROCESSING && observed.index == 4
        && g_strcmp0(observed.text, "One%20stop%20after%20each%20word.%0AExact%09second%20line.\t\t0\t1") == 0;
    observed.event = 0;
    adw_combo_row_set_selected(ui.polish_location_row, 1);
    okay = okay && gtk_widget_get_visible(GTK_WIDGET(ui.polish_key_row))
        && !gtk_widget_get_visible(polish_local_group)
        && polish_selected_model() == 1 && observed.event == 0;
    gtk_editable_set_text(GTK_EDITABLE(ui.polish_key_row), "clear-on-local-switch");
    adw_combo_row_set_selected(ui.polish_location_row, 0);
    okay = okay && polish_selected_model() == 4 &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(ui.polish_key_row)), "") == 0;
    adw_combo_row_set_selected(ui.polish_model_row, 0);
    okay = okay && polish_selected_model() == 2 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_prompt_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_directives_row)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_tags_row));
    adw_combo_row_set_selected(ui.polish_model_row, 1);
    okay = okay && polish_selected_model() == 3 &&
        gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_prompt_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_directives_row)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(ui.polish_tags_row)) &&
        !adw_switch_row_get_active(ui.polish_directives_row) && adw_switch_row_get_active(ui.polish_tags_row);
    on_polish_apply(NULL, NULL);
    okay = okay && observed.index == 3 &&
        g_strcmp0(observed.text, "One%20stop%20after%20each%20word.%0AExact%09second%20line.\t\t0\t1") == 0;
    fixture.remembered_remote_index = -1;
    polish_apply(&fixture);
    adw_combo_row_set_selected(ui.polish_location_row, 1);
    observed.event = 0;
    on_polish_apply(NULL, NULL);
    okay = okay && observed.event == 0 && polish_selected_model() == -1;
    adw_combo_row_set_selected(ui.polish_location_row, 0);
    okay = okay && polish_selected_model() == 4;
    okay = okay && jsti_window_set_cleanup_sources(10001) == -1;
    polish_apply(&saved);
    polish_remote_count = saved_remote;
    ui.suppress = TRUE;
    adw_combo_row_set_selected(ui.polish_location_row, saved_location);
    polish_select_location(saved.selected, FALSE);
    ui.polish_local_selected = saved_local;
    ui.suppress = FALSE;
    ui.callback = saved_callback;
    g_clear_pointer(&observed.text, g_free);
    g_free(saved.local_notice); g_free(saved.prompt); g_free(actual_prompt);
    g_ptr_array_unref(saved.models); g_ptr_array_unref(fixture.models);
    return okay ? 0 : fail(error, capacity, "local cleanup source/index/prompt/privacy controls failed");
}

static gboolean cleanup_preview_self_test(void) {
    gchar *original = displayed_transcript();
    gchar *status = g_strdup(gtk_label_get_text(ui.status));
    gchar *presented = g_strdup(ui.presented_id);
    gint32 state = ui.state, page = ui.page;
    gboolean visible = cleanup_visible;
    jsti_window_event_fn callback = ui.callback;
    ui.callback = NULL;
    ui.state = JSTI_STATE_WORKING;
    show_page(JSTI_PAGE_DASHBOARD);
    guint64 first = jsti_window_begin_cleanup_preview();
    gboolean okay = jsti_window_cleanup_preview("first", first) == 0 &&
        jsti_window_cleanup_preview("latest", first) == 0;
    cleanup_preview_apply(NULL);
    gchar *actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "latest") == 0 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.copy)) && !gtk_widget_get_sensitive(GTK_WIDGET(ui.dashboard_copy));
    g_free(actual);
    show_page(JSTI_PAGE_GENERAL);
    show_page(JSTI_PAGE_DASHBOARD);
    okay = okay && jsti_window_cleanup_preview("away/back stale", first) == 1;
    guint64 second = jsti_window_begin_cleanup_preview();
    okay = okay && second != first && jsti_window_cleanup_preview("replacement", second) == 0;
    jsti_window_end_cleanup_preview(first);
    cleanup_preview_apply(NULL);
    actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "replacement") == 0;
    g_free(actual);
    gchar *maximum = g_strnfill(65536, 'x');
    okay = okay && jsti_window_cleanup_preview(maximum, second) == 0;
    g_free(maximum);
    jsti_window_end_cleanup_preview(second);
    cleanup_preview_apply(NULL);
    actual = displayed_transcript();
    okay = okay && g_strcmp0(actual, "replacement") == 0;
    g_free(actual);
    gchar *oversized = g_strnfill(65537, 'x');
    okay = okay && jsti_window_cleanup_preview("retired", second) == 1 &&
        jsti_window_cleanup_preview(oversized, second) == -1 &&
        jsti_window_cleanup_preview("\xff", second) == -1;
    g_free(oversized);
    set_transcript(original);
    gtk_label_set_text(ui.status, status);
    g_free(ui.presented_id);
    ui.presented_id = presented;
    ui.state = state;
    cleanup_visible = visible;
    show_page(page);
    ui.callback = callback;
    refresh_actions();
    g_free(original);
    g_free(status);
    return okay;
}

int32_t jsti_window_self_test(char *error, size_t capacity) {
    if (jsti_hands_free_guard_self_test(error, capacity) != 0) return -1;
    if (ui.window == NULL) return fail(error, capacity, "the window was not created");
    const JSTIAboutLink invalid_about_link = {"Invalid", "file:///not-an-update"};
    if (ui.about_details == NULL || ui.about_links == NULL ||
        strstr(gtk_label_get_text(ui.about_details), "Version:") == NULL ||
        jsti_window_configure_about("bad", NULL, 0) != -1 ||
        jsti_window_configure_about("bad", &invalid_about_link, 1) != -1 ||
        jsti_window_configure_about("\xff", &invalid_about_link, 1) != -1)
        return fail(error, capacity, "About metadata or invalid input refusal failed");
    guint about_count = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(ui.about_links));
         child != NULL; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *button = gtk_flow_box_child_get_child(GTK_FLOW_BOX_CHILD(child));
        const char *uri = g_object_get_data(G_OBJECT(button), "about-uri");
        if (!GTK_IS_BUTTON(button) || uri == NULL || !g_str_has_prefix(uri, "https://"))
            return fail(error, capacity, "About link label or destination was not preserved");
        ++about_count;
    }
    if (about_count != 6) return fail(error, capacity, "About canonical links are missing");
    if (!cleanup_preview_self_test())
        return fail(error, capacity, "cleanup preview bounds, coalescing, navigation or retirement failed");
    if (local_cleanup_sources_self_test(error, capacity) != 0) return -1;
    if (jsti_visual_density_self_test(GTK_WIDGET(ui.window)) != 0)
        return fail(error, capacity, "layout density geometry, Normal restoration or editing focus failed");
    if (!sidebar_navigation_self_test())
        return fail(error, capacity, "sidebar hints, focus guards or window-local navigation failed");
    if (jsti_action_shortcuts_self_test(error, capacity) != 0) return -1;
    if (jsti_action_shortcut_editor_self_test(ui.window, error, capacity) != 0) return -1;
    if (!action_execution_self_test())
        return fail(error, capacity, "action shortcut native page, event, slot or sensitivity routing failed");
    if (!command_forwarding_self_test())
        return fail(error, capacity, "desktop-bound command parsing, dispatch or lifetime admission failed");
    if (!command_process_self_test(error, capacity)) return -1;
    if (!post_processing_self_test())
        return fail(error, capacity, "Local/Remote post-processing controls, key isolation or callback indexes failed");
    if (ui.recordings_folder == NULL || ui.audio_cleanup == NULL ||
        ui.backup_audio == NULL || ui.backup_profiles == NULL ||
        ui.backup_export == NULL || ui.backup_inspect == NULL ||
        !adw_switch_row_get_active(ui.backup_audio) ||
        adw_switch_row_get_active(ui.backup_profiles) ||
        jsti_window_confirm_audio_cleanup(NULL, 1) != -1 ||
        g_strcmp0(gtk_button_get_label(ui.recordings_folder), "_Open folder") != 0) {
        return fail(error, capacity, "the recording folder control was not created");
    }
    BackupChoice choice = {0};
    g_weak_ref_init(&choice.parent, G_OBJECT(ui.window));
    choice.cancelled = g_cancellable_new();
    ui.backup_chooser = g_object_ref(choice.cancelled);
    GObject *choice_parent = g_weak_ref_get(&choice.parent);
    refresh_actions();
    gboolean backup_ok = backup_choice_active(&choice, choice_parent) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.backup_audio)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.backup_profiles)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.backup_export)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(ui.backup_inspect));
    jsti_window_event_fn backup_callback = ui.callback;
    ui.callback = observe_event;
    for (gint32 flags = 0; flags < 4; ++flags) {
        choice.include_audio = flags & 1;
        choice.include_profiles = flags & 2;
        backup_emit_path(&choice, "synthetic-export.zip");
        backup_ok = backup_ok && observed.event == JSTI_EVENT_MIGRATION_EXPORT && observed.index == flags &&
            g_strcmp0(observed.text, "synthetic-export.zip") == 0;
    }
    choice.inspect = TRUE;
    choice.include_audio = 1;
    backup_emit_path(&choice, "synthetic-review.zip");
    backup_ok = backup_ok && observed.event == JSTI_EVENT_MIGRATION_INSPECT && observed.index == 0 &&
        g_strcmp0(observed.text, "synthetic-review.zip") == 0;
    ui.callback = backup_callback;
    g_clear_pointer(&observed.text, g_free);
    ui.closing = TRUE;
    backup_ok = backup_ok && !backup_choice_active(&choice, choice_parent);
    ui.closing = FALSE;
    g_cancellable_cancel(choice.cancelled);
    backup_ok = backup_ok && !backup_choice_active(&choice, choice_parent);
    g_clear_object(&ui.backup_chooser);
    g_clear_object(&choice_parent);
    g_weak_ref_clear(&choice.parent);
    g_object_unref(choice.cancelled);
    refresh_actions();
    if (!backup_ok) return fail(error, capacity, "History backup chooser cancellation or late-close fence failed");
    gchar report_text[] = "Synthetic read-only report.";
    GtkWidget *report_dialog = migration_report_dialog(report_text);
    g_object_ref_sink(report_dialog);
    report_text[0] = 'x';
    gboolean report_ok = jsti_window_show_migration_report(NULL) == -1 &&
        g_strcmp0(adw_message_dialog_get_body(ADW_MESSAGE_DIALOG(report_dialog)), "Synthetic read-only report.") == 0 &&
        g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(report_dialog)), "close") == 0 &&
        g_strcmp0(adw_message_dialog_get_close_response(ADW_MESSAGE_DIALOG(report_dialog)), "close") == 0;
    gtk_window_destroy(GTK_WINDOW(report_dialog));
    g_object_unref(report_dialog);
    if (!report_ok) return fail(error, capacity, "Backup inspection report text ownership or close defaults changed");
    gchar audio_token[] = "00000000-0000-0000-0000-000000000093";
    GtkWidget *audio_confirmation = audio_cleanup_dialog(audio_token, 2);
    g_object_ref_sink(audio_confirmation);
    audio_token[0] = 'x';
    gboolean audio_confirmation_ok =
        g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(audio_confirmation)), "cancel") == 0 &&
        g_strcmp0(adw_message_dialog_get_close_response(ADW_MESSAGE_DIALOG(audio_confirmation)), "cancel") == 0 &&
        g_strcmp0(g_object_get_data(G_OBJECT(audio_confirmation), "jsti-audio-cleanup-token"),
                  "00000000-0000-0000-0000-000000000093") == 0;
    g_signal_handlers_block_by_func(audio_confirmation, G_CALLBACK(audio_cleanup_response), NULL);
    gtk_window_destroy(GTK_WINDOW(audio_confirmation));
    g_object_unref(audio_confirmation);
    if (!audio_confirmation_ok) return fail(error, capacity, "recording audio confirmation defaults or snapshot changed");
    if (!configuration_self_test())
        return fail(error, capacity, "configuration rows did not populate and emit a complete Apply");
    if (!text_output_self_test())
        return fail(error, capacity, "clipboard restoration did not follow the session capability and saved choice");
    const char *icon_name = gtk_window_get_icon_name(ui.window);
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(GTK_WIDGET(ui.window)));
    if (g_strcmp0(icon_name, "com.justspeaktoit.JustSpeakToIt") != 0 ||
        !gtk_icon_theme_has_icon(theme, "com.justspeaktoit.JustSpeakToIt")) {
        return fail(error, capacity, "the canonical application icon is not available in the window's theme");
    }
    if (login_item_self_test(error, capacity) != 0) return -1;
    if (automation_self_test(error, capacity) != 0) return -1;
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
    if (jsti_model_filters_self_test(error, capacity) != 0) return -1;
    if (jsti_cloud_sync_self_test(error, capacity) != 0) return -1;
    if (jsti_history_filters_self_test(error, capacity) != 0) return -1;
    if (jsti_vocabulary_self_test(error, capacity) != 0) return -1;
    if (jsti_profiles_self_test(error, capacity) != 0) return -1;
    if (jsti_troubleshooting_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_api_keys_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_permissions_self_test(ui.window, error, capacity) != 0) return -1;
    {
        GtkTextBuffer *prompt = gtk_text_view_get_buffer(ui.polish_prompt_row);
        GtkTextIter prompt_start, prompt_end;
        gtk_text_buffer_get_bounds(prompt, &prompt_start, &prompt_end);
        gchar *draft = gtk_text_buffer_get_text(prompt, &prompt_start, &prompt_end, TRUE);
        gint32 saved_enabled = adw_switch_row_get_active(ui.polish_row) ? 1 : 0;
        gint32 disabled = 0;
        post_processing_enabled_apply(&disabled);
        gtk_text_buffer_get_bounds(prompt, &prompt_start, &prompt_end);
        gchar *after_fix = gtk_text_buffer_get_text(prompt, &prompt_start, &prompt_end, TRUE);
        gboolean draft_preserved = g_strcmp0(draft, after_fix) == 0 && !adw_switch_row_get_active(ui.polish_row);
        post_processing_enabled_apply(&saved_enabled);
        g_free(draft); g_free(after_fix);
        if (!draft_preserved || jsti_window_set_post_processing_enabled(2) != -1)
            return fail(error, capacity, "cleanup fix refresh replaced a prompt draft or accepted an invalid state");
    }
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
    gchar *all_ids = g_strdup_printf("%s\n%s", first, second);
    if (jsti_window_set_history_management(NULL) != -1 || jsti_window_set_history_management("\xff") != -1) {
        g_free(all_ids);
        return fail(error, capacity, "invalid History management input was accepted");
    }
    history_management_apply(all_ids);
    GtkWidget *confirmation = history_delete_dialog(all_ids, TRUE);
    g_object_ref_sink(confirmation);
    gboolean management_ok = gtk_widget_get_sensitive(GTK_WIDGET(ui.history_delete))
        && gtk_widget_get_sensitive(GTK_WIDGET(ui.history_clear))
        && adw_message_dialog_has_response(ADW_MESSAGE_DIALOG(confirmation), "keep-audio")
        && adw_message_dialog_has_response(ADW_MESSAGE_DIALOG(confirmation), "delete-audio")
        && g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(confirmation)), "cancel") == 0;
    history_management_apply((gpointer)first);
    management_ok = management_ok && g_strcmp0(
        g_object_get_data(G_OBJECT(confirmation), "jsti-history-delete-ids"), all_ids) == 0;
    gtk_window_destroy(GTK_WINDOW(confirmation));
    g_object_unref(confirmation);
    history_management_apply(all_ids);
    g_free(all_ids);
    if (!management_ok) return fail(error, capacity, "History confirmation choices or frozen IDs were not retained");
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
    if (voice_favorites_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_credentials_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_sources_self_test(ui.window, error, capacity) != 0) return -1;
    History *empty = history_copy(NULL, 0, "");
    history_apply(empty);
    history_free(empty);
    Update clear = { .status = (gchar *)"Self-test complete.", .transcript = (gchar *)"", .has_transcript = TRUE,
                     .state = JSTI_STATE_IDLE };
    update_apply(&clear);
    if (ui.selected_id != NULL || gtk_widget_get_sensitive(GTK_WIDGET(ui.copy))) {
        return fail(error, capacity, "clearing History left record actions enabled");
    }
    if (jsti_hud_self_test(error, capacity) != 0) return -1;
    if (jsti_comparison_self_test(ui.window, error, capacity) != 0) return -1;
    return jsti_tray_self_test(error, capacity);
}

/* ------------------------------------------------------ screenshot tour */

/* Renders `widget` at its allocated size into a PNG, over the window's
 * background colour when `opaque`. */
int32_t jsti_widget_save_snapshot(GtkWidget *widget, const char *path, gboolean opaque) {
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
        GskRenderer *renderer = gtk_native_get_renderer(gtk_widget_get_native(widget));
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
    TextOutput output;
} Tour;

void jsti_voice_discovery_show_fixture(GtkWindow *owner);
int32_t jsti_voice_discovery_save_snapshot(const char *path);
enum { TOUR_PORTAL_OUTPUT = JSTI_PAGE_COUNT, TOUR_DARK_DASHBOARD, TOUR_DARK_HISTORY, TOUR_RECORDING, TOUR_HUD_RECORDING,
       TOUR_HUD_COMPLETED, TOUR_HISTORY_FILTERS, TOUR_DARK_HISTORY_FILTERS, TOUR_DARK_GENERAL, TOUR_EXPANDED_RECORDING,
       TOUR_COMPACT_RECORDING, TOUR_COMPACT_COMPLETED, TOUR_VOICE_SOURCES, TOUR_VOICE_CONTROLS, TOUR_VOICE_USAGE,
       TOUR_VOICE_DISCOVERY, TOUR_DONE };

static gboolean tour_capture(gpointer data);

static void tour_show(Tour *tour) {
    if (tour->step < JSTI_PAGE_COUNT) {
        show_page(tour->step);
    } else if (tour->step == TOUR_PORTAL_OUTPUT) {
        TextOutput portal = { .method = 0, .restore = TRUE, .can_restore = FALSE };
        text_output_apply(&portal);
        show_page(JSTI_PAGE_GENERAL);
    } else if (tour->step == TOUR_DARK_DASHBOARD) {
        text_output_apply(&tour->output);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_DASHBOARD);
    } else if (tour->step == TOUR_DARK_HISTORY) {
        show_page(JSTI_PAGE_HISTORY);
    } else if (tour->step == TOUR_DARK_GENERAL) {
        Update idle = { .state = JSTI_STATE_IDLE };
        update_apply(&idle);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_GENERAL);
    } else if (tour->step == TOUR_HISTORY_FILTERS || tour->step == TOUR_DARK_HISTORY_FILTERS) {
        Update idle = { .state = JSTI_STATE_IDLE };
        update_apply(&idle);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(),
            tour->step == TOUR_HISTORY_FILTERS ? ADW_COLOR_SCHEME_FORCE_LIGHT : ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_HISTORY);
        gtk_menu_button_popup(GTK_MENU_BUTTON(ui.history_filters));
    } else if (tour->step == TOUR_HUD_RECORDING) {
        jsti_hud_show(1, "Recording", "Capturing audio",
                      "Could we move the catch-up to Friday? That gives us a little more time");
    } else if (tour->step == TOUR_HUD_COMPLETED) {
        jsti_hud_show(5, "Completed", "Saved. Pasted into the original window.", "");
    } else if (tour->step == TOUR_EXPANDED_RECORDING) {
        jsti_hud_show_layout(1, "Recording", "Capturing audio",
                              "Could we move the catch-up to Friday? That gives us a little more time to finish "
                              "the proposal and review the notes together before sending them to the team.", 0, FALSE, TRUE);
    } else if (tour->step == TOUR_COMPACT_RECORDING) {
        jsti_hud_show_presentation(1, "Recording", "Capturing audio",
                                    "Could we move the catch-up to Friday? That gives us a little more time", 0, TRUE);
    } else if (tour->step == TOUR_COMPACT_COMPLETED) {
        jsti_hud_show_presentation(5, "Completed", "Saved. Pasted into the original window.", "", 2400, TRUE);
    } else if (tour->step == TOUR_VOICE_SOURCES) {
        jsti_hud_destroy();
        jsti_voice_sources_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_CONTROLS) {
        jsti_voice_sources_close();
        jsti_voice_controls_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_USAGE) {
        jsti_voice_usage_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_DISCOVERY) {
        jsti_voice_discovery_show_fixture(ui.window);
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
    case TOUR_PORTAL_OUTPUT: return "general-portal-output";
    case TOUR_RECORDING: return "dashboard-recording";
    case TOUR_HUD_RECORDING: return "hud-recording";
    case TOUR_HUD_COMPLETED: return "hud-completed";
    case TOUR_EXPANDED_RECORDING: return "hud-expanded-recording";
    case TOUR_COMPACT_RECORDING: return "hud-compact-recording";
    case TOUR_COMPACT_COMPLETED: return "hud-compact-completed";
    case TOUR_DARK_DASHBOARD: return "dashboard-dark";
    case TOUR_DARK_HISTORY: return "history-dark";
    case TOUR_HISTORY_FILTERS: return "history-filters";
    case TOUR_DARK_HISTORY_FILTERS: return "history-filters-dark";
    case TOUR_VOICE_SOURCES: return "voice-sources";
    case TOUR_VOICE_CONTROLS: return "voice-controls";
    case TOUR_VOICE_USAGE: return "voice-usage";
    case TOUR_DARK_GENERAL: return "general-dark";
    case TOUR_VOICE_DISCOVERY: return "voice-discovery";
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
    if (tour->step == TOUR_HISTORY_FILTERS || tour->step == TOUR_DARK_HISTORY_FILTERS) {
        GtkPopover *popover = gtk_menu_button_get_popover(GTK_MENU_BUTTON(ui.history_filters));
        if (!popover || jsti_widget_save_snapshot(GTK_WIDGET(popover), path, TRUE) != 0) {
            g_printerr("The History filter editor %s could not be saved.\n", file);
        }
        gtk_menu_button_set_popover(GTK_MENU_BUTTON(ui.history_filters), NULL);
        g_free(path); g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) tour_show(tour);
        else {
            g_free(tour->directory); g_free(tour);
            gtk_window_close(ui.window);
        }
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_CONTROLS) {
        if (jsti_voice_controls_save_snapshot(path) != 0) g_printerr("The Voice controls snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++; tour_show(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_USAGE) {
        if (jsti_voice_usage_save_snapshot(path) != 0) g_printerr("The Voice usage snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++; tour_show(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_DISCOVERY) {
        if (jsti_voice_discovery_save_snapshot(path) != 0) g_printerr("The account voice snapshot failed.\n");
        g_free(path); g_free(file);
        jsti_comparison_screenshot_tour(ui.window, tour->directory);
        g_free(tour->directory); g_free(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_SOURCES) {
        if (jsti_voice_sources_save_snapshot(path) != 0) g_printerr("The Voice Output editor snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) {
            tour_show(tour);
        } else {
            jsti_comparison_screenshot_tour(ui.window, tour->directory);
            g_free(tour->directory);
            g_free(tour);
        }
        return G_SOURCE_REMOVE;
    }
    if ((tour->step >= TOUR_HUD_RECORDING && tour->step <= TOUR_HUD_COMPLETED) ||
        (tour->step >= TOUR_EXPANDED_RECORDING && tour->step <= TOUR_COMPACT_COMPLETED)) {
        /* The HUD is its own window; X11 only. */
        GtkWidget *card = jsti_hud_card();
        if (card != NULL && jsti_widget_save_snapshot(card, path, TRUE) != 0) g_printerr("The HUD %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) {
            tour_show(tour);
        } else {
            jsti_comparison_screenshot_tour(ui.window, tour->directory);
            g_free(tour->directory);
            g_free(tour);
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
        if (jsti_widget_save_snapshot(column, path, TRUE) != 0) g_printerr("The full page %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
    }
    tour->step++;
    if (tour->step < TOUR_DONE) {
        tour_show(tour);
    } else {
        jsti_comparison_screenshot_tour(ui.window, tour->directory);
        g_free(tour->directory);
        g_free(tour);
    }
    return G_SOURCE_REMOVE;
}

static void tour_start(gpointer data) {
    Tour *tour = data;
    const JSTIHistoryFilterModel models[] = {
        {"model/sample", "Sample transcription model", 0},
        {"model/long", "An imported transcription model with a long descriptive name and vocabulary context", 0}
    };
    if (jsti_window_set_history_filters(models, 2, 0, "", "") != 0) {
        g_printerr("Could not prepare the sample History filter editor.\n");
        g_free(tour->directory); g_free(tour);
        gtk_window_close(ui.window);
        return;
    }
    tour->output = (TextOutput){
        .method = (gint32)adw_combo_row_get_selected(ui.output_row),
        .restore = adw_switch_row_get_active(ui.restore_row),
        .can_restore = ui.can_restore_clipboard
    };
    tour_show(tour);
}

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
