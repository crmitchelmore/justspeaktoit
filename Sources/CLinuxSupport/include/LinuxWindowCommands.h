#ifndef JSTI_LINUX_WINDOW_COMMANDS_H
#define JSTI_LINUX_WINDOW_COMMANDS_H
/* Settings search results, configuration reveal and single-instance action commands. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One settings search result: the shared DesktopSettingsSearchSession row. */
typedef struct JSTISettingsSearchResult {
    const char *title;
    const char *detail;
    /* SettingsSearchEntry.resultAccessibilityIdentifier; the row's widget name. */
    const char *identifier;
} JSTISettingsSearchResult;
/* Replaces the settings search results, in order: UTF-8, at most 50 rows of at
 * most 4096 bytes per string. Copied before return and applied in call order
 * with the window's other setters. Thread safe; -1 for invalid input. */
int32_t jsti_window_set_settings_search_results(const JSTISettingsSearchResult *results, size_t count);
/* Scrolls to, focuses and briefly highlights configuration row `index` (the
 * jsti_window_set_configuration field index). It does not change the page:
 * call jsti_window_show_page first. Rows hidden on this session (overlay-only
 * preferences on Wayland) stay hidden. Thread safe; -1 when out of range. */
int32_t jsti_window_reveal_configuration_field(size_t index);

/* The argument the login item starts the app with (the shared
 * DesktopLoginItem.launchArgument): the window starts minimised. */
#define JSTI_LOGIN_LAUNCH_ARGUMENT "--background"
#define JSTI_TOGGLE_ARGUMENT "--toggle"
#define JSTI_SPEAK_CLIPBOARD_ARGUMENT "--speak-clipboard"
#define JSTI_SPEAK_SELECTED_TEXT_ARGUMENT "--speak-selected-text"
#define JSTI_PASTE_LAST_HISTORY_ARGUMENT "--paste-last-history"
#define JSTI_STOP_SPEECH_ARGUMENT "--stop-speech"
#define JSTI_PAUSE_SPEECH_ARGUMENT "--pause-resume-speech"
#define JSTI_QUICK_VOICE_1_ARGUMENT "--quick-voice-1"
#define JSTI_QUICK_VOICE_2_ARGUMENT "--quick-voice-2"
#define JSTI_QUICK_VOICE_3_ARGUMENT "--quick-voice-3"

/* Pure preflight for exactly one supported action (including legacy --toggle).
 * Rejects unknown options without registering, activating or opening stores. */
int32_t jsti_window_validate_action_command(int argc, char **argv, char *error, size_t error_capacity);

/* Forward an action command before constructing a controller or opening stores.
 * Refuses a missing primary instance without activating any window. */
int32_t jsti_window_forward_action(const char *app_id, int argc, char **argv, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
