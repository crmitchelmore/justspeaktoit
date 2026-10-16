#include "LinuxSupportInternal.h"

#include <gtk/gtk.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif

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
    gint references;
    gint mode; /* 0 ordinary copy, 1 owned copy, 2 conditional restore */
    guint64 ownership;
    gboolean superseded;
    gint abandoned;
} ClipboardJob;

static guint64 ownership_generation;
static GWeakRef owned_provider;
static GWeakRef owned_board;
static gboolean ownership_initialized;
#ifdef GDK_WINDOWING_X11
static Window owned_window;
#endif

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

static void write_selection(ClipboardJob *job) {
    GdkClipboard *board = clipboard();
    if (board == NULL) {
        job->message = g_strdup("No display clipboard is available.");
        return;
    }
    if (!ownership_initialized) {
        g_weak_ref_init(&owned_provider, NULL);
        g_weak_ref_init(&owned_board, NULL);
        ownership_initialized = TRUE;
    }
    if (job->mode == 2) {
        GObject *provider = g_weak_ref_get(&owned_provider);
        GObject *owner = g_weak_ref_get(&owned_board);
        gboolean matches = job->ownership != 0 && job->ownership == ownership_generation &&
            owner == G_OBJECT(board) && provider != NULL &&
            provider == G_OBJECT(gdk_clipboard_get_content(board)) && gdk_clipboard_is_local(board);
        g_clear_object(&provider);
        g_clear_object(&owner);
        if (!matches) {
            job->superseded = TRUE;
            job->ok = TRUE;
            return;
        }
    }
    if (ownership_generation == G_MAXUINT64) {
        job->message = g_strdup("Clipboard ownership receipts are exhausted; restart the app.");
        return;
    }
#ifdef GDK_WINDOWING_X11
    GdkDisplay *display = gdk_clipboard_get_display(board);
    Display *xdisplay = GDK_IS_X11_DISPLAY(display) ? gdk_x11_display_get_xdisplay(display) : NULL;
    Atom selection = xdisplay != NULL ? XInternAtom(xdisplay, "CLIPBOARD", False) : None;
    if (job->mode != 0 && xdisplay != NULL) {
        /* GDK's ownership notification may still be queued. Keep the server
         * check and selection change together, not just the GTK cache check. */
        XGrabServer(xdisplay);
        if (job->mode == 2 && XGetSelectionOwner(xdisplay, selection) != owned_window) {
            XUngrabServer(xdisplay);
            XFlush(xdisplay);
            job->superseded = TRUE;
            job->ok = TRUE;
            return;
        }
        gdk_clipboard_set_text(board, job->text);
        owned_window = job->mode == 1 ? XGetSelectionOwner(xdisplay, selection) : None;
        XUngrabServer(xdisplay);
        XFlush(xdisplay);
        if (job->mode == 1 && owned_window == None) {
            job->message = g_strdup("The X11 clipboard selection was not claimed.");
            return;
        }
    } else
#endif
    {
        if (job->mode != 0) {
            job->message = g_strdup("Clipboard restoration requires the X11 display.");
            return;
        }
        gdk_clipboard_set_text(board, job->text);
    }
    ++ownership_generation;
    g_weak_ref_set(&owned_provider, job->mode == 1 ? gdk_clipboard_get_content(board) : NULL);
    g_weak_ref_set(&owned_board, job->mode == 1 ? board : NULL);
    job->ownership = ownership_generation;
    job->ok = TRUE;
}

static void write_work(JSTIMainCall *call, gpointer data) {
    ClipboardJob *job = data;
    if (!g_atomic_int_get(&job->abandoned)) write_selection(job);
    jsti_main_call_complete(call);
}

static void write_job_unref(gpointer pointer) {
    ClipboardJob *job = pointer;
    if (g_atomic_int_dec_and_test(&job->references)) job_free(job);
}

static int32_t write_clipboard(const char *text, gint mode, guint64 *ownership, char *error, size_t capacity) {
    ClipboardJob *job = g_new0(ClipboardJob, 1);
    job->text = g_strdup(text != NULL ? text : "");
    job->mode = mode;
    job->ownership = ownership != NULL ? *ownership : 0;
    job->references = 2;
    gboolean done = jsti_main_invoke_sync(write_work, job, write_job_unref, CLIPBOARD_TIMEOUT_MS);
    if (!done) {
        g_atomic_int_set(&job->abandoned, TRUE);
        jsti_set_error(error, capacity, "The clipboard did not respond. Select Copy to try again.");
        write_job_unref(job);
        return -1;
    }
    int32_t status = job->ok ? (job->superseded ? 2 : 0) : -1;
    if (!job->ok) jsti_set_error(error, capacity, "%s", job->message);
    if (status == 0 && ownership != NULL) *ownership = job->ownership;
    write_job_unref(job);
    return status;
}

int32_t jsti_clipboard_write(const char *text, char *error, size_t capacity) {
    return write_clipboard(text, 0, NULL, error, capacity);
}

int32_t jsti_clipboard_write_owned(const char *text, uint64_t *ownership, char *error, size_t capacity) {
    *ownership = 0;
    return write_clipboard(text, 1, ownership, error, capacity);
}

int32_t jsti_clipboard_restore(const char *text, uint64_t ownership, char *error, size_t capacity) {
    return write_clipboard(text, 2, &ownership, error, capacity);
}

static void ownership_test_work(JSTIMainCall *call, gpointer data) {
    ClipboardJob *job = data;
    char error[256] = {0};
    uint64_t first = 0, second = 0;
    gboolean valid = jsti_clipboard_write_owned("synthetic transcript", &first, error, sizeof(error)) == 0 &&
        jsti_clipboard_restore("synthetic previous", first, error, sizeof(error)) == 0 &&
        jsti_clipboard_write_owned("synthetic transcript", &first, error, sizeof(error)) == 0 &&
        jsti_clipboard_write("synthetic transcript", error, sizeof(error)) == 0 &&
        jsti_clipboard_restore("must not replace same-text copy", first, error, sizeof(error)) == 2 &&
        jsti_clipboard_write_owned("synthetic transcript", &first, error, sizeof(error)) == 0 &&
        jsti_clipboard_write_owned("synthetic newer transcript", &second, error, sizeof(error)) == 0 &&
        jsti_clipboard_restore("must not replace newer run", first, error, sizeof(error)) == 2 &&
        jsti_clipboard_restore("synthetic previous", second, error, sizeof(error)) == 0;
#ifdef GDK_WINDOWING_X11
    if (valid) {
        Display *other = XOpenDisplay(gdk_display_get_name(gdk_display_get_default()));
        if (other == NULL) {
            valid = FALSE;
        } else {
            Window foreign = XCreateSimpleWindow(other, DefaultRootWindow(other), 0, 0, 1, 1, 0, 0, 0);
            Atom selection = XInternAtom(other, "CLIPBOARD", False);
            valid = jsti_clipboard_write_owned("synthetic transcript", &first, error, sizeof(error)) == 0;
            XSetSelectionOwner(other, selection, foreign, CurrentTime);
            XSync(other, False);
            /* Do not pump GDK: its cached local provider is deliberately stale. */
            valid = valid && jsti_clipboard_restore("must not replace another client", first,
                error, sizeof(error)) == 2 && XGetSelectionOwner(other, selection) == foreign;
            XDestroyWindow(other, foreign);
            XCloseDisplay(other);
        }
    }
#endif
    job->ok = valid;
    if (!valid) job->message = g_strdup(error[0] != '\0' ? error : "X11 clipboard ownership fixtures failed.");
    jsti_main_call_complete(call);
}

int32_t jsti_clipboard_ownership_self_test(char *error, size_t capacity) {
    ClipboardJob *job = g_new0(ClipboardJob, 1);
    job->references = 2;
    gboolean done = jsti_main_invoke_sync(ownership_test_work, job, write_job_unref, CLIPBOARD_TIMEOUT_MS);
    int32_t status = done && job->ok ? 0 : -1;
    if (!done) jsti_set_error(error, capacity, "X11 clipboard ownership fixtures timed out.");
    else if (!job->ok) jsti_set_error(error, capacity, "%s", job->message);
    write_job_unref(job);
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
