#ifndef JSTI_LINUX_WINDOW_PRESENTATION_H
#define JSTI_LINUX_WINDOW_PRESENTATION_H
/* Presentation updates: login item, automation, HUD, pages, shortcuts, density, text
 * output, post-processing, voices and snapshots. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "LinuxWindowEvents.h"

#ifdef __cplusplus
extern "C" {
#endif

/* General › Launch at login: the shared DesktopLoginItemState (0 off, 1 on,
 * 2 off by the system, 3 on by policy, 4 unavailable) and the note under it. */
int32_t jsti_window_set_login_item(int32_t state, const char *detail);
/* Actual listener state after local approval, not merely imported intent. */
int32_t jsti_window_set_automation(int32_t enabled, const char *detail);
/* The recording HUD. phase is the shared DesktopHUDState.Phase: 0 hidden,
 * 1 recording (level meter and live_text), 2 transcribing, 3 post-processing,
 * 4 delivering, 5 success (hides after 2.4 s), 6 failure (hides after 6 s);
 * each new phase restarts its clock. On X11 a click-through card above other
 * windows at the bottom centre of the active monitor that never takes focus;
 * on Wayland the result only, as a notification while the window is inactive.
 * Thread safe; -1 for an invalid phase or UTF-8. */
int32_t jsti_window_set_hud(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                            int32_t display_milliseconds, int32_t compact);
int32_t jsti_window_set_hud_layout(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                                   int32_t display_milliseconds, int32_t compact, int32_t expanded);
/* Shows a JSTI_PAGE_* page, as choosing it in the sidebar does. */
int32_t jsti_window_show_page(int32_t page);
/* Window-local bindings from SpeakCore; strings are copied before return.
 * Missing destinations are unavailable. Hints never control navigation. */
typedef struct {
    const char *destination;
    int32_t digit;
    const char *hint;
} JSTISidebarShortcut;
int32_t jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int32_t show_hints);

typedef struct {
    int32_t compact;
    int32_t page_padding, section_spacing, card_padding, content_spacing, inline_spacing, group_spacing;
    int32_t minimum_row_height;
} JSTIVisualDensity;
int32_t jsti_window_set_visual_density(JSTIVisualDensity density);
/* variant: 0 processed, 1 original, -1 none. */
int32_t jsti_window_set_history_presentation(
    const char *record_id, int32_t variant, int32_t switchable, const char *text, const char *status);
int32_t jsti_window_set_transcript_variant(const char *record_id, int32_t variant, int32_t switchable);
/* method: 0 paste into the focused app, 1 clipboard only. */
int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard,
                                   int32_t can_restore_clipboard, const char *shortcut_hint);
int32_t jsti_window_set_text_output_policy(
    int32_t method, int32_t restore_clipboard, int32_t can_restore_clipboard, const char *shortcut_hint,
    const char *policy_title, const char *policy_labels, int32_t policy_selection, const char *policy_help);
/* Full shared projection; local_index identifies built-in rules. Callback
 * indexes remain full-projection indexes; selected -1 requires a user choice.
 * remembered_remote_index is dormant picker recall; -1 requires explicit choice. */
int32_t jsti_window_set_post_processing(
    const char *const *models, size_t count, int32_t enabled, int32_t selected,
    int32_t local_index, int32_t remembered_remote_index, const char *local_notice,
    int32_t include_directives, int32_t include_tags, const char *prompt);
/* Shows the saved Azure Speech resource endpoint ("" for none). */
int32_t jsti_window_set_azure_resource(const char *endpoint);
/* The shortcut behaviour picker, indexed as JSTI_EVENT_SHORTCUT_STYLE. */
int32_t jsti_window_set_shortcut_style(int32_t index);
/* The Read aloud voices in picker order and the saved one. Read aloud is
 * offered once at least one voice is listed. */
int32_t jsti_window_set_voices(const char *const *names, size_t count, int32_t selected);
/* Main thread only: the transcript and version the window displays now. */
int32_t jsti_window_transcript_snapshot(char *buffer, size_t capacity, size_t *required);
int32_t jsti_window_transcript_variant(void);
void jsti_window_request_close(void);
/* 1 while this app's window has keyboard focus. Safe from any thread. */
int32_t jsti_window_is_active(void);
/* Desktop notification through GNotification (portal-backed in Flatpak). */
void jsti_notify(const char *title, const char *body);
/* Main thread only: renders the window to a PNG for visual review. */
int32_t jsti_window_save_snapshot(const char *path, char *error, size_t error_capacity);
/* Shows every page in turn (then a recording, then dark mode), saves each as
 * `directory`/NN-name.png once it has been drawn, then closes the window.
 * Safe from any thread. */
int32_t jsti_window_screenshot_tour(const char *directory, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
