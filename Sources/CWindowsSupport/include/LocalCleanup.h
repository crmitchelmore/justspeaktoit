#ifndef JSTI_LOCAL_CLEANUP_H
#define JSTI_LOCAL_CLEANUP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct JSTILocalCleanupRow {
    const char *identifier;
    const char *name;
    const char *detail;
    /* 0 absent, 1 paused, 2 downloading, 3 downloaded, 4 in use, 5 removing */
    int32_t state;
} JSTILocalCleanupRow;
/* 1 download/resume, 2 remove confirmed by the UI, 3 cancel, 4 import metadata.
   Strings are borrowed during the callback; the host copies them on admission. */
typedef void (*JSTILocalCleanupCallback)(
    int32_t action, const char *identifier, const char *repository, const char *filename, void *context);
int32_t jsti_window_set_local_cleanup(
    const JSTILocalCleanupRow *, size_t count, const char *status, JSTILocalCleanupCallback, void *context);
/* Existing post-processing setters keep their ABI; this additive call splits
   the list into remote then local choices and enables the native source picker. */
int32_t jsti_window_set_cleanup_sources(size_t remote_count);
#ifdef __cplusplus
}
#endif
#endif
