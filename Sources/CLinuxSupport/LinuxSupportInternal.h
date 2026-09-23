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

#endif
