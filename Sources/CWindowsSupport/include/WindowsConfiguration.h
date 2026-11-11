#ifndef JSTI_WINDOWS_CONFIGURATION_H
#define JSTI_WINDOWS_CONFIGURATION_H
/* Dictation preferences: the configuration fields and their Apply callback. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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
/* Revision mode acknowledges rendered fields with action 6, then appends that
 * revision to actions 0/3/4/5 so queued edits retain their actual view identity. */
int jsti_window_set_configuration_revision(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered_keywords, size_t recovered_count,
    JSTIConfigurationCallback callback, void *context, const char *revision);
/* Changes only a label, never an unsaved value. 1 means no editor snapshot exists yet. */
int jsti_window_set_configuration_field_title(size_t index, const char *title);
/* Explicit route availability, without replacing a value or changing dependencies. */
int jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled);

#ifdef __cplusplus
}
#endif
#endif
