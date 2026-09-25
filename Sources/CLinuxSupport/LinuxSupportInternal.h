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

/* For window sections kept in their own files: the window's ordered,
 * thread-safe setter queue (apply runs on the GTK main thread while the window
 * exists; destroy always runs) and its event callback (main thread only). */
typedef void (*jsti_window_apply_fn)(gpointer data);
int32_t jsti_window_post(jsti_window_apply_fn apply, gpointer data, GDestroyNotify destroy);
void jsti_window_emit(gint32 event, const char *text, gint32 index);

/* LinuxLocalModels.c: the Local models group, built once with the window,
 * and its part of the window self-test. */
struct _GtkWidget *jsti_local_models_group_new(void);
int32_t jsti_local_models_self_test(char *error, size_t capacity);

/* The iCloud sync group (LinuxCloudSync.c): added to the window's preferences
 * page, and exercised by the window self-test. */
void jsti_cloud_sync_build(gpointer page);
int32_t jsti_cloud_sync_self_test(char *error, size_t capacity);

/* LinuxModelStream.c: a model file read on a thread of its own, so the speech
 * runtime, which holds its lock while whisper.cpp loads, never waits on the
 * file itself. `cancelled(data)` ends every wait early. */
typedef struct JSTIModelStream JSTIModelStream;
typedef gboolean (*jsti_stream_cancelled_fn)(gpointer data);
enum { JSTI_MODEL_STREAM_CHUNK = 1 << 20, JSTI_MODEL_STREAM_PREFIX = 2 << 20 };
/* Starts reading `path`; NULL (with `error`) when no reader could start. */
JSTIModelStream *jsti_model_stream_open(const char *path, char *error, size_t capacity);
/* Waits until `bytes` are buffered or the file ended or failed; FALSE when
 * cancelled first. */
gboolean jsti_model_stream_wait(JSTIModelStream *stream, size_t bytes, jsti_stream_cancelled_fn cancelled,
                                gpointer data);
/* Copies up to `size` bytes in order, waiting for the reader. Stops short at
 * the end of the file, on a read error, or, setting `*was_cancelled`, when it
 * would wait after cancellation. */
size_t jsti_model_stream_take(JSTIModelStream *stream, void *output, size_t size, jsti_stream_cancelled_fn cancelled,
                              gpointer data, gboolean *was_cancelled);
/* Why the stream failed, if it has: it could not open the path, the path was
 * a device or anything else that is neither a regular file nor a FIFO, or a
 * read failed. */
typedef enum {
    JSTI_MODEL_STREAM_OK,
    JSTI_MODEL_STREAM_UNOPENED,
    JSTI_MODEL_STREAM_NOT_A_FILE,
    JSTI_MODEL_STREAM_READ_ERROR
} JSTIModelStreamFailure;
JSTIModelStreamFailure jsti_model_stream_failure(JSTIModelStream *stream);
/* Stops the reader at its next step and drops the caller's reference. */
void jsti_model_stream_close(JSTIModelStream *stream);

#endif
