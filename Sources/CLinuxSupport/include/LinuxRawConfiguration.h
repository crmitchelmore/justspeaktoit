#ifndef JSTI_LINUX_RAW_CONFIGURATION_H
#define JSTI_LINUX_RAW_CONFIGURATION_H
/* General > Edit raw configuration: every setting as JSON. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* index: DesktopRawConfigurationAction (0 load, 1 validate, 2 apply,
 * 3 defaults, 4 import, 5 export); text: the editor's JSON, an import path,
 * or an export path, a newline and the JSON. Reported on the GTK main thread. */
enum { JSTI_EVENT_RAW_CONFIGURATION = 180 };

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
