/*
 * Private to the LinuxWindow*.c translation units: the window's shared state, its
 * types and the functions one unit calls in another. Not public ABI; Swift sees
 * only include/CLinuxSupport.h.
 */
#ifndef JSTI_LINUX_WINDOW_INTERNAL_H
#define JSTI_LINUX_WINDOW_INTERNAL_H

#include "LinuxActionShortcutsInternal.h"

#include <adwaita.h>
#include <glib/gstdio.h>
#include <string.h>

#define JSTI_MAXIMUM_CONFIGURATION_FIELDS 64

typedef struct EscapePolicy {
    GMutex mutex;
    guint64 epoch;
    gboolean enabled, recording, closed;
} EscapePolicy;

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

/* The streaming cleanup preview. `lock` guards every field but `visible`. */
typedef struct CleanupPreview {
    GMutex lock;
    guint64 ticket;
    gboolean active, posted;
    gchar *text;
    /* UI-thread only; preview text is never a Copy/export/read-aloud source. */
    gboolean visible;
} CleanupPreview;

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
    gint32 preferred_model_slots[4];
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
    guint state_announcement; /* Idle source that speaks a state change when the HUD is hidden */
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
    GtkButton *issue_button;
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
    GtkButton *backup_restore;
    GtkWidget *restore_dialog;
    GCancellable *backup_chooser;
    gboolean closing;
    gboolean cancel_key_held;
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
GtkWidget *jsti_vocabulary_page_new(int kind);
GtkWidget *jsti_vocabulary_learning_preferences(void);
int32_t jsti_vocabulary_self_test(char *error, size_t capacity);

typedef struct ConfigurationState {
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
} ConfigurationState;

/* Read aloud: its History action and the voice picker in its own group. */
typedef struct ReadAloud {
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
} ReadAloud;

typedef struct BackupChoice {
    GWeakRef parent;
    GCancellable *cancelled;
    gint32 include_audio;
    gint32 include_profiles;
    gint action; /* 0 export, 1 inspect, 2 restore */
} BackupChoice;

/* Sidebar entries in page order, with the Mac sidebar's tints. */
typedef struct PageInfo {
    const char *name;
    const char *title;
    const char *icon;
    const char *tint;
} PageInfo;

typedef struct SidebarShortcuts {
    gint digits[JSTI_PAGE_COUNT];
    GtkWidget *hints[JSTI_PAGE_COUNT];
    gboolean configured;
} SidebarShortcuts;

typedef struct WindowCommand {
    gint run, slot;
    gboolean background, unknown_argument;
} WindowCommand;

/* ------------------------------------------------ thread-safe setters */

typedef void (*apply_fn)(gpointer data);

typedef struct Update {
    gchar *status;
    gchar *transcript;
    gboolean has_transcript;
    gint32 state;
} Update;

struct Models {
    GArray *slots;
    GPtrArray *names;
    gint32 selected;
    gchar *status;
    gboolean refreshing;
};

typedef struct HistoryEntry {
    gchar *id, *created, *audio_length, *cost, *preview, *models, *context;
    gint32 tone;
} HistoryEntry;

typedef struct History {
    GArray *entries;
    gchar *selected;
    gboolean select;
} History;

typedef struct MigrationRestoreConfirmation {
    gchar *token;
    gchar *text;
    gboolean offers_replace;
} MigrationRestoreConfirmation;

typedef struct Insights {
    gchar *all[5];
    gchar *visible[5];
} Insights;

typedef struct LoginItem {
    gint32 state;
    gchar *detail;
} LoginItem;

typedef struct {
    gint digits[JSTI_PAGE_COUNT];
    gchar *hints[JSTI_PAGE_COUNT];
    gboolean show_hints;
} SidebarUpdate;

typedef struct Presentation {
    gchar *id;
    gint32 variant;
    gboolean switchable;
    gchar *text;
    gchar *status;
    gboolean has_text;
} Presentation;

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

typedef struct {
    size_t index;
    gchar *title;
} ConfigurationTitleUpdate;

typedef struct { size_t index; gboolean enabled; } ConfigurationAvailabilityUpdate;

/* Settings search: the revealed row, its pending scroll and its highlight. */
typedef struct Reveal {
    GtkWidget *target;
    guint tick;
    guint frames;
    guint highlight;
} Reveal;

typedef struct Voices {
    GPtrArray *names;
    gint32 selected;
    GPtrArray *identifiers;
    GArray *favorite_ranks;
    JSTIVoicePickerCallback callback;
    void *context;
} Voices;

void jsti_voice_discovery_show_fixture(GtkWindow *owner);
int32_t jsti_voice_discovery_save_snapshot(const char *path);

/* Hidden: shared between these units only, never exported from the binary. */
#pragma GCC visibility push(hidden)

/* Shared window state, defined once in the translation unit named beside it. */
extern EscapePolicy escape_policy; /* LinuxWindow.c */
extern CleanupPreview cleanup_preview; /* LinuxWindow.c */
extern UI ui; /* LinuxWindow.c */
extern guint polish_remote_count; /* LinuxWindow.c */
extern GtkWidget *polish_local_group; /* LinuxWindow.c */
extern ConfigurationState configuration; /* LinuxWindow.c */
extern gint configuration_field_count; /* LinuxWindow.c */
extern ReadAloud read_aloud; /* LinuxWindow.c */
extern gint loop_running; /* LinuxWindow.c */
extern GMutex post_lock; /* LinuxWindow.c */
extern gboolean window_closed; /* LinuxWindow.c */
extern GQueue early_posts; /* LinuxWindow.c */
extern const PageInfo page_info[JSTI_PAGE_COUNT]; /* LinuxWindowNavigation.c */
extern SidebarShortcuts sidebar_shortcuts; /* LinuxWindowNavigation.c */
extern GtkWidget *columns; /* LinuxWindowPages.c */
extern Reveal reveal; /* LinuxWindowConfiguration.c */

/* Defined in the LinuxWindow*.c translation units. */
void escape_publish(EscapePolicy *policy, gint32 recording, gint32 enabled, gboolean close);
guint64 escape_token(EscapePolicy *policy);
gboolean escape_enabled(void);
guint model_mode(gboolean local, gboolean live);
void retire_cleanup_preview(void);
void emit(gint32 event, const char *text, gint32 index);
gint32 selected_model_slot(void);
const char *selected_microphone(void);
gchar *displayed_transcript(void);
void set_transcript(const char *text);
void refresh_setup(void);
void refresh_actions(void);
void on_record(GtkButton *button, gpointer data);
void on_cancel(GtkButton *button, gpointer data);
void on_copy(GtkButton *button, gpointer data);
void refresh_azure_row(void);
void on_model(GObject *object, GParamSpec *spec, gpointer data);
void on_azure_apply(AdwEntryRow *row, gpointer data);
void on_microphone(GObject *object, GParamSpec *spec, gpointer data);
void on_key_apply(AdwEntryRow *row, gpointer data);
void on_text_output(GObject *object, GParamSpec *spec, gpointer data);
void apply_appearance(guint appearance);
void on_appearance(GObject *object, GParamSpec *spec, gpointer data);
void on_login_item(GObject *object, GParamSpec *spec, gpointer data);
void on_automation(GObject *object, GParamSpec *spec, gpointer data);
void on_style(GObject *object, GParamSpec *spec, gpointer data);
guint polish_remote_boundary(void);
gint32 polish_selected_model(void);
gchar *polish_prompt_text(void);
void polish_select_location(gint32 desired, gboolean choose_first);
void on_polish_location(GObject *object, GParamSpec *spec, gpointer data);
void on_polish_model(GObject *object, GParamSpec *spec, gpointer data);
void on_polish_apply(GtkButton *button, gpointer data);
void on_refresh(GtkButton *button, gpointer data);
void on_search(GtkSearchEntry *entry, gpointer data);
void detach_detail(void);
void attach_detail(GtkListBoxRow *row);
void on_history_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data);
void on_version(GObject *object, GParamSpec *spec, gpointer data);
void on_retry(GtkButton *button, gpointer data);
void on_correction_results(GtkButton *button, gpointer data);
void on_play(GtkButton *button, gpointer data);
void on_stop_play(GtkButton *button, gpointer data);
void on_read_aloud(GtkButton *button, gpointer data);
void on_voice(GObject *object, GParamSpec *spec, gpointer data);
void on_favorite_voice(GObject *object, GParamSpec *spec, gpointer data);
void on_favorite_toggle(GtkButton *button, gpointer data);
void on_open_audio(GtkButton *button, gpointer data);
void on_recordings_folder(GtkButton *button, gpointer data);
void on_recordings_choose(GtkButton *button, gpointer data);
void on_recordings_default(GtkButton *button, gpointer data);
void on_audio_cleanup(GtkButton *button, gpointer data);
gboolean backup_choice_active(const BackupChoice *choice, GObject *parent);
void backup_emit_path(const BackupChoice *choice, const char *path);
void on_backup(GtkButton *button, gpointer data);
void audio_cleanup_response(AdwMessageDialog *dialog, const char *response, gpointer data);
GtkWidget *audio_cleanup_dialog(const char *token, size_t count);
void on_issue_report(GtkButton *button, gpointer data);
void on_export(GtkButton *button, gpointer data);
void on_import(GtkButton *button, gpointer data);
GtkWidget *group(const char *title);
GtkWidget *read_aloud_group(void);
void show_page(gint32 page);
gboolean sidebar_navigate(guint keyval, GdkModifierType modifiers, GtkWidget *focused);
gboolean cancel_key(guint keyval, GdkModifierType modifiers, GtkWidget *focused, gboolean active);
gboolean cancel_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                   GdkModifierType modifiers, gpointer data);
gboolean sidebar_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                    GdkModifierType modifiers, gpointer data);
void action_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                GdkModifierType modifiers, gpointer data);
void action_window_active(GObject *object, GParamSpec *spec, gpointer data);
GtkWidget *build_sidebar(void);
GtkWidget *settings_hero(const char *title, const char *subtitle);
void add_page(gint32 page, GtkWidget *widget);
void add_compact_hero_setters(AdwBreakpoint *breakpoint, GtkWidget *widget);
GtkWidget *build_dashboard(GtkTextBuffer *buffer);
GtkWidget *history_delete_dialog(const char *identifiers, gboolean clear);
GtkWidget *build_history(GtkTextBuffer *buffer);
GtkWidget *build_voice_output(void);
GtkWidget *build_general(void);
GtkWidget *build_transcription(void);
GtkWidget *build_post_processing(void);
GtkWidget *build_keyboard(void);
GtkWidget *build_cloud_sync(void);
GtkWidget *link_button(const char *label, const char *uri);
gboolean action_shortcut_run(gint run, const char *page, gint slot);
GtkWidget *build_about(void);
gboolean parse_window_command(gint argc, const gchar *const *argv, WindowCommand *command);
gboolean is_forwardable_command(gint run, gint slot);
gboolean parse_action_command(int argc, const gchar *const *argv, WindowCommand *command);
gint forward_window_command(gint run, gint slot, gboolean remote);
int on_command_line(GApplication *application, GApplicationCommandLine *line, gpointer data);
int32_t post(apply_fn apply, gpointer data, GDestroyNotify destroy);
void open_posts(void);
void close_posts(void);
void update_apply(gpointer pointer);
void cleanup_preview_apply(gpointer pointer);
void models_free(gpointer pointer);
void filter_models(gint32 keep);
void on_model_filter(gboolean local, gboolean live);
void apply_models(const JSTIModelRow *rows, size_t count, gint32 selected);
void model_preferences_apply(gpointer pointer);
void local_model_preferences_apply(gpointer pointer);
void history_free(gpointer pointer);
void history_apply(gpointer pointer);
History *history_copy(const JSTIHistoryRow *rows, size_t count, const char *selected_id);
void history_management_apply(gpointer pointer);
GtkWidget *migration_report_dialog(const char *text);
void retire_migration_restore(void);
void refresh_migration_restore(void);
void migration_restore_response(AdwMessageDialog *dialog, const char *response, gpointer data);
gboolean migration_restore_stage(const MigrationRestoreConfirmation *confirmation);
void insights_free(gpointer pointer);
void insights_apply(gpointer pointer);
void insights_copy(gchar **target, const JSTIInsights *source);
void post_processing_enabled_apply(gpointer pointer);
void login_item_apply(gpointer pointer);
void automation_apply(gpointer pointer);
void sidebar_update_apply(gpointer pointer);
void presentation_apply(gpointer pointer);
void text_output_apply(gpointer pointer);
void polish_apply(gpointer pointer);
void cleanup_sources_apply(gpointer pointer);
int32_t jsti_window_set_cleanup_sources(size_t count);
void on_configuration_apply(GtkButton *button, gpointer data);
void configuration_hands_free_availability(GtkWidget *row, gboolean enabled);
gboolean configuration_choices_valid(const char *choices, const char *value);
void configuration_title_apply(gpointer data);
void configuration_availability_apply(gpointer data);
void reveal_cancel(void);
void configuration_reveal_apply(gpointer data);
void voices_apply(gpointer pointer);
int32_t fail(char *error, size_t capacity, const char *message);

#pragma GCC visibility pop

#endif
