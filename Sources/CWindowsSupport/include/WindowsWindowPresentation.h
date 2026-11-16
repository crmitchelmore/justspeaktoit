#ifndef JSTI_WINDOWS_WINDOW_PRESENTATION_H
#define JSTI_WINDOWS_WINDOW_PRESENTATION_H
/* Main window presentation: insights, pages, settings search, HUD, History and playback. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "WindowsWindowRun.h"

#ifdef __cplusplus
extern "C" {
#endif

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

/* The window's pages, in sidebar order (the same order and values as Linux). */
enum {
    JSTI_PAGE_DASHBOARD = 0, JSTI_PAGE_HISTORY, JSTI_PAGE_VOICE_OUTPUT, JSTI_PAGE_GENERAL, JSTI_PAGE_TRANSCRIPTION,
    JSTI_PAGE_POST_PROCESSING, JSTI_PAGE_CORRECTIONS, JSTI_PAGE_PRONUNCIATION, JSTI_PAGE_PROFILES,
    JSTI_PAGE_KEYBOARD, JSTI_PAGE_CLOUD_SYNC, JSTI_PAGE_ABOUT, JSTI_PAGE_COUNT
};
/* Shows a JSTI_PAGE_* page, as its sidebar button does. Thread safe. */
int jsti_window_show_page(int page);

/* One settings search row. UTF-8; borrowed only during the call. */
typedef struct {
    const char *title;
    const char *detail;
    const char *identifier;
} JSTISettingsSearchResult;
/* Replaces the "Search for anything" results (UTF-8, at most 50: actions,
 * History and settings from the shared DesktopCommandPaletteSession) shown under
 * the sidebar's search box; an empty set shows "No results" while a query is
 * typed. Rows are read aloud as "<title>, <detail>". Strings are copied before
 * return. Thread safe and latest-only; -1 for invalid input or no window. */
int jsti_window_set_settings_search_results(const JSTISettingsSearchResult *results, size_t count);
/* Opens the preferences dialog on configuration field `index`'s group, scrolls
 * that field into view and focuses it; `index` is the field's position in the
 * array given to jsti_window_set_configuration(_revision). Thread safe; ignored
 * while recording or another dialog is open. -1 if out of range or unconfigured. */
int jsti_window_reveal_configuration_field(size_t index);
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
/* Shows a restore preview and answers MIGRATION_RESTORE_RESPONSE exactly once
 * with token. offers_replace enables the Replace choice. */
int jsti_window_confirm_migration_restore(const char *token, const char *text, int offers_replace,
                                          char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
