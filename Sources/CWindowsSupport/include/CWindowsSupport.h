#ifndef JSTI_WINDOWS_SUPPORT_H
#define JSTI_WINDOWS_SUPPORT_H

#include <stddef.h>
#include <stdint.h>
#include "VoiceSources.h"
#include "VoiceAudioCodec.h"
#include "VoiceCredentials.h"
#include "LocalCleanup.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Corrections/pronunciation editor; events 70 (action), 71 (load), index 0/1;
 * event 72 reads a selected recording's correction snapshot (kind 2).
 * Escaped UTF-8 field contract lives in DesktopVocabularyWire. */
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh);

/* UTF-8 strings throughout. Zero is success; -1 is failure with a caller-owned
 * error buffer. No API logs credential or transcript contents. Windows only. */
enum JSTIWindowEvent {
    JSTI_EVENT_TOGGLE_RECORDING = 1,
    JSTI_EVENT_IMPORT_AUDIO = 2,
    JSTI_EVENT_COPY_TRANSCRIPT = 3,
    JSTI_EVENT_SAVE_CREDENTIAL = 4,
    JSTI_EVENT_MODEL_CHANGED = 5,
    JSTI_EVENT_CLOSING = 6,
    JSTI_EVENT_READY = 7,
    JSTI_EVENT_ERROR = 8,
    JSTI_EVENT_HISTORY_SELECTED = 9,
    JSTI_EVENT_HISTORY_RETRY = 10,
    JSTI_EVENT_HISTORY_EXPORT = 11,
    JSTI_EVENT_HISTORY_OPEN_AUDIO = 12,
    JSTI_EVENT_MICROPHONE_CHANGED = 13,
    JSTI_EVENT_CANCEL_TRANSCRIPTION = 14,
    JSTI_EVENT_HISTORY_SEARCH = 15,
    JSTI_EVENT_TRANSCRIPT_VARIANT = 16,
    /* Native History playback controls; both carry the selected record ID. */
    JSTI_EVENT_HISTORY_PLAY_PAUSE = 18,
    JSTI_EVENT_HISTORY_STOP = 19,
    JSTI_EVENT_REFRESH_MODELS = 20,
    /* Gesture activation styles only (see jsti_window_set_hotkey). DOWN carries
     * the selected microphone ID like TOGGLE_RECORDING; UP and DEADLINE carry
     * no text. A press-to-toggle style keeps sending TOGGLE_RECORDING. */
    JSTI_EVENT_HOTKEY_DOWN = 21,
    JSTI_EVENT_HOTKEY_UP = 22,
    JSTI_EVENT_HOTKEY_DEADLINE = 23,
    /* Carries the selected record ID; read the displayed transcript with
     * jsti_window_transcript_snapshot synchronously in the callback, as for Copy. */
    JSTI_EVENT_HISTORY_READ_ALOUD = 24,
    /* General's automation switch: text is "1" to allow automation and "0" to
     * stop it. Report the state reached with jsti_window_set_automation. */
    JSTI_EVENT_AUTOMATION_TOGGLED = 25,
    /* General > Theme changed. text: "0" follow Windows, "1" light, "2" dark. */
    JSTI_EVENT_APPEARANCE = 26,
    /* General's Launch at login switch: text "1" on, "0" off. The switch stays
     * disabled until jsti_window_set_login_item reports the state reached. */
    JSTI_EVENT_LOGIN_ITEM = 27,
    JSTI_EVENT_HISTORY_FILTERS = 90, /* text: DesktopHistoryFilter JSON */
    JSTI_EVENT_HISTORY_DELETE = 91, /* text: frozen newline-separated UUIDs; index: 1 removes owned audio */
    JSTI_EVENT_RECORDINGS_FOLDER = 93,
    JSTI_EVENT_AUDIO_CLEANUP = 94,
    JSTI_EVENT_AUDIO_CLEANUP_RESPONSE = 95, /* text: confirmation UUID; index: 1 confirms, 0 cancels */
    JSTI_EVENT_MIGRATION_EXPORT = 96, /* text: selected ZIP destination; index: 1 includes saved audio */
    JSTI_EVENT_MIGRATION_INSPECT = 97, /* text: selected ZIP source; no application changes */
    JSTI_EVENT_USER_ABSENT = 120
};

/* Runs on the UI thread. text is borrowed until callback returns. model_index
 * is the selected caller-supplied model. READY is sent after controls exist.
 * COPY_TRANSCRIPT carries the selected history ID, or empty if none is selected.
 * MICROPHONE_CHANGED and TOGGLE_RECORDING carry the selected microphone ID;
 * empty selects the default communications microphone. HISTORY_SEARCH carries
 * the current search text (empty when cleared); the host filters the rows it
 * supplies through jsti_window_set_history. TRANSCRIPT_VARIANT carries the
 * selected record ID after the user chose a transcript version; pair it with
 * jsti_window_transcript_variant() synchronously inside the callback. */
typedef void (*JSTIWindowCallback)(int event, const char *text, int model_index, void *context);
typedef struct JSTIConfigurationField {
    const char *title;
    const char *value;
    const char *group;
    int is_boolean;
    int requires_hud_overlay;
    /* Optional newline-separated choices: raw value, tab, display title. */
    const char *choices;
    int requires_hands_free_guard;
    /* Zero: independent. Otherwise the 1-based index of a boolean enabling field. */
    int enabled_by_field;
} JSTIConfigurationField;
/* action 0 applies fields; 1 imports and 2 exports a path in values[0].
 * action 3 applies fields plus the selected recovered-keyword text in the final
 * value; the host verifies that exact edit still exists before restoring it.
 * The callback validates synchronously; persistence is ordered by Swift. */
typedef int (*JSTIConfigurationCallback)(int action, const char *const *values, size_t count,
                                        void *context, char *error, size_t capacity);
int jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
                                  const char *const *recovered_keywords, size_t recovered_count,
                                  JSTIConfigurationCallback callback, void *context);
void jsti_window_clear_configuration(void);
/* Changes only a label, never an unsaved value. 1 means no editor snapshot exists yet. */
int jsti_window_set_configuration_field_title(size_t index, const char *title);
/* Explicit route availability, without replacing a value or changing dependencies. */
int jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled);

/* Comparison actions 100-107. Model rows: id TAB name TAB live(0/1), round rows:
 * id TAB name. Run payload: language LF tab-separated model ids LF file paths.
 * Rank payload: round id LF comma-separated ranks in persisted blind order. */
int jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                           const char *selected, int busy, int recording, int judgeable,
                           int sync_enabled, int sync_available, const char *references, const char *reference);
/* Thread-safe; false refuses hands-free if native lock/sleep observation failed. */
int jsti_window_hands_free_guard_ready(void);
int jsti_window_run(const char *const *model_names, size_t model_count, int selected_index,
                    JSTIWindowCallback callback, void *context, char *error, size_t error_capacity);
/* Optional pre-run mode catalogue with the same count/order as window_run's
 * full model array. Each mode is 0 remote batch, 1 remote live, 2 local batch
 * or 3 local live: bit 0 is live, bit 1 is local. The window shows a Source
 * picker (Remote, Local) when both sources have models, then a Mode picker
 * (Batch, Live) when the selected source has both. Preferences are global
 * indices of a remote batch, a remote live and a local batch row; -1 chooses
 * that mode's first model. Null/count0 restores the legacy all-batch
 * catalogue. Inputs are copied. window_run's selected_index overrides that
 * mode's preference. Every callback continues to report a global model index,
 * never a filtered combo row. */
int jsti_window_set_model_modes(const int *modes, size_t count, int preferred_batch_index,
                                int preferred_live_index, int preferred_local_index);
typedef struct JSTIModelRow {
    const char *id;
    const char *name;
    int is_live;
    int display_order; /* -1 hidden; otherwise unique visible rank, independent of slot index. */
    int is_local; /* 1 for an on-device model; the Source picker separates Local from Remote. */
} JSTIModelRow;
/* Deep-copies a model snapshot. Configure before window_run, then append-only
 * identity slots may be updated from any thread. Existing IDs/modes must stay
 * at the same indices; labels and visible order may change. Current selections
 * remain visible and selected even when their display_order becomes -1.
 * Programmatic refresh never emits MODEL_CHANGED or changes recording state.
 * status/refreshing update a separate discovery control; event20 requests a
 * refresh. No network operation runs inside the native window loop. */
int jsti_window_set_model_catalog(const JSTIModelRow *rows, size_t count,
                                   const char *status, int refreshing);
/* Thread safe; updates coalesce. Null status/transcript retains the prior value.
 * recording: -1 retains current value, 0 idle, 1 recording, 2 busy (disable controls). */
int jsti_window_update(const char *status, const char *transcript, int recording);
/* Preview-only, bounded/coalesced, invalidated by native page/record/version changes.
 * Offer returns 1 for a stale ticket, -1 for an enqueue/validation failure. */
uint64_t jsti_window_begin_cleanup_preview(void);
int jsti_window_cleanup_preview(const char *text, uint64_t ticket);
void jsti_window_end_cleanup_preview(uint64_t ticket);
void jsti_window_request_close(void);
/* Copies IDs/names before return; also valid before window_run. Caller may
 * include a synthetic default row with an empty ID. Selection updates are
 * programmatic; a user change emits MICROPHONE_CHANGED with its device ID. */
int jsti_window_set_microphones(const char *const *ids, const char *const *names,
                                size_t count, const char *selected_id);


/* A complete active capture-device snapshot; borrowed only during the callback.
 * Endpoint IDs are opaque; an empty ID is reserved for the system-default row. */
typedef struct JSTIAudioDevice {
    const char *id;
    const char *name;
    int is_default;
} JSTIAudioDevice;
/* Latest-only refresh on the UI thread. Does not change the selected ID or emit
 * selection events; a missing selection becomes an unavailable row. Snapshots
 * received while recording/busy are deferred until idle. Error-only snapshots
 * (non-null error) retain the prior list. Must be called after window creation. */
int jsti_window_refresh_microphones(const JSTIAudioDevice *devices, size_t count, const char *error);
/* One owned worker registers endpoint notifications and enumerates off the UI
 * and capture threads. OS callbacks only signal coalesced work. The callback
 * receives a complete snapshot or an error, never a partial list; it must return
 * promptly and must not destroy the monitor. No credentials or capture access. */
typedef void (*JSTIAudioDevicesChangedCallback)(const JSTIAudioDevice *devices, size_t count,
                                               const char *error, void *context);
typedef struct JSTIAudioDeviceMonitor JSTIAudioDeviceMonitor;
JSTIAudioDeviceMonitor *jsti_audio_device_monitor_create(JSTIAudioDevicesChangedCallback callback, void *context,
                                                        char *error, size_t error_capacity);
/* Nonblocking and valid from the callback. No later snapshot is dispatched once
 * cancellation is observed; an already-running callback finishes normally. */
void jsti_audio_device_monitor_cancel(JSTIAudioDeviceMonitor *monitor);
/* Cancels, unregisters off the notification callback, drains and joins. The
 * caller retains context until success. Returns -1 without destroying when
 * called by the snapshot worker, preventing self-join. Do not call concurrently
 * with another destroy. Call outside the UI/actor after the window loop ends. */
int jsti_audio_device_monitor_destroy(JSTIAudioDeviceMonitor *monitor, char *error, size_t error_capacity);
int jsti_audio_device_monitor_self_test(char *error, size_t error_capacity);

typedef struct JSTIHistoryRow {
    const char *id;
    const char *title;
    const char *detail;
    /* The History card, worded by the shared DesktopHistoryRowSummary. Each may
     * be null or empty, which hides its badge. tone: 0 transcribed, 1 failed,
     * 2 not yet transcribed. */
    const char *created;
    const char *audio_length;
    const char *cost;
    const char *preview;
    const char *models;
    const char *context;
    int tone;
} JSTIHistoryRow;

typedef struct JSTIHistoryFilterModel {
    const char *id;
    const char *name;
    int selected;
} JSTIHistoryFilterModel;
/* Copies the complete used-model catalogue and current filter. Dates are
 * Gregorian YYYY-MM-DD, or empty for no boundary. Safe from any thread. */
int jsti_window_set_history_filters(const JSTIHistoryFilterModel *models, size_t count,
                                    int errors_only, const char *from_day, const char *through_day);

/* Preformatted History totals, as the Mac dashboard shows them. */
typedef struct JSTIInsights {
    const char *sessions;
    const char *errors;
    const char *recording_time;
    const char *average_length;
    const char *spend;
} JSTIInsights;
/* The dashboard totals (`all` saved records) and the History header totals
 * (`visible`, the records the search shows). Thread safe; coalesced. */
int jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible);

/* The window's pages, in sidebar order. */
enum {
    JSTI_PAGE_DASHBOARD = 0, JSTI_PAGE_HISTORY, JSTI_PAGE_VOICE_OUTPUT, JSTI_PAGE_GENERAL, JSTI_PAGE_TRANSCRIPTION,
    JSTI_PAGE_POST_PROCESSING, JSTI_PAGE_PROFILES, JSTI_PAGE_KEYBOARD, JSTI_PAGE_CLOUD_SYNC, JSTI_PAGE_ABOUT,
    JSTI_PAGE_COUNT
};
/* Shows a JSTI_PAGE_* page, as its sidebar button does. Thread safe. */
int jsti_window_show_page(int page);
/* Window-local bindings from SpeakCore. Missing destinations are not bound.
 * Hiding hints changes presentation only. Strings are copied before return. */
typedef struct {
    const char *destination;
    int digit;
    const char *hint;
} JSTISidebarShortcut;
int jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int show_hints);

typedef struct {
    int32_t compact;
    int32_t page_padding, section_spacing, card_padding, content_spacing, inline_spacing, group_spacing;
    int32_t minimum_row_height;
} JSTIVisualDensity;
int jsti_window_set_visual_density(JSTIVisualDensity density);
/* General > Theme: 0 follows Windows, 1 light, 2 dark. Safe before or while
 * the window runs; a user choice emits JSTI_EVENT_APPEARANCE with "0"-"2". */
int jsti_window_set_appearance(int appearance);
/* The recording HUD: a topmost, click-through card at the bottom centre of the
 * foreground window's screen that never takes focus. phase is the shared
 * DesktopHUDState.Phase: 0 hidden, 1 recording (level meter and live_text),
 * 2 transcribing, 3 post-processing, 4 delivering, 5 success (hides after
 * 2.4 s), 6 failure (hides after 6 s). Each new phase restarts its clock.
 * Thread safe and latest-only; -1 for invalid UTF-8, phase or length. */
int jsti_window_set_hud(int phase, const char *headline, const char *subheadline, const char *live_text,
                        int display_milliseconds, int compact);
int jsti_window_set_hud_layout(int phase, const char *headline, const char *subheadline, const char *live_text,
                               int display_milliseconds, int compact, int expanded);
/* Shows every page, then the dashboard and History in dark mode, then the
 * dashboard while recording, saving each as `directory`\NN-name.bmp once
 * drawn, then closes the window. Thread safe. */
int jsti_window_screenshot_tour(const char *directory, char *error, size_t error_capacity);
/* Atomically replaces history; synchronously deep-copies all UTF-8 strings.
 * selected_id: null preserves the current selection if it still exists, an
 * empty string clears it. A user selection made after enqueue takes precedence.
 * Programmatic updates do not emit selection events.
 * Events 9-12 and 16 carry the selected record ID in their borrowed text
 * argument. Rows are whatever the host chose to show (for example a search
 * result); the window never filters, reorders or edits them itself. Clearing
 * or changing the selected row also resets the displayed transcript variant
 * until the host reports one. */
int jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id);
/* Complete retained IDs, including filtered-out rows. Copied for Clear confirmation. */
int jsti_window_set_history_management(const char *identifiers);
/* Which retained transcript the window shows for record_id. It is applied only
 * while that record is still the selected row, so a late report can never
 * describe a different record; null/empty record_id clears the control.
 * selected: -1 none, 0 processed, 1 original. can_switch (0/1) lets the user
 * choose between both versions; otherwise the control only reports the one
 * displayed. Thread safe; updates coalesce with jsti_window_update. A user
 * choice emits TRANSCRIPT_VARIANT and is retained until the selection changes. */
int jsti_window_set_transcript_variant(const char *record_id, int selected, int can_switch);
/* Copies one complete saved-record presentation. UI applies only to the current
 * record and requested version; selection changes clear text/actions meanwhile.
 * selected: 0 processed, 1 original, -1 no result. Thread-safe, latest-only. */
int jsti_window_set_history_presentation(const char *record_id, int selected, int can_switch,
    const char *transcript_utf8, const char *status_utf8);
/* Snapshot this window's displayed transcript on its UI thread before an action
 * or modal dialog. Returns 0 including valid empty text, 2 when the buffer is too
 * small (required includes NUL), or -1 when unavailable/invalid/over 8 MiB UTF-8.
 * Passing null/0 queries capacity. Never falls back to saved or external text. */
int jsti_window_transcript_snapshot(char *text_utf8, size_t capacity, size_t *required);
/* The displayed transcript variant: -1 none, 0 processed, 1 original. UI thread
 * only; call synchronously from the COPY_TRANSCRIPT, HISTORY_EXPORT or
 * TRANSCRIPT_VARIANT callback so it pairs with that event's record ID. */
int jsti_window_transcript_variant(void);
/* Record-bound native playback display for the History pane. state: 0 idle,
 * 1 preparing, 2 playing, 3 paused. time_text is the host-formatted
 * elapsed/remaining text (null keeps the idle placeholder). The report is
 * applied only while record_id is still the selected row, so a late report can
 * never describe another record; a null/empty record_id resets the controls.
 * Selecting another row also resets the display to idle until the host
 * reports again. Play/Pause is enabled for a selected idle record or while a
 * playback is active; Stop only while a playback is active. Thread safe;
 * latest-only, coalesced with jsti_window_update. Never touches the status or
 * transcript text. */
int jsti_window_set_playback(const char *record_id, int state, const char *time_text);
/* Call synchronously from the UI event callback, capturing the event's record
 * ID first. Returns 0 chosen (UTF-8 path), 1 cancelled, -1 failed. A too-small
 * output buffer is an error; paths are never silently truncated. */
int jsti_window_choose_export_path(const char *suggested_filename, char *path, size_t path_capacity,
                                   char *error, size_t error_capacity);
/* Opens an existing audio file through its registered Windows application.
 * Only recognised audio filename extensions are accepted; never executes an
 * arbitrary imported file. Shell activation errors are returned. */
int jsti_shell_open_file(const char *path, char *error, size_t error_capacity);
/* Reveals an existing directory in Explorer; never opens a file association. */
int jsti_shell_open_directory(const char *path, char *error, size_t error_capacity);
int jsti_window_confirm_audio_cleanup(const char *token, size_t count, char *error, size_t error_capacity);
int jsti_window_show_migration_report(const char *text, char *error, size_t error_capacity);

/* Atomic Apply callback from the native settings dialog, on the UI thread.
 * prompt/new_key are borrowed until return. Empty new_key means keep the saved
 * credential; no saved credential is read back into the password field. */
typedef void (*JSTIPostProcessingCallback)(int enabled, int model_index, int include_directives, int include_tags,
                                          const char *prompt,
                                          const char *new_key, void *context);
/* Thread safe; deep-copies labels/settings. local_index identifies the sole
 * built-in rules entry in the shared projection; -1 selected means unavailable.
 * Callback indexes refer to this full projection, not a filtered picker row.
 * remembered_remote_index is dormant picker recall; -1 requires explicit choice. */
int jsti_window_set_postprocessing(const char *const *model_names, size_t model_count,
                                   int selected_index, int enabled, int local_index, int remembered_remote_index,
                                   const char *local_notice, int include_directives, int include_tags, const char *prompt,
                                   JSTIPostProcessingCallback callback, void *context);

/* Stable text output choices across the native boundary. restore_clipboard is
 * 0/1 and only affects a Smart paste at the cursor; the dialog keeps every
 * stored choice even while it is irrelevant to the selected method. */
enum JSTITextOutputMethod {
    JSTI_TEXT_OUTPUT_SMART = 0,
    JSTI_TEXT_OUTPUT_DIRECT_ONLY = 1,
    JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY = 2
};
enum JSTITextOutputInsertion {
    JSTI_TEXT_OUTPUT_AT_CURSOR = 0,
    JSTI_TEXT_OUTPUT_REPLACE_FIELD = 1
};
/* Atomic Apply from the native Text output dialog, on the UI thread: exactly
 * one complete snapshot per Apply. Cancel, Escape and closing emit nothing.
 * Return promptly; never wait for a Swift actor here. */
typedef void (*JSTITextOutputSettingsCallback)(int method, int insertion, int restore_clipboard, void *context);
/* Thread safe; valid before window_run and from any thread afterwards. Invalid
 * values or a null callback return -1 and keep the previous configuration.
 * The context is borrowed: keep it alive until a later configuration or
 * jsti_window_clear_text_output has replaced it AND any dialog opened from it
 * has closed, because an open dialog keeps its own copy of the callback and
 * context and can still Apply. No dialog is open once window_run returns. The
 * dialog opens from the latest configuration; refresh it with the persisted
 * choices after every save attempt so a reopened dialog never shows unsaved
 * choices. */
int jsti_window_set_text_output(int method, int insertion, int restore_clipboard,
                                JSTITextOutputSettingsCallback callback, void *context);
/* Reads the configuration the dialog will open with. -1 when unconfigured or
 * an output pointer is null. */
int jsti_window_text_output(int *method, int *insertion, int *restore_clipboard);
int jsti_window_set_app_switch(const char *title, const char *labels, int selection, const char *help);
/* During the synchronous Apply callback, reads that dialog's immutable draft. */
int jsti_window_app_switch_selection(void);
/* Thread safe. Drops the configured callback and context so no later dialog
 * can use them; the dialog is unavailable until configured again. A dialog
 * already open is unaffected and keeps its copied callback and context until
 * it closes, so the caller must retain the context until then as well. Once
 * window_run has returned no dialog is open, and clearing ends the borrow. */
void jsti_window_clear_text_output(void);

/* Global recording shortcut. modifiers combine MOD_ALT (1), MOD_CONTROL (2) and
 * MOD_SHIFT (4) and must include Ctrl or Alt; virtual_key is a non-modifier
 * virtual-key code. The Shortcut dialog lists style_names with their
 * descriptions; press_style is the index whose presses toggle recording
 * natively (TOGGLE_RECORDING, or CANCEL_TRANSCRIPTION while transcribing).
 * Every other style reports HOTKEY_DOWN on the press and HOTKEY_UP when the key
 * is released, for the host's gesture recognition; presses while a modal
 * dialog is open or a transcription is running are ignored. The callback runs
 * on the UI thread once per Apply, after the new shortcut is registered;
 * persist it and never wait for a Swift actor there. Thread safe; the
 * combination is registered when window_run starts and afterwards changes only
 * through the dialog. The context is borrowed like jsti_window_set_text_output's. */
typedef void (*JSTIHotKeySettingsCallback)(unsigned modifiers, unsigned virtual_key, int style, void *context);
int jsti_window_set_hotkey(unsigned modifiers, unsigned virtual_key,
                           const char *const *style_names, const char *const *style_descriptions,
                           size_t style_count, int style, int press_style,
                           JSTIHotKeySettingsCallback callback, void *context);
/* Drops the callback and context; the dialog is unavailable until configured again. */
void jsti_window_clear_hotkey(void);
/* UI thread only, from a hotkey event: arms the one gesture deadline timer,
 * which later sends HOTKEY_DEADLINE. Negative milliseconds cancel it. */
int jsti_window_set_hotkey_deadline(int milliseconds);
/* Voice output dialog: the canonical voices the host can speak with, as
 * UTF-8 labels, and the selected index. The callback runs on the UI thread
 * once per Apply with the chosen index. Thread safe; the context is borrowed
 * like jsti_window_set_text_output's. */
typedef void (*JSTIVoiceOutputCallback)(int voice, void *context);
int jsti_window_set_voice_output(const char *const *voice_names, size_t voice_count, int selected,
                                 JSTIVoiceOutputCallback callback, void *context);
void jsti_window_clear_voice_output(void);
/* Azure Speech resource dialog: the HTTPS endpoint of the user's Azure Speech
 * or Foundry resource, shown and edited as UTF-8 text (empty when none is
 * saved). Azure live transcription connects only to that resource; recorded
 * audio uses it when set. The callback runs on the UI thread once per Apply
 * with the entered text. It validates synchronously, never waiting for a Swift
 * actor, and returns 0 to accept, which closes the dialog, or -1 after writing
 * a readable reason into error, which the dialog shows while it stays open.
 * Thread safe; the context is borrowed like the voice dialog's. */
typedef int (*JSTIAzureResourceCallback)(const char *endpoint, void *context, char *error, size_t error_capacity);
int jsti_window_set_azure_resource(const char *endpoint, JSTIAzureResourceCallback callback, void *context);
void jsti_window_clear_azure_resource(void);
/* Local models dialog: rows of the on-device models the host offers, in the
 * host's order, with their install state. Thread safe; an open dialog refreshes
 * in place. The callback runs on the UI thread with one action and the row
 * index (-1 for the GPU choice); it must return promptly and never block on a
 * Swift actor. The runtime status is also shown under the model picker while
 * the Local source is selected. The context is borrowed like the voice
 * dialog's. */
enum JSTILocalModelState {
    JSTI_LOCAL_MODEL_NOT_INSTALLED = 0,
    JSTI_LOCAL_MODEL_PARTIAL = 1,
    JSTI_LOCAL_MODEL_DOWNLOADING = 2,
    JSTI_LOCAL_MODEL_INSTALLED = 3
};
enum JSTILocalModelAction {
    JSTI_LOCAL_MODEL_DOWNLOAD = 1,
    JSTI_LOCAL_MODEL_CANCEL = 2,
    JSTI_LOCAL_MODEL_REMOVE = 3,
    JSTI_LOCAL_MODEL_GPU_ON = 4,
    JSTI_LOCAL_MODEL_GPU_OFF = 5
};
typedef struct JSTILocalModelRow {
    const char *name;
    const char *detail;
    const char *about;
    int state;
} JSTILocalModelRow;
typedef void (*JSTILocalModelCallback)(int action, int model_index, void *context);
/* Borrowed strings, copied by the callback before returning. cancel != 0
 * cancels only metadata discovery, not an installed model or download. */
typedef void (*JSTILocalModelImportCallback)(const char *repository, const char *filename, int cancel, void *context);
void jsti_window_set_local_model_import_callback(JSTILocalModelImportCallback callback);
int jsti_window_set_local_models(const JSTILocalModelRow *rows, size_t count, const char *runtime_status,
                                 int use_gpu, JSTILocalModelCallback callback, void *context);
void jsti_window_clear_local_models(void);
/* Thread safe: checks or clears the Settings menu's automation item. */
int jsti_window_set_automation(int enabled);
/* Thread safe: General's Launch at login switch shows the shared
 * DesktopLoginItemState (0 off, 1 on, 2 off by the system, 3 on by policy,
 * 4 unavailable); only 0 and 1 can be changed there. `detail` is the note. */
int jsti_window_set_login_item(int state, const char *detail);

/* Launch at login (WindowsLoginItem.cpp). The portable app registers
 * `"<exe>" --background` under HKCU\...\Run and honours Task Manager's
 * StartupApproved switch; the MSIX app uses its declared windows.startupTask.
 * Both may block for a few seconds: never call them on the UI thread. state
 * and `reached` are the shared DesktopLoginItemState. */
int jsti_login_item_state(void);
int jsti_login_item_set(int enabled, int *reached, char *error, size_t error_capacity);
/* 1 when this process was started with the login argument (--background). */
int jsti_login_item_launched(void);
/* Portable: registers, disables as Task Manager does, re-enables and removes a
 * Run value of its own, never the user's. Packaged: reads the startup task,
 * and turns it on and off again only when it is plainly off. */
int jsti_login_item_self_test(char *error, size_t error_capacity);
/* The localised key name, for example "Ctrl+Alt+Space". */
int jsti_hotkey_name(unsigned modifiers, unsigned virtual_key, char *name, size_t capacity);

/* Borrowed UTF-8 draft values. Choice -1 inherits the app setting, -2 preserves
 * an existing unavailable value, otherwise indexes the supplied catalogue.
 * polish_mode: 0 inherit, 1 disabled, 2 enabled. Paths are newline-separated. */
typedef struct JSTIProfileDraft {
    const char *id, *name, *paths, *prompt, *output_language, *notes;
    int transcription, polish_mode, polish_model, language;
} JSTIProfileDraft;
/* UI-thread callback: action 1 validates/copies all drafts for an atomic save;
 * return -1 with a readable error to keep the editor open. Action 0 cancels.
 * All pointers expire on return. Never block waiting for a Swift actor. */
typedef int (*JSTIProfilesCallback)(int action, const JSTIProfileDraft *drafts, size_t count,
                                  void *context, char *error, size_t error_capacity);
int jsti_window_set_profiles(const JSTIProfileDraft *drafts, size_t count,
                            const char *const *transcription_names, size_t transcription_count,
                            const char *const *polish_names, size_t polish_count,
                            const char *const *language_names, size_t language_count,
                            const char *notice,
                            JSTIProfilesCallback callback, void *context);
/* Posts an open request to the native UI thread. Ignored during recording. */
void jsti_window_request_profiles(void);

typedef struct JSTICapture JSTICapture;
/* Active capture endpoints only; the default marker means eCommunications.
 * Callbacks run synchronously after enumeration succeeds; strings are borrowed
 * until callback return. A successful empty list means no active microphones.
 * Enumeration does not activate a microphone or request recording access. */
typedef void (*JSTIAudioDeviceCallback)(const char *id, const char *name, int is_default, void *context);
int jsti_audio_devices_enumerate(JSTIAudioDeviceCallback callback, void *context,
                                 char *error, size_t error_capacity);
/* Dedicated bounded writer callback, PCM16 little-endian mono at the capture's
 * sample rate: 16 kHz unless explicitly configured. Legacy constructors emit
 * 100 ms frames; create_with_options selects 20 or 100 ms. Stop flushes a final
 * partial frame without padding. Copy synchronously and return promptly.
 * Do not call capture stop/destroy from either callback. */
typedef void (*JSTIAudioCallback)(const int16_t *samples, size_t sample_count, void *context);
typedef void (*JSTIAudioErrorCallback)(const char *message, void *context);
/* Default communications microphone at 16 kHz. */
JSTICapture *jsti_capture_create(JSTIAudioCallback callback, JSTIAudioErrorCallback error_callback,
                                 void *context);
/* Copies the opaque endpoint ID and captures at 16 kHz. Null/empty chooses the
 * default communications microphone at start. An explicit ID must still be
 * active and a capture device; it never silently falls back to another
 * microphone. On success an error buffer is cleared rather than left stale. */
JSTICapture *jsti_capture_create_with_device(const char *device_id, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback error_callback, void *context,
                                             char *error, size_t error_capacity);
/* As create_with_device, capturing directly at sample_rate: exactly 16000 or
 * 24000 (OpenAI Realtime canonical PCM) Hz PCM16 mono. The Windows audio engine
 * converts to the selected rate in a single pass; frames carry sample_rate/10
 * samples. Any other rate fails here with a descriptive error before any
 * microphone is activated. The rate is fixed for the capture's lifetime; create
 * a new capture to change it. */
JSTICapture *jsti_capture_create_with_format(const char *device_id, uint32_t sample_rate,
                                             JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback error_callback, void *context,
                                             char *error, size_t error_capacity);
/* As create_with_format, with an explicit frame duration of exactly 20 or
 * 100 ms. Rejects other durations before device activation. PCM storage stays
 * fixed and the writer queue retains 12.8 seconds at either duration/rate.
 * This sets application batching only, not the audio driver's packet period.
 * Choose a duration compatible with the provider; AssemblyAI requires at least
 * 50 ms and should use 100 ms. Legacy constructors always retain 100 ms. */
JSTICapture *jsti_capture_create_with_options(const char *device_id, uint32_t sample_rate,
                                              uint32_t frame_milliseconds, JSTIAudioCallback callback,
                                              JSTIAudioErrorCallback error_callback, void *context,
                                              char *error, size_t error_capacity);
/* Serialize start/stop/destroy on the caller side. start reports initialization
 * errors synchronously; later device/stream failures invoke error_callback. */
int jsti_capture_start(JSTICapture *capture, char *error, size_t error_capacity);
int jsti_capture_stop(JSTICapture *capture, char *error, size_t error_capacity);
void jsti_capture_destroy(JSTICapture *capture);

/* Package-only owned capture, never selected by the production factory.
 * Calls are serialized by one owner, outside all native callbacks. run_id is
 * immutable for the handle lifetime; an owner slot must not be copied/reused.
 * Open may block in the OS and may return a partial non-null owner on failure.
 * Never pass this distinct handle to legacy capture_destroy.
 * Receipt size/version must be initialized by the caller. Only retire success
 * nulls the slot, after actual producer join and thread-affine resource release.
 * Audio failure is separate from safety: safe retirement can retain AUDIO_FAILED.
 * On control/join failure retain owner AND callback context for explicit retry. */
typedef struct JSTIOwnedCapture JSTIOwnedCapture;
enum {
    JSTI_OWNED_CAPTURE_VERSION = 1,
    JSTI_OWNED_PRODUCER_QUIESCED = 1,
    JSTI_OWNED_CALLBACKS_DRAINED = 2,
    JSTI_OWNED_AUDIO_FAILED = 4,
    JSTI_OWNED_RESOURCES_RETIRED = 8,
    JSTI_OWNED_OWNERSHIP_RETAINED = 16
};
typedef struct JSTIOwnedCaptureReceipt {
    uint32_t size;
    uint32_t version;
    uint32_t flags;
    uint64_t delivered_samples;
    char first_audio_error[1024];
} JSTIOwnedCaptureReceipt;
int jsti_owned_capture_open(JSTIOwnedCapture **owner, const char *run_id, const char *device_id,
                            uint32_t sample_rate, uint32_t frame_ms, JSTIAudioCallback audio,
                            JSTIAudioErrorCallback failure, void *context,
                            JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
int jsti_owned_capture_quiesce(JSTIOwnedCapture *owner, const char *run_id,
                               JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
int jsti_owned_capture_retire(JSTIOwnedCapture **owner, const char *run_id,
                              JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
/* Hardware-free qualification only: bits 1 stop-signal failure, 2 producer-join
 * failure, 4 writer-join failure (each once), 8 late audio error, 16 partial-open
 * failure. Uses real threads/events/Frames/writer; emits one final 73-sample tail.
 * No environment switch or production fallback selects this entrypoint. */
int jsti_owned_capture_open_fixture(JSTIOwnedCapture **owner, const char *run_id, uint32_t faults,
                                    uint32_t sample_rate, uint32_t frame_ms, JSTIAudioCallback audio,
                                    JSTIAudioErrorCallback failure, void *context,
                                    JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
int jsti_owned_capture_self_test(char *error, size_t capacity);

/* Legacy direct path, retained for source/ABI compatibility. Capture at the
 * recording hotkey before showing UI. Insertion is explicitly addressed to the
 * original native Edit/RichEdit control only; other applications fail closed
 * and should offer Copy. This entrypoint never sends keystrokes or touches the
 * clipboard. New callers use the opaque jsti_insertion_* API below. */
typedef struct JSTITextTarget {
    uintptr_t window;
    uintptr_t focused_control;
    uint32_t process_id;
    uint32_t thread_id;
} JSTITextTarget;
int jsti_target_capture(JSTITextTarget *target, char *error, size_t error_capacity);
int jsti_target_insert_text(const JSTITextTarget *target, const char *text,
                            char *error, size_t error_capacity);
/* Deliberate user copy: plain CF_UNICODETEXT, eligible for clipboard history. */
int jsti_clipboard_write(const char *text, char *error, size_t error_capacity);
/* Read-only CF_UNICODETEXT snapshot, <=1 MiB UTF-8. Call off the UI thread.
 * Returns 1 for non-text. Free a successful snapshot with the matching function. */
int jsti_voice_command_clipboard_read(char **text, char *error, size_t error_capacity);
void jsti_voice_command_clipboard_free(char *text);

/* Opaque insertion target with explicit lifetime. Capture synchronously at the
 * recording hotkey: it records the foreground window, its thread and the
 * focused control immediately and never blocks on the target application. A
 * dedicated worker resolves the snapshotted focus event to its exact UI
 * Automation element so later insertion can prove field identity; startup
 * never waits for that provider. Every insertion re-verifies the original
 * process, thread, window and focused control, refuses password/read-only
 * fields and never steals focus or types into another application.
 *
 * Methods, in order of preference for the captured control:
 *  1. Native Unicode Edit/RichEdit: EM_REPLACESEL to the captured control
 *     (inserts at the caret or replaces the selection).
 *  2. UI Automation Value pattern SetValue, used only when it is exactly
 *     equivalent to insertion: the field is empty or the whole text is
 *     selected (or the replace-field flag is set). UI Automation's Text
 *     pattern is read-only and cannot insert; the field is never replaced
 *     wholesale to emulate a caret insertion.
 *  3. Guarded clipboard paste: the current clipboard is snapshotted, the text
 *     is placed as CF_UNICODETEXT excluded from clipboard history/cloud sync,
 *     Ctrl+V is sent while the captured control still owns focus, the field is
 *     read back through UI Automation where possible, and the previous
 *     clipboard content is restored unless it changed meanwhile.
 * Insertion into a process of higher integrity (for example an elevated app)
 * fails closed because Windows UIPI blocks both messages and input.
 *
 * Insert blocks the caller for a bounded time (about six seconds worst case)
 * and may be called at most once at a time per target. Destroy is nonblocking:
 * a worker still blocked inside a provider call is detached and
 * releases its own resources when that call returns. Destroy after insert
 * returns, never from another thread concurrently with insert. */
typedef struct JSTIInsertionTarget JSTIInsertionTarget;
enum JSTIInsertionFlags {
    /* Replace the whole field instead of inserting at the caret. Native
     * controls select all first; UI Automation requires a writable Value
     * pattern; the clipboard fallback is never used for replacement. */
    JSTI_INSERTION_REPLACE_FIELD = 1u << 0,
    /* Leave the transcript on the clipboard after a paste instead of
     * restoring the previous content (macOS "restore clipboard" off). */
    JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD = 1u << 1,
    /* Never paste through the clipboard. An explicit app-switch policy may
     * still request a recovery copy without sending keys. */
    JSTI_INSERTION_NO_PASTE_FALLBACK = 1u << 2,
    JSTI_INSERTION_ORIGINAL_APP = 1u << 3,
    JSTI_INSERTION_CURRENT_APP = 1u << 4,
    JSTI_INSERTION_ONLY_ORIGINAL_FRONT = 1u << 5
};
enum JSTIInsertionMethod {
    JSTI_INSERTION_METHOD_NONE = 0,
    JSTI_INSERTION_METHOD_NATIVE_EDIT = 1,
    JSTI_INSERTION_METHOD_UIA_VALUE = 2,
    JSTI_INSERTION_METHOD_PASTE = 3,
    JSTI_INSERTION_METHOD_CLIPBOARD = 4
};
enum JSTIInsertionIdentity {
    /* Process, thread, foreground window and focused control matched. */
    JSTI_INSERTION_IDENTITY_WINDOW = 1,
    /* Additionally the same UI Automation element that had focus at capture. */
    JSTI_INSERTION_IDENTITY_FIELD = 2
};
enum JSTIInsertionClipboard {
    JSTI_INSERTION_CLIPBOARD_UNTOUCHED = 0,
    JSTI_INSERTION_CLIPBOARD_RESTORED = 1,
    /* Restored what fit; oversized or non-memory formats were not preserved. */
    JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY = 2,
    /* The transcript was intentionally left on the clipboard. */
    JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT = 3,
    JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED = 4,
    /* Another application changed the clipboard meanwhile; it was left alone. */
    JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE = 5
};
typedef struct JSTIInsertionResult {
    int method;    /* JSTIInsertionMethod */
    int verified;  /* 1 when the field was read back and contains the text */
    int identity;  /* JSTIInsertionIdentity */
    int clipboard; /* JSTIInsertionClipboard */
} JSTIInsertionResult;
/* Start the bounded focus-event observer during normal application startup. */
void jsti_insertion_prepare(void);
/* Null with an error when no external application field is focused. */
JSTIInsertionTarget *jsti_insertion_capture(char *error, size_t error_capacity);
/* Zero: input was submitted by result->method; verified reports read-back.
 * -1: no text mutation was submitted. 1: mutation may have occurred or shortcut
 * submission was partial; do not retry automatically. Clipboard state is
 * reported in result->clipboard. Text must be non-empty UTF-8. */
int jsti_insertion_insert(JSTIInsertionTarget *target, const char *text, unsigned flags,
                          JSTIInsertionResult *result, char *error, size_t error_capacity);
/* Thread-safe nonblocking abandonment. Prevents pending mutations; an operation
 * already dispatched may complete, and insert then reports its actual/uncertain
 * outcome. The target remains owned until insert returns and destroy is called. */
void jsti_insertion_cancel(JSTIInsertionTarget *target);
/* Blocking, bounded worker request; never call on the UI/audio/host actor.
 * original nonnull captures only the exact acknowledged insertion's UIA range.
 * original null samples that range once. Identity/context changes refuse learning. */
int jsti_insertion_learning(JSTIInsertionTarget *target, const char *original,
                            char *edited, size_t edited_capacity, char *error, size_t error_capacity);
/* Explicit clipboard-only output, guarded by the captured request's cancellation
 * state immediately before replacement. Does not follow or mutate field focus. */
int jsti_insertion_copy_text(JSTIInsertionTarget *target, const char *text, JSTIInsertionResult *result,
                              char *error, size_t error_capacity);
/* Original captured process handle, never a fresh focus/PID lookup. required_bytes
 * includes the NUL; 0 success, 2 insufficient buffer, -1 unavailable. */
int jsti_insertion_executable_path(const JSTIInsertionTarget *target, char *path, size_t path_capacity,
                                   size_t *required_bytes, char *error, size_t error_capacity);
void jsti_insertion_destroy(JSTIInsertionTarget *target);

/* Automatic clipboard output for one completed recording whose method is copy
 * to clipboard, including recordings started with Record in this window, which
 * have no captured field. It never queries or follows focus, never inserts and
 * never sends input. The transcript is left as plain Unicode text, exactly like
 * jsti_insertion_copy_text and jsti_clipboard_write: an ordinary copy without
 * the guarded paste's history and cloud exclusion formats. A job copies at
 * most once. */
typedef struct JSTIClipboardOutput JSTIClipboardOutput;
/* Allocates a job without touching the clipboard. */
JSTIClipboardOutput *jsti_clipboard_output_create(char *error, size_t error_capacity);
/* Blocks for a bounded time; call off the UI thread and outside actors. A
 * cancelled job, or one used by an earlier attempt, is refused before the text
 * is read or the clipboard opened; any other attempt uses the job up.
 * Otherwise the clipboard is opened (10 attempts, 20 ms apart) and its content
 * snapshotted; then, while it is still owned, cancellation is checked under the
 * job's lock immediately before replacement. A cancel that returned before
 * that check guarantees no clipboard change; a later cancel cannot stop the
 * committed write, which is reported. 0 copied; -1 nothing copied, and
 * clipboard_state (JSTIInsertionClipboard, optional) reports whether a failed
 * write restored the previous content. Text must be non-empty UTF-8. */
int jsti_clipboard_output_copy(JSTIClipboardOutput *job, const char *text, int *clipboard_state,
                               char *error, size_t error_capacity);
/* Thread safe and nonblocking, including while copy runs on another thread. */
void jsti_clipboard_output_cancel(JSTIClipboardOutput *job);
/* Call once, after copy has returned or when it was never called. */
void jsti_clipboard_output_destroy(JSTIClipboardOutput *job);
/* Synthetic in-memory clipboard only: copy, cancellation before and inside the
 * owned section, single use, failed-write restore and bounded busy failure.
 * Never touches the system clipboard. */
int jsti_clipboard_output_self_test(char *error, size_t error_capacity);

/* Deterministic native checks on app-owned synthetic hidden controls with
 * injected foreground, clipboard and keystroke seams: caret/selection
 * insertion, surrogate pairs, stale identity, password/read-only refusal,
 * UI Automation value/paste paths, timeouts and worker cleanup. Never sends
 * real input, touches the system clipboard or inserts into another app. */
int jsti_text_output_self_test(char *error, size_t error_capacity);

/* Generic credentials scoped to this Windows user; names are automatically
 * prefixed with com.justspeaktoit/. Read: 1 missing, 2 buffer too small (required
 * byte count returned). No terminator is appended to credential bytes. */
int jsti_credential_write(const char *name, const uint8_t *bytes, size_t count,
                          char *error, size_t error_capacity);
int jsti_credential_read(const char *name, uint8_t *bytes, size_t capacity, size_t *count,
                         char *error, size_t error_capacity);
int jsti_credential_delete(const char *name, char *error, size_t error_capacity);

/* App-owned sensitive-file staging only. Absolute local paths; relative paths,
 * alternate data streams and all reparse points in the path are rejected.
 * Directory preparation creates/repairs only the supplied leaf directory; its
 * parent must exist and an existing leaf must belong to the current user.
 * Both APIs apply an explicit protected DACL granting only the current user
 * and SYSTEM full control. File creation is exclusive: existing files are
 * never opened, truncated or followed. No parent ACL is changed. */
int jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
/* Exclusive private leaf creation, including explicit current-user ownership
 * when the process is elevated. An existing directory is never changed. */
int jsti_private_directory_create(const char *path, char *error, size_t error_capacity);
int jsti_private_file_create(const char *path, char *error, size_t error_capacity);
/* Opt-in held capture capability; not wired to the host/default Swift factory.
 * root must already exist. IDs must be UUID strings. Creation is exclusive in
 * a new private UUID directory and never repairs the caller-selected root.
 * Reuses private-staging ACLs and pinned, non-reparse ancestor traversal.
 * Calls must be serialized. Destroy exactly once, after close; destroy also
 * closes an abandoned capability, but never deletes retained audio.
 * Discard marks only the held file for deletion; directories are never removed.
 * Close is idempotent and reports teardown failures without retrying handles. */
typedef struct JSTIOwnedCaptureFile JSTIOwnedCaptureFile;
int jsti_owned_capture_file_create(const char *root, const char *directory_id, const char *recording_id,
                                   JSTIOwnedCaptureFile **result, char *error, size_t error_capacity);
int jsti_owned_capture_file_write(JSTIOwnedCaptureFile *file, const uint8_t *bytes, size_t count,
                                  char *error, size_t error_capacity);
int jsti_owned_capture_file_seek(JSTIOwnedCaptureFile *file, uint64_t offset,
                                 char *error, size_t error_capacity);
int jsti_owned_capture_file_flush(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_validate(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_discard(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_close(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
void jsti_owned_capture_file_destroy(JSTIOwnedCaptureFile *file);
/* Native qualification fixture. Caller supplies an exclusively owned
 * test root; only new UUID children and synthetic bytes are used. */
int jsti_owned_capture_file_self_test(const char *root, char *error, size_t error_capacity);
/* Copies a private regular source into private destination-side staging, then
 * publishes exclusively. The source is retained. 0 committed, 2 cancelled
 * before commit, -1 failed, 3 committed with a handle-cleanup error (never
 * retry or delete that destination). Cancellation is checked between bounded chunks.
 * Existing destinations and reparse paths are never replaced or followed. */
typedef int (*jsti_file_publication_cancelled_fn)(void *context);
/* Opt-in private immutable recording namespace. Identity is native FILE_ID_INFO,
 * never a Foundation systemFileNumber conversion. initialize exclusively creates
 * the named namespace; open never repairs permissions or manufactures missing records.
 * append returns 0 success, 2 cancelled, -1 failure; published is set once rename
 * commits, including post-commit cancellation/close failure. Never retry/delete a
 * published leaf. Every writer is closed before append returns. Maximum leaf 16 KiB;
 * enumeration caps at 4096 NUL-terminated ASCII names. The verified provider must
 * enforce the aggregate byte/record budget and decode/bind records before granting authority.
 * Held directory sharing excludes a competing namespace capability and replacement;
 * callers serialize operations and do not close/destroy during another call. */
typedef struct JSTIRecordingRegistry JSTIRecordingRegistry;
int jsti_recording_registry_open(const char *history, int initialize, JSTIRecordingRegistry **result,
                                 char *error, size_t error_capacity);
int jsti_recording_registry_identity(JSTIRecordingRegistry *registry, uint64_t *history_volume,
                                     uint8_t *history_id16, uint64_t *namespace_volume, uint8_t *namespace_id16,
                                     char *error, size_t error_capacity);
int jsti_recording_registry_names(JSTIRecordingRegistry *registry, char *names, size_t names_capacity,
                                  size_t *written, uint32_t *count, char *error, size_t error_capacity);
int jsti_recording_registry_read(JSTIRecordingRegistry *registry, const char *name,
                                 uint8_t *bytes, size_t bytes_capacity, size_t *written,
                                 char *error, size_t error_capacity);
int jsti_recording_registry_append(JSTIRecordingRegistry *registry, const char *name,
                                   const uint8_t *bytes, size_t count,
                                   jsti_file_publication_cancelled_fn cancelled, void *context, int *published,
                                   char *error, size_t error_capacity);
int jsti_recording_registry_close(JSTIRecordingRegistry *registry, char *error, size_t error_capacity);
void jsti_recording_registry_destroy(JSTIRecordingRegistry *registry);
int jsti_recording_registry_self_test(const char *history, char *error, size_t error_capacity);
/* Qualification-only additive ABI. No shared POSIX identity conversion.
 * Caller supplies a writable outcome header (two uint32_t fields) describing
 * the entire available storage. Invalid version/size returns -1 without writes.
 * Valid outcomes preserve all causes; native codes are unsigned bit patterns.
 * Calls and destruction must be serialized; cancellation is synchronous and
 * borrowed. Close attempts are terminal even when native release is unconfirmed.
 * No published leaf is removed or retried. No raw native handle is exported. */
#define JSTI_REGISTRY_ABI_V2 2u
#define JSTI_REGISTRY_MAX_RESOURCES_V2 256u
#define JSTI_REGISTRY_MAX_CAUSES_V2 512u
#define JSTI_REGISTRY_MAX_LEAF_BYTES_V2 16384u
#define JSTI_REGISTRY_MAX_NAMES_V2 4096u
#define JSTI_REGISTRY_MAX_NAMES_BYTES_V2 262144u
#define JSTI_REGISTRY_MAX_PATH_UTF8_BYTES_V2 128000u
#define JSTI_REGISTRY_MAX_LEAF_NAME_BYTES_V2 64u
enum {
    JSTI_REGISTRY_DOMAIN_NONE_V2 = 0, JSTI_REGISTRY_DOMAIN_WIN32_V2 = 1,
    JSTI_REGISTRY_DOMAIN_NTSTATUS_V2 = 2, JSTI_REGISTRY_DOMAIN_HRESULT_V2 = 3,
    JSTI_REGISTRY_DOMAIN_CONTRACT_V2 = 4
};
enum { JSTI_REGISTRY_EFFECT_NOT_PUBLISHED_V2 = 0, JSTI_REGISTRY_EFFECT_PUBLISHED_V2 = 1 };
enum {
    JSTI_REGISTRY_CAUSE_PRIMARY_V2 = 1, JSTI_REGISTRY_CAUSE_SECONDARY_V2 = 2,
    JSTI_REGISTRY_CAUSE_CLEANUP_V2 = 3
};
enum {
    JSTI_REGISTRY_CONTRACT_INVALID_V2 = 1, JSTI_REGISTRY_CONTRACT_BUDGET_V2 = 2,
    JSTI_REGISTRY_CONTRACT_CLOSED_V2 = 3, JSTI_REGISTRY_CONTRACT_REENTRANT_V2 = 4,
    JSTI_REGISTRY_CONTRACT_CANCELLED_V2 = 5, JSTI_REGISTRY_CONTRACT_UNSUPPORTED_V2 = 6,
    JSTI_REGISTRY_CONTRACT_IDENTITY_V2 = 7, JSTI_REGISTRY_CONTRACT_CHANGED_V2 = 8,
    JSTI_REGISTRY_CONTRACT_TEARDOWN_UNCONFIRMED_V2 = 9, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2 = 10
};
enum {
    JSTI_REGISTRY_STAGE_ADMISSION_V2 = 1, JSTI_REGISTRY_STAGE_OPEN_V2 = 2,
    JSTI_REGISTRY_STAGE_IDENTITY_V2 = 3, JSTI_REGISTRY_STAGE_ENUMERATE_V2 = 4,
    JSTI_REGISTRY_STAGE_READ_V2 = 5, JSTI_REGISTRY_STAGE_WRITE_V2 = 6,
    JSTI_REGISTRY_STAGE_READONLY_V2 = 7, JSTI_REGISTRY_STAGE_FLUSH_V2 = 8,
    JSTI_REGISTRY_STAGE_PRECOMMIT_V2 = 9, JSTI_REGISTRY_STAGE_PUBLISH_V2 = 10,
    JSTI_REGISTRY_STAGE_POSTCOMMIT_V2 = 11, JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2 = 12,
    JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2 = 13, JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2 = 14,
    JSTI_REGISTRY_STAGE_FENCE_ACL_V2 = 15, JSTI_REGISTRY_STAGE_FENCE_ATTRIBUTES_V2 = 16,
    JSTI_REGISTRY_STAGE_FENCE_LINKS_V2 = 17, JSTI_REGISTRY_STAGE_DISCARD_V2 = 18,
    JSTI_REGISTRY_STAGE_CLOSE_V2 = 19, JSTI_REGISTRY_STAGE_DESTROY_V2 = 20
};
enum {
    JSTI_REGISTRY_CHECK_ADMISSION_V2 = 1, JSTI_REGISTRY_CHECK_PRECOMMIT_V2 = 2,
    JSTI_REGISTRY_CHECK_POSTCOMMIT_V2 = 3
};
typedef struct { uint64_t volume_serial; uint8_t file_id[16]; } JSTIRegistryIdentityV2;
typedef struct {
    uint32_t kind, domain, native_code, stage;
    uint64_t resource_id;
} JSTIRegistryCauseV2;
typedef struct {
    uint32_t abi_version, struct_size, effect, cause_count, primary_index, cleanup_count;
    uint32_t close_attempt_count, release_unconfirmed_count, capability_poisoned;
    JSTIRegistryCauseV2 causes[JSTI_REGISTRY_MAX_CAUSES_V2];
} JSTIRegistryOutcomeV2;
typedef struct JSTIRecordingRegistryV2 JSTIRecordingRegistryV2;
typedef int (*jsti_registry_cancelled_v2_fn)(void *context, uint32_t checkpoint);
int jsti_recording_registry_open_v2(const uint8_t *history_utf8, size_t history_count, int initialize,
                                   JSTIRecordingRegistryV2 **result, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_identity_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryIdentityV2 *history,
                                       JSTIRegistryIdentityV2 *namespace_identity, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_names_v2(JSTIRecordingRegistryV2 *registry, uint8_t *names, size_t capacity,
                                    size_t *written, uint32_t *count, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_read_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t name_count,
                                   uint8_t *bytes, size_t capacity, size_t *written, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_append_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t name_count,
                                     const uint8_t *bytes, size_t count, jsti_registry_cancelled_v2_fn cancelled,
                                     void *context, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_validate_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_close_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_destroy_v2(JSTIRecordingRegistryV2 **registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_private_file_publish(const char *source, const char *destination,
                              jsti_file_publication_cancelled_fn cancelled, void *context,
                              char *error, size_t error_capacity);
/* Uses a unique temporary directory and synthetic bytes only; verifies ACLs,
 * directory repair, existing-file preservation and junction refusal. */
int jsti_private_storage_self_test(char *error, size_t error_capacity);

typedef struct JSTIWebSocket JSTIWebSocket;
enum JSTIWebSocketEvent {
    JSTI_WEBSOCKET_OPEN = 1,
    JSTI_WEBSOCKET_TEXT = 2,
    JSTI_WEBSOCKET_BINARY = 3,
    JSTI_WEBSOCKET_SEND_COMPLETE = 4,
    JSTI_WEBSOCKET_CLOSED = 5,
    JSTI_WEBSOCKET_ERROR = 6
};
/* All callbacks run serially on one dedicated worker. Bytes are borrowed until
 * return; copy synchronously. Messages are complete and bounded to 4 MiB. Code
 * is the native error for ERROR/SEND_COMPLETE (zero means send succeeded), or
 * the peer close status for CLOSED. Error bytes never include URL/header data.
 * Callbacks may send or cancel, but must not destroy this socket. */
typedef void (*JSTIWebSocketCallback)(int event, const uint8_t *bytes, size_t count,
                                     int code, void *context);
/* Copies all inputs. wss is required except ws on literal loopback addresses
 * or localhost for local probes. Credentials in URLs and redirects are refused.
 * Header names/values are validated; WinHTTP owns the upgrade control headers. */
JSTIWebSocket *jsti_websocket_create(const char *url, const char *const *header_names,
                                     const char *const *header_values, size_t header_count,
                                     JSTIWebSocketCallback callback, void *context,
                                     char *error, size_t error_capacity);
int jsti_websocket_start(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Copies at most 4 MiB. Exactly one send may be outstanding. A return of zero
 * guarantees one later SEND_COMPLETE callback, including during cancellation. */
int jsti_websocket_send(JSTIWebSocket *socket, const uint8_t *bytes, size_t count,
                        int is_text, char *error, size_t error_capacity);
/* Thread safe cancellation, including during the HTTP upgrade. No join. */
void jsti_websocket_cancel(JSTIWebSocket *socket);
/* Serialize destruction against all caller API calls. Cancels, drains native
 * callbacks and joins the worker. On failure the socket/context remain owned
 * by the caller and must be retained; zero releases the socket permanently. */
int jsti_websocket_destroy(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Deterministic URL/header validation; no network or credentials. */
int jsti_websocket_self_test(char *error, size_t error_capacity);

/* ---- CloudKit sync -------------------------------------------------------- */

/* One HTTPS request through WinHTTP, for CloudKit Web Services. Blocking: call
 * perform from a worker thread. https is required except http to the literal
 * loopback address or localhost (local fake servers). Redirects, cookies,
 * credentials in the URL and automatic authentication are refused; responses
 * are never cached. headers is "Name: value" lines joined by CRLF, or NULL.
 * The URL and headers carry tokens: they are never copied into errors.
 * perform returns 0 with *status set, 1 when cancelled, 2 when the body exceeds
 * response_limit, 3 on timeout, 4 on a transient connection failure, and -1
 * on any other failure. After 0, body/headers stay valid until destroy. */
typedef struct JSTIHTTPRequest JSTIHTTPRequest;
JSTIHTTPRequest *jsti_http_request_create(void);
int jsti_http_request_perform(JSTIHTTPRequest *request, const char *method, const char *url,
                              const char *headers, const uint8_t *body, size_t body_count,
                              size_t response_limit, int timeout_milliseconds, int *status,
                              char *error, size_t error_capacity);
/* The response body and the raw CRLF-separated response headers (UTF-8). */
const uint8_t *jsti_http_request_body(const JSTIHTTPRequest *request, size_t *count);
const char *jsti_http_request_headers(const JSTIHTTPRequest *request);
/* Thread safe; a blocked perform returns 1 promptly. */
void jsti_http_request_cancel(JSTIHTTPRequest *request);
/* Never while perform runs on another thread. */
void jsti_http_request_destroy(JSTIHTTPRequest *request);

/* A one-connection-at-a-time HTTP listener on 127.0.0.1, for the Apple ID
 * sign-in callback and for loopback test servers. port 0 picks a free port.
 * accept waits up to timeout for one complete request (at most 1 MiB):
 * 0 success, 1 timeout, 3 cancelled, -1 failure. A connection that closes, or
 * sends no complete request within request_window_milliseconds (0: five
 * seconds), is dropped and listening goes on. respond writes raw bytes and
 * closes the connection. */
typedef struct JSTILoopbackListener JSTILoopbackListener;
typedef struct JSTILoopbackConnection JSTILoopbackConnection;
JSTILoopbackListener *jsti_loopback_listen(uint16_t port, int request_window_milliseconds, uint16_t *bound_port,
                                           char *error, size_t error_capacity);
int jsti_loopback_accept(JSTILoopbackListener *listener, int timeout_milliseconds,
                         JSTILoopbackConnection **connection, char *error, size_t error_capacity);
const uint8_t *jsti_loopback_request(const JSTILoopbackConnection *connection, size_t *count);
/* Who owns the socket at the other end, from the TCP table's owning process:
 * 0 a process of this process's user, 1 another user's, -1 when that cannot
 * be determined (including a process this user may not open). Only while the
 * peer's socket is open. */
int jsti_loopback_peer_owner(const JSTILoopbackConnection *connection);
int jsti_loopback_respond(JSTILoopbackConnection *connection, const uint8_t *bytes, size_t count);
void jsti_loopback_connection_destroy(JSTILoopbackConnection *connection);
/* Thread safe; a blocked accept returns 3 promptly. */
void jsti_loopback_cancel(JSTILoopbackListener *listener);
void jsti_loopback_destroy(JSTILoopbackListener *listener);

/* CNG primitives for the API-key sync envelope: PBKDF2-HMAC-SHA256, and
 * AES-256-GCM with a fresh random 96-bit nonce, no associated data and a
 * 128-bit tag kept apart from the ciphertext. open returns 1 when the tag does
 * not verify. All return -1 on other failures. */
int jsti_crypto_pbkdf2_sha256(const uint8_t *password, size_t password_count, const uint8_t *salt,
                              size_t salt_count, uint64_t iterations, uint8_t *key, size_t key_count,
                              char *error, size_t error_capacity);
int jsti_crypto_aes_gcm_seal(const uint8_t *key, size_t key_count, const uint8_t *plaintext, size_t count,
                             uint8_t *nonce12, uint8_t *ciphertext, uint8_t *tag16,
                             char *error, size_t error_capacity);
int jsti_crypto_aes_gcm_open(const uint8_t *key, size_t key_count, const uint8_t *nonce12,
                             const uint8_t *ciphertext, size_t count, const uint8_t *tag16,
                             uint8_t *plaintext, char *error, size_t error_capacity);
int jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t error_capacity);

/* Opens an https URL on an apple.com or icloud.com host in the default browser. */
int jsti_shell_open_sign_in_page(const char *url, char *error, size_t error_capacity);

/* The iCloud sync dialog (Settings menu). The host supplies a snapshot; the
 * dialog closes after one action and calls back on the UI thread with it:
 * 1 apply choices, 2 sign in, 3 sign out, 4 sync now. passphrase is the typed
 * API-key passphrase (empty when none) and is wiped when the callback returns.
 * Thread safe; the context is borrowed like jsti_window_set_voice_output's. */
typedef struct JSTICloudSyncView {
    const char *status;
    int available;
    int signed_in;
    int history_enabled;
    int key_import_enabled;
} JSTICloudSyncView;
typedef void (*JSTICloudSyncCallback)(int action, int history_enabled, int key_import_enabled,
                                      const char *passphrase, void *context);
int jsti_window_set_cloud_sync(const JSTICloudSyncView *view, JSTICloudSyncCallback callback, void *context);
void jsti_window_clear_cloud_sync(void);

typedef struct JSTIAudioConversion JSTIAudioConversion;
/* One completion on the dedicated conversion worker after start succeeds.
 * status: 0 success, 1 cancelled, -1 failure. Duration/sample_count describe the
 * actual canonical16kHz mono PCM16 output only on success. Error is borrowed
 * until callback returns. Retain context until destroy succeeds; never destroy
 * from this callback. The input is never changed. */
typedef void (*JSTIAudioConversionCallback)(int status, double duration_seconds,
                                           uint64_t sample_count, const char *error, void *context);
/* Absolute local regular-file input; maximum25,000,000 input/output bytes.
 * Output must not exist, and its parent must already have been prepared by
 * jsti_private_directory_prepare. Conversion uses installed Media Foundation
 * decoders; support for compressed formats depends on the Windows installation.
 * Partial outputs are removed by their owned handle on failure/cancellation. */
JSTIAudioConversion *jsti_audio_conversion_create(const char *input_path, const char *output_path,
                                                  JSTIAudioConversionCallback callback, void *context,
                                                  char *error, size_t error_capacity);
int jsti_audio_conversion_start(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Thread safe request. Pending sample reads are flushed on the worker;
 * cancellation is checked between setup stages and output writes. */
void jsti_audio_conversion_cancel(JSTIAudioConversion *conversion);
/* Serialize against caller operations. Cancels and joins; zero frees the job.
 * On failure retain the job/context and retry outside its callback thread. */
int jsti_audio_conversion_destroy(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Synthetic WAV decode/resample, bounds/collision/refusal/cancellation checks.
 * No microphone, credentials, provider requests, or user recordings. */
int jsti_audio_conversion_self_test(char *error, size_t error_capacity);

typedef struct JSTIAudioPlayback JSTIAudioPlayback;
/* Exactly one completion on the dedicated playback worker after start
 * succeeds. status: 0 finished (every decoded frame was consumed by the audio
 * engine), 1 cancelled, -1 failed. played_seconds is the source audio the
 * engine actually consumed when playback ended, on every status; it is 0 when
 * nothing was measured. error is borrowed until the callback returns and is
 * empty on success. Retain context until destroy succeeds; never destroy from
 * this callback. Never invoked under a native lock, never after destroy. */
typedef void (*JSTIAudioPlaybackCallback)(int status, double played_seconds, const char *error, void *context);
/* Absolute local regular-file input of 1 byte to 1 GiB (two hours of 24 kHz
 * PCM16 history is about 346 MB). Creation opens the file read-only with
 * write/delete sharing denied and refuses directories, non-disk files and a
 * leaf reparse point; that pinned handle is the only stream Windows decodes
 * from, so the source is never reopened by name or modified. Decoding uses the
 * installed in-process Media Foundation codecs and converts straight to the
 * default multimedia render endpoint's shared-mode mix format and rate; if the
 * decoder cannot produce that format it decodes float at the source rate and
 * the Windows audio engine converts. There is no forced transcription-rate
 * conversion, custom resampler, external player or transcription step; the
 * endpoint conversion may resample a high-rate source. Decoded audio is queued
 * through a fixed two-second ring (at most 64 MiB, typically under 1 MiB) into
 * an event-driven shared-mode WASAPI stream; each decoded sample is bounded to
 * four seconds of output (1 MiB to 64 MiB) before it is coalesced; file and
 * codec work never run on the render thread, which submits only real source
 * frames (never synthesised silence) so the reported position is the source
 * audio actually consumed. A missing Media Foundation (Windows N), a missing
 * codec, an empty decode, no active render endpoint, an invalidated device or an
 * engine that stops requesting audio all fail with a descriptive error; there
 * is no silent fallback, and a render failure wakes a decoder stalled on a
 * slow codec at once so the failure is reported promptly. Creation itself
 * does not touch any device. */
JSTIAudioPlayback *jsti_audio_playback_create(const char *input_path, JSTIAudioPlaybackCallback callback,
                                              void *context, char *error, size_t error_capacity);
/* Starts once. A cancelled or already started job is refused synchronously
 * without any callback. Zero guarantees exactly one later completion, which
 * may arrive before this call returns; serialize destroy after it returns. */
int jsti_audio_playback_start(JSTIAudioPlayback *playback, char *error, size_t error_capacity);
/* Thread safe, nonblocking commands handled by the render thread. Pause stops
 * the engine and freezes both the queued audio and the reported position;
 * resume starts it again from the same frames without re-decoding. A pause
 * requested before rendering begins holds the first frame; a long pause never
 * trips the no-render-event failure deadline and keeps the decoder bounded by
 * the fixed queue. Returns 0 requested, 1 ignored because playback already
 * ended, -1 no playback. Commands are idempotent. */
int jsti_audio_playback_pause(JSTIAudioPlayback *playback);
int jsti_audio_playback_resume(JSTIAudioPlayback *playback);
typedef struct JSTIAudioPlaybackSnapshot {
    int state;               /* 0 preparing, 1 playing, 2 paused, 3 ended (see the completion). */
    double position_seconds; /* Source audio actually consumed by the engine so far. */
    double duration_seconds; /* Container duration when the source reports one, otherwise -1. */
    /* Output acknowledgement: 0 the engine was never started, 1 it was started
     * (running or paused, so it may start again), 2 the render thread stopped
     * the stream (or ended without ever starting it) and it can never start
     * again. After cancel, 2 arrives as soon as the render thread has stopped
     * the WASAPI stream, well before the decoder teardown that destroy joins;
     * hosts wait for it before another audible playback or microphone capture
     * and treat a bounded wait that expires as a failure, not as silence.
     * After cancel has returned, 0 is also proof of quiet: each potential Start
     * reserves state 1 before checking cancellation, so a later reservation
     * cannot start an engine after the caller has observed 0. State 1 includes
     * an in-flight Start; never interpret it as quiet. A failed Stop retains 1
     * until the endpoint is released, rather than falsely acknowledging it. */
    int output_state;
} JSTIAudioPlaybackSnapshot;
/* Cheap cached read of atomics; safe from any thread at any rate, never
 * blocks. The position is stable while paused, monotonic while playing and
 * never advanced by queued or silent frames. Returns -1 for a null playback. */
int jsti_audio_playback_snapshot(const JSTIAudioPlayback *playback, JSTIAudioPlaybackSnapshot *snapshot);
/* Thread safe request; stops rendering promptly and unblocks decoding. */
void jsti_audio_playback_cancel(JSTIAudioPlayback *playback);
/* Serialize against caller operations, after start has returned. Cancels and
 * joins both native threads; zero frees the job and the pinned input handle.
 * Refuses to join itself from the completion callback and keeps the job and
 * context owned by the caller on any failure, so retry outside the callback
 * thread. Codec teardown may take a few seconds; hosts stop audibly through
 * cancel first and destroy off their UI/actor threads. */
int jsti_audio_playback_destroy(JSTIAudioPlayback *playback, char *error, size_t error_capacity);
/* Capability probe for callers and tests: 1 when Windows reports an active
 * default multimedia render endpoint, 0 when there is none, -1 when Windows
 * could not answer. Enumeration only; nothing is activated. A 1 does not
 * promise that a later playback succeeds, and playback failures must never be
 * reinterpreted as a missing endpoint. */
int jsti_audio_playback_endpoint_available(char *error, size_t error_capacity);
/* Deterministic checks on short low-amplitude synthetic WAV files in a unique
 * temporary directory, without any endpoint: fixed queue, input pinning and
 * limits, Media Foundation exact/converted decode, decoded-sample bound,
 * duration, cancellation of a stalled read, and the production render loop
 * driven by a synthetic engine: exact output bytes with no trailing silence,
 * source-position accounting through pause/resume/cancel/drain, pause before
 * start, event timeout, start failure, immediate completion, refused second
 * start, callback self-destroy refusal, and release of the pinned source.
 * Needs Media Foundation. Never uses recordings, credentials or a speaker. */
int jsti_audio_playback_self_test(char *error, size_t error_capacity);

/* Deterministic native checks: Unicode, 16/24 kHz frame boundaries, silence,
 * fixed queue capacity, writer drain, capture creation and sample-rate
 * validation, invalid insertion targets. Does not use microphone, clipboard or
 * real credentials. */
int jsti_native_self_test(char *error, size_t error_capacity);
int jsti_audio_devices_self_test(char *error, size_t error_capacity);
/* Call on the UI thread from READY in smoke-test mode. Verifies native control
 * bounds, history updates/events, search/filter selection handling, transcript
 * variant action identities, an invisible settings Apply round-trip and the Text
 * output dialog: every choice through its controls, Cancel/Escape/Enter,
 * keyboard order, minimum bounds and its modal loop blocking recording.
 * Restores history and text output configuration afterwards; never uses
 * microphone, clipboard or credentials. */
int jsti_window_self_test(char *error, size_t error_capacity);
/* Smoke-test diagnostics only: writes a 32-bit BMP of this application's client
 * window and controls. Call on the UI thread after READY. Never captures the
 * desktop or another app; caller provides a smoke-test state without secrets. */
int jsti_window_save_snapshot(const char *path, char *error, size_t error_capacity);

/* Streaming SHA-256 through Windows CNG (BCrypt). One object per digest;
 * finish writes 64 lowercase hex characters plus a terminator and ends the
 * object's use. destroy is always required. Never logs input bytes. */
typedef struct JSTISHA256 JSTISHA256;
JSTISHA256 *jsti_sha256_create(char *error, size_t error_capacity);
int jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error, size_t error_capacity);
int jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hex_capacity, char *error, size_t error_capacity);
void jsti_sha256_destroy(JSTISHA256 *hasher);

/* On-device transcription through whisper.cpp, loaded at run time.
 *
 * open loads whisper.dll (and the ggml DLLs beside it) from an absolute
 * directory with a restricted search path, checks the exact pinned
 * whisper.cpp version and registers ggml's dynamic backends from that
 * directory only: every CPU variant and, when allow_gpu is 1 and the system
 * Vulkan loader exists, Vulkan. A missing Vulkan loader is not an error; the
 * CPU runs instead. The runtime is process-wide and stays loaded once opened;
 * a second open must name the same directory. Implicit Vulkan layers (overlay
 * and capture hooks) are disabled for this process unless the user already
 * configured VK_LOADER_LAYERS_DISABLE. Returns NULL with an error when the
 * runtime is absent or does not match. */
typedef struct JSTIWhisperRuntime JSTIWhisperRuntime;
JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int allow_gpu,
                                              char *error, size_t error_capacity);
/* Writes a short UTF-8 description such as "whisper.cpp 1.9.4; GPU: Vulkan0
 * (NVIDIA ...); CPU" listing the registered devices. */
int jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity);
/* 1 when a GPU device is registered and would be used, otherwise 0. */
int jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime);

/* A cancellation token for one transcription. cancel is thread safe and may
 * be called before, during or after transcribe. */
typedef struct JSTIWhisperJob JSTIWhisperJob;
JSTIWhisperJob *jsti_whisper_job_create(void);
void jsti_whisper_job_cancel(JSTIWhisperJob *job);
void jsti_whisper_job_destroy(JSTIWhisperJob *job);

enum JSTIWhisperResult {
    JSTI_WHISPER_OK = 0,
    JSTI_WHISPER_FAILED = -1,
    JSTI_WHISPER_CANCELLED = 1,
    JSTI_WHISPER_MODEL_MISMATCH = 2
};
/* Transcribes 16 kHz mono float samples with the model at model_path (UTF-8,
 * absolute; read through a wide-character path), whose pinned SHA-256 is the
 * 64 hex digits model_sha256. Loading hashes every byte as it hands it to
 * whisper.cpp, through one open file, and a model whose bytes do not match is
 * freed unused with JSTI_WHISPER_MODEL_MISMATCH, so no byte that was not
 * verified is ever recognised with. The loaded model is cached for later calls
 * with the same path and digest and released when another model is used or
 * release_model is called. Calls are serialised. language is a Whisper code
 * such as "en", or NULL/empty to detect it; an unknown code detects it.
 * On success *text receives a heap UTF-8 string owned by the caller (free with
 * jsti_whisper_free_text). Returns a JSTIWhisperResult. */
int jsti_whisper_transcribe(JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256,
                            const float *samples, size_t sample_count, const char *language, int threads,
                            JSTIWhisperJob *job, char **text, char *error, size_t error_capacity);
void jsti_whisper_free_text(char *text);
/* Frees the cached model, waiting for a running transcription to finish. */
void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime);
/* Frees the cached model only if it was loaded from model_path (the path given
 * to jsti_whisper_transcribe), waiting for a running transcription to finish.
 * The check and the release are atomic with loading, so a model loaded in its
 * place stays cached. The loaded model's file is closed once loaded, so it may
 * already be deleted. Returns 1 when that model was freed, 0 when another model
 * or none is cached, and -1 for an invalid argument. */
int jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *model_path);

/* Independent predecoded recording-feedback channel. No History/TTS state is shared.
 * create does not open files/devices. prepare runs off UI, once; cancellation may
 * run concurrently. play/stop enqueue commands only. cue: 0=start, 1=stop;
 * gain is finite 0...1 and applied to PCM, never endpoint volume.
 * failure is borrowed during callback on the owned worker; context must outlive
 * destroy. Callback must not destroy or block waiting for this channel.
 * The stream stays warm with silence; stop discards the pending cue and
 * emits silence on the next render event. Already submitted audio is bounded
 * by the negotiated 50 ms-or-smaller buffer (plus endpoint hardware latency).
 * destroy joins off UI, after prepare returns; it reports cleanup failures.
 * Command functions return 0 on success, -1 with an explicit error on failure;
 * diagnostic getters/checks document their own success values below. */
typedef struct JSTIRecordingFeedback JSTIRecordingFeedback;
typedef void (*JSTIRecordingFeedbackFailure)(const char *error, void *context);
JSTIRecordingFeedback *jsti_recording_feedback_create(JSTIRecordingFeedbackFailure failure, void *context,
                                                      char *error, size_t error_capacity);
int jsti_recording_feedback_prepare(JSTIRecordingFeedback *feedback, const char *start_path, const char *stop_path,
                                    char *error, size_t error_capacity);
void jsti_recording_feedback_cancel_preparation(JSTIRecordingFeedback *feedback);
int jsti_recording_feedback_play(JSTIRecordingFeedback *feedback, int cue, float gain,
                                 char *error, size_t error_capacity);
/* Diagnostic only: 0 before the current play's first PCM buffer is released,
 * -1 with error if failed/cancelled, otherwise command-admission-to-ReleaseBuffer
 * seconds. A superseded play cannot publish into a newer play's measurement.
 * This is queue latency, NOT audible or hardware latency. No endpoint calls. */
double jsti_recording_feedback_first_buffer_latency(JSTIRecordingFeedback *feedback,
                                                   char *error, size_t error_capacity);
void jsti_recording_feedback_stop(JSTIRecordingFeedback *feedback);
/* 1 once this stop's first silence buffer is released, 0 while pending, -1
 * with error on failure. Old submitted audio may still be in hardware. */
int jsti_recording_feedback_stop_acknowledged(JSTIRecordingFeedback *feedback,
                                             char *error, size_t error_capacity);
int jsti_recording_feedback_destroy(JSTIRecordingFeedback *feedback, char *error, size_t error_capacity);
/* Codec-only installed-MF validation: exactly eight actual asset paths. No
 * endpoint is opened. Also checks the production PCM fill/gain/restart seam. */
int jsti_recording_feedback_self_test(const char *const *paths, size_t count, char *error, size_t error_capacity);
/* Same resident-renderer seam, independent of optional MF and audio hardware. */
int jsti_recording_feedback_renderer_self_test(char *error, size_t error_capacity);
/* Device-free installed-codec check of a profile's start/stop AAC assets.
 * Returns 2 after both bounded decodes and cleanup, -1 with an explicit error. */
int jsti_recording_feedback_check_assets(const char *start_path, const char *stop_path,
                                        char *error, size_t error_capacity);
/* The saved on-device live row (mode 3) restored when the user picks Local and
 * Live. Call after jsti_window_set_model_modes, which clears it, and before
 * window_run. -1 chooses the first local live row. Returns -1 when the index is
 * not a configured mode-3 row or the window is running. */
int jsti_window_set_preferred_local_live_model(int index);

#ifdef __cplusplus
}
#endif
#endif
