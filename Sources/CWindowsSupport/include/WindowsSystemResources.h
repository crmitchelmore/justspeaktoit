#ifndef JSTI_WINDOWS_SYSTEM_RESOURCES_H
#define JSTI_WINDOWS_SYSTEM_RESOURCES_H
/* General > App behaviour > System resources in use, the WASAPI capture probe and the hotkey registration observer. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* General > App behaviour > "System resources in use" sends
 * JSTI_EVENT_SYSTEM_RESOURCE_RELEASE and JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL
 * (WindowsWindowEvents.h) through the window callback on the UI thread. */

typedef struct JSTISystemResourceRow {
    const char *id;
    const char *title;
    const char *reason;
    const char *caption;
    /* NULL: the hold has no release button. */
    const char *release_title;
    /* Nonzero while its release runs; the button is disabled. */
    int32_t releasing;
} JSTISystemResourceRow;

typedef struct JSTISystemResourcesView {
    const char *headline;
    /* NULL unless the OS reports a microphone nothing claims. */
    const char *warning;
    /* Shown when there are no rows. */
    const char *empty;
    /* What the OS reports about the microphone. */
    const char *microphone;
    const JSTISystemResourceRow *rows;
    int32_t row_count;
    int32_t can_release_everything;
} JSTISystemResourcesView;

/* Replaces what the System resources in use window shows, open or not. Safe
 * from any thread; strings are copied before it returns. -1 rejects the view. */
int32_t jsti_window_set_system_resources(const JSTISystemResourcesView *view);

/* Whether this process has an active WASAPI capture session on any active
 * microphone right now (IAudioSessionManager2): 1 yes, 0 no, -1 unknown.
 * Safe from any thread; it initialises COM for its own call if needed. */
int32_t jsti_audio_process_capturing(void);

/* The dictation shortcut's registration, on the UI thread: name is the
 * registered combination, or NULL once nothing is registered. Reported after
 * every start, stop or change. The context is borrowed until the observer is
 * replaced or cleared with NULL, and a late call may still arrive from a
 * change already in progress, so resolve it through a weak or retiring box. */
typedef void (*JSTIHotKeyRegistrationCallback)(const char *name, void *context);
void jsti_hotkey_set_registration_observer(JSTIHotKeyRegistrationCallback callback, void *context);

#ifdef __cplusplus
}
#endif
#endif
