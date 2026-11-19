#ifndef JSTI_LINUX_SYSTEM_RESOURCES_H
#define JSTI_LINUX_SYSTEM_RESOURCES_H
/* General > System resources in use, and the sound server's capture probe. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* General > "System resources in use" reports these on the GTK main thread. */
enum {
    JSTI_EVENT_SYSTEM_RESOURCE_RELEASE = 170,      /* text: the row's id */
    JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL = 171
};

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

/* Replaces the rows of General > System resources in use. Safe from any
 * thread, like jsti_window_update; strings are copied before it returns. */
int32_t jsti_window_set_system_resources(const JSTISystemResourcesView *view);

/* Whether this process records from any PulseAudio/PipeWire source right now:
 * 1 yes, 0 no, -1 unknown (the device monitor is not running, or the server
 * reported an error or did not answer). Each of its two queries gives up after
 * 500 ms, so a stalled server cannot hold up monitor shutdown for longer. */
int32_t jsti_audio_process_capturing(void);
/* Exercises the probe's query deadline and error handling without a sound
 * server. 0 on success, otherwise the failing step. */
int32_t jsti_audio_capture_query_self_test(void);

#ifdef __cplusplus
}
#endif
#endif
