#ifndef JSTI_WINDOWS_RAW_CONFIGURATION_H
#define JSTI_WINDOWS_RAW_CONFIGURATION_H
/* General > App behaviour > Edit raw configuration: every setting as JSON. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The window sends JSTI_EVENT_RAW_CONFIGURATION (WindowsWindowEvents.h) through
 * the window callback on the UI thread. model_index is the
 * DesktopRawConfigurationAction (0 load, 1 validate, 2 apply, 3 defaults,
 * 4 import, 5 export); text is the editor's JSON, an import path, or an export
 * path, a newline and the JSON. The host answers each request, in order. */

/* Shows an action's outcome in the raw configuration window: text replaces
 * the editor unless NULL; status and issues (one per line) are shown and
 * announcement is spoken. failed marks the status as an error. Safe from any
 * thread; strings are copied before it returns. -1 for invalid UTF-8. */
int32_t jsti_window_set_raw_configuration(
    const char *text, const char *status, const char *issues, const char *announcement, int32_t failed);

#ifdef __cplusplus
}
#endif
#endif
