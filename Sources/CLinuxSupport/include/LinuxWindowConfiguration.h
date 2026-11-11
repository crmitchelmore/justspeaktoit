#ifndef JSTI_LINUX_WINDOW_CONFIGURATION_H
#define JSTI_LINUX_WINDOW_CONFIGURATION_H
/* Action shortcuts, the dictation preferences form and the hands-free guard. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Linux window-local projection of customShortcutBindings. Global/unsupported
 * rows remain visible but disabled; this does not change dictation registration.
 * run: 0 unavailable, 1 record, 2 page, 3 stop, 4 troubleshooting,
 * 5 comparison, 6 quick voice, 7 clipboard speech, 8 speech pause,
 * 9 API Keys, 10 Permissions, 11 paste last History, 12 selected-text speech.
 * Selected-text speech needs external focus; its saved window binding stays disabled.
 * Strings are copied before return. */
typedef struct JSTILinuxActionShortcut {
    const char *title, *chord, *note, *page, *identifier;
    uint32_t keysym, modifiers;
    int32_t run, slot, enabled, binding_enabled, binding_global, can_be_global, has_key;
} JSTILinuxActionShortcut;
int32_t jsti_window_set_action_shortcuts(const JSTILinuxActionShortcut *rows, size_t count);
/* Presets come from the canonical catalogue, flattened in names/row order.
 * Save completion is asynchronous and correlated to one editor request. */
int32_t jsti_window_set_action_shortcut_editor(const char *revision, const char *const *names,
    const JSTILinuxActionShortcut *presets, size_t preset_count, size_t row_count, int32_t reset_index);
int32_t jsti_action_shortcuts_edit_finished(const char *request, int32_t success, const char *message);
int32_t jsti_action_shortcuts_editor_is_open(void);
typedef struct JSTIConfigurationField {
    const char *title;
    const char *value;
    const char *group;
    int32_t is_boolean;
    int32_t requires_hud_overlay;
    /* Optional newline-separated choices: raw value, tab, display title. */
    const char *choices;
    int32_t requires_hands_free_guard;
    /* -1: unavailable/read-only, retained for transfer. Zero: independent.
     * Positive: the 1-based index of a boolean enabling field. */
    int32_t enabled_by_field;
} JSTIConfigurationField;
typedef int32_t (*JSTIConfigurationCallback)(int32_t action, const char *const *values, size_t count,
                                            void *context, char *error, size_t capacity);
/* Recovery action 3 carries all fields followed by the exact selected edit,
 * which the host verifies is still recoverable before persisting.
 * Actions 4/5 carry all fields for save-and-preview start/stop sound. */
int32_t jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
                                      const char *const *recovered_keywords, size_t recovered_count,
                                      JSTIConfigurationCallback callback, void *context);
/* Revision mode acknowledges rendered fields with action 6, then appends that
 * revision to actions 0/3/4/5 so queued edits retain their actual view identity. */
int32_t jsti_window_set_configuration_revision(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered_keywords, size_t recovered_count,
    JSTIConfigurationCallback callback, void *context, const char *revision);
/* Queues a label-only update without replacing an unsaved entry value. */
int32_t jsti_window_set_configuration_field_title(size_t index, const char *title);
/* Queues route availability for a field with no enabling-field dependency. */
int32_t jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled);
/* False when logind/screen-lock observation is unavailable; manual capture is unaffected. */
int32_t jsti_window_hands_free_guard_ready(void);

#ifdef __cplusplus
}
#endif
#endif
