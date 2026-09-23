#include "LinuxSupportInternal.h"

#include <gtk/gtk.h>
#include <string.h>

/*
 * The app's own GTK clipboard, used for Copy, X11 paste and the fallback
 * "copied, press Ctrl+V" output. GTK serves the selection from its main loop
 * after the call returns. On Wayland only the focused client may set or read
 * the selection, so background insertion there uses the Clipboard portal.
 */

#define CLIPBOARD_TIMEOUT_MS 2000

typedef struct ClipboardJob {
    gchar *text;
    gboolean has_text;
    gboolean ok;
    gchar *message;
} ClipboardJob;

static void job_free(gpointer pointer) {
    ClipboardJob *job = pointer;
    g_free(job->text);
    g_free(job->message);
    g_free(job);
}

static GdkClipboard *clipboard(void) {
    GdkDisplay *display = gdk_display_get_default();
    return display != NULL ? gdk_display_get_clipboard(display) : NULL;
}

static void write_work(JSTIMainCall *call, gpointer data) {
    ClipboardJob *job = data;
    GdkClipboard *board = clipboard();
    if (board == NULL) {
        job->message = g_strdup("No display clipboard is available.");
    } else {
        gdk_clipboard_set_text(board, job->text);
        job->ok = TRUE;
    }
    jsti_main_call_complete(call);
}

int32_t jsti_clipboard_write(const char *text, char *error, size_t capacity) {
    ClipboardJob *job = g_new0(ClipboardJob, 1);
    job->text = g_strdup(text != NULL ? text : "");
    /* The job outlives a timed-out wait; keep one reference for the caller. */
    ClipboardJob *result = job;
    gboolean done = jsti_main_invoke_sync(write_work, job, NULL, CLIPBOARD_TIMEOUT_MS);
    if (!done) {
        jsti_set_error(error, capacity, "The clipboard did not respond. Select Copy to try again.");
        return -1;
    }
    int32_t status = result->ok ? 0 : -1;
    if (!result->ok) jsti_set_error(error, capacity, "%s", result->message);
    job_free(result);
    return status;
}

typedef struct ReadState {
    JSTIMainCall *call;
    ClipboardJob *job;
} ReadState;

static void read_finished(GObject *source, GAsyncResult *result, gpointer data) {
    ReadState *state = data;
    GError *failure = NULL;
    gchar *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, &failure);
    if (text != NULL) {
        state->job->text = text;
        state->job->has_text = TRUE;
        state->job->ok = TRUE;
    } else if (failure != NULL && g_error_matches(failure, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED)) {
        state->job->ok = TRUE; /* not text */
    } else {
        state->job->message = g_strdup(failure != NULL ? failure->message : "The clipboard could not be read.");
    }
    g_clear_error(&failure);
    jsti_main_call_complete(state->call);
    g_free(state);
}

static void read_work(JSTIMainCall *call, gpointer data) {
    ClipboardJob *job = data;
    GdkClipboard *board = clipboard();
    if (board == NULL) {
        job->message = g_strdup("No display clipboard is available.");
        jsti_main_call_complete(call);
        return;
    }
    GdkContentFormats *formats = gdk_clipboard_get_formats(board);
    if (!gdk_content_formats_contain_gtype(formats, G_TYPE_STRING) &&
        !gdk_content_formats_contain_mime_type(formats, "text/plain;charset=utf-8") &&
        !gdk_content_formats_contain_mime_type(formats, "text/plain")) {
        job->ok = TRUE;
        jsti_main_call_complete(call);
        return;
    }
    ReadState *state = g_new0(ReadState, 1);
    state->call = call;
    state->job = job;
    gdk_clipboard_read_text_async(board, NULL, read_finished, state);
}

int32_t jsti_clipboard_read(char **text, char *error, size_t capacity) {
    *text = NULL;
    ClipboardJob *job = g_new0(ClipboardJob, 1);
    /* On timeout the pending read still owns the job, so it is leaked
     * deliberately rather than freed under the asynchronous callback. */
    if (!jsti_main_invoke_sync(read_work, job, NULL, CLIPBOARD_TIMEOUT_MS)) {
        jsti_set_error(error, capacity, "The clipboard did not respond.");
        return -1;
    }
    if (!job->ok) {
        jsti_set_error(error, capacity, "%s", job->message);
        job_free(job);
        return -1;
    }
    int32_t status = job->has_text ? 0 : 1;
    *text = job->text;
    job->text = NULL;
    job_free(job);
    return status;
}
