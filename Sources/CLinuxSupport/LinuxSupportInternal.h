#ifndef JSTI_LINUX_SUPPORT_INTERNAL_H
#define JSTI_LINUX_SUPPORT_INTERNAL_H

#include "include/CLinuxSupport.h"
#include <glib.h>

/* Writes a formatted, always-terminated message into a caller buffer. */
void jsti_set_error(char *error, size_t capacity, const char *format, ...) G_GNUC_PRINTF(3, 4);

/* Runs `work(data)` on the default (GTK) main context and waits for it, at
 * most `timeout_ms`. Runs inline on the owning thread. Returns FALSE on
 * timeout or when no main loop is running; the work is then abandoned and
 * must not touch caller memory, so callers pass heap state it owns. */
typedef struct JSTIMainCall JSTIMainCall;
typedef void (*jsti_main_work_fn)(JSTIMainCall *call, gpointer data);
gboolean jsti_main_invoke_sync(jsti_main_work_fn work, gpointer data, GDestroyNotify destroy, guint timeout_ms);
/* Called by asynchronous main-thread work to release the waiting caller. */
void jsti_main_call_complete(JSTIMainCall *call);

/* TRUE while the GTK window's main loop is running. */
gboolean jsti_window_loop_running(void);

/* For window parts built in other files: the setters' queue (applied in call
 * order on the GTK main thread, see jsti_window_update) and the window's
 * event callback. */
typedef void (*jsti_window_apply_fn)(gpointer data);
int32_t jsti_window_post(jsti_window_apply_fn apply, gpointer data, GDestroyNotify destroy);
void jsti_window_emit(int32_t event, const char *text, int32_t index);

/* The iCloud sync group (LinuxCloudSync.c): added to the window's preferences
 * page, and exercised by the window self-test. */
void jsti_cloud_sync_build(gpointer page);
int32_t jsti_cloud_sync_self_test(char *error, size_t capacity);

#endif
