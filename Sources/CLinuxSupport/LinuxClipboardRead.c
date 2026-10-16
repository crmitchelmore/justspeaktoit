#include "LinuxSupportInternal.h"
#include "include/LinuxClipboardRead.h"
#include <gtk/gtk.h>
#include <string.h>

struct JSTILinuxClipboardRead {
    gint references;
    GMutex mutex;
    GCond changed;
    gsize maximum;
    guint timeout;
    gboolean started, done, admitted;
    gint status;
    gchar *error, *text;
    GSource *queued;
    GCancellable *cancellable;
    GInputStream *stream;
    GByteArray *bytes;
};

static gint outstanding;

static JSTILinuxClipboardRead *read_ref(JSTILinuxClipboardRead *request) {
    g_atomic_int_inc(&request->references);
    return request;
}

static void read_unref(gpointer data) {
    JSTILinuxClipboardRead *request = data;
    if (!g_atomic_int_dec_and_test(&request->references)) return;
    g_clear_object(&request->stream);
    g_clear_object(&request->cancellable);
    g_byte_array_unref(request->bytes);
    g_free(request->error);
    g_free(request->text);
    g_cond_clear(&request->changed);
    g_mutex_clear(&request->mutex);
    if (request->admitted) g_atomic_int_set(&outstanding, 0);
    g_free(request);
}

static void terminal_locked(JSTILinuxClipboardRead *request, gint status, const gchar *error) {
    if (request->done) return;
    request->status = status;
    request->error = g_strdup(error);
    request->done = TRUE;
    g_cond_broadcast(&request->changed);
}

/* Owns the asynchronous chain reference, not caller memory. */
static void native_finished(JSTILinuxClipboardRead *request, gint status, const gchar *error) {
    g_mutex_lock(&request->mutex);
    terminal_locked(request, status, error);
    g_mutex_unlock(&request->mutex);
    g_clear_object(&request->stream);
    read_unref(request);
}

static void read_next(JSTILinuxClipboardRead *request);

static void bytes_finished(GObject *source, GAsyncResult *result, gpointer data) {
    JSTILinuxClipboardRead *request = data;
    GError *failure = NULL;
    GBytes *bytes = g_input_stream_read_bytes_finish(G_INPUT_STREAM(source), result, &failure);
    g_mutex_lock(&request->mutex);
    gboolean cancelled = request->done;
    g_mutex_unlock(&request->mutex);
    if (cancelled || failure != NULL || bytes == NULL) {
        native_finished(request, -1, failure != NULL ? failure->message : "The clipboard read was cancelled.");
        if (bytes != NULL) g_bytes_unref(bytes);
        g_clear_error(&failure);
        return;
    }
    gsize size = 0;
    const guint8 *value = g_bytes_get_data(bytes, &size);
    if (size > request->maximum - request->bytes->len) {
        g_bytes_unref(bytes);
        native_finished(request, 2, "The clipboard text exceeds the read limit.");
        return;
    }
    if (size == 0) {
        g_bytes_unref(bytes);
        const gchar *text = request->bytes->len != 0 ? (const gchar *)request->bytes->data : "";
        if (!g_utf8_validate(text, request->bytes->len, NULL) ||
            memchr(text, '\0', request->bytes->len) != NULL) {
            native_finished(request, 3, "The clipboard does not contain valid UTF-8 text.");
            return;
        }
        g_mutex_lock(&request->mutex);
        if (!request->done) request->text = g_strndup(text, request->bytes->len);
        g_mutex_unlock(&request->mutex);
        native_finished(request, 0, NULL);
        return;
    }
    g_byte_array_append(request->bytes, value, (guint)size);
    g_bytes_unref(bytes);
    read_next(request);
}

static void read_next(JSTILinuxClipboardRead *request) {
    g_mutex_lock(&request->mutex);
    gboolean cancelled = request->done;
    g_mutex_unlock(&request->mutex);
    if (cancelled) {
        native_finished(request, 5, "The clipboard read was cancelled.");
        return;
    }
    /* Read one overflow byte, never an unbounded read_text_async payload. */
    gsize count = MIN((gsize)16384, request->maximum - request->bytes->len + 1);
    g_input_stream_read_bytes_async(request->stream, count, G_PRIORITY_DEFAULT,
                                    request->cancellable, bytes_finished, request);
}

static void stream_finished(GObject *source, GAsyncResult *result, gpointer data) {
    JSTILinuxClipboardRead *request = data;
    GError *failure = NULL;
    request->stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, NULL, &failure);
    if (request->stream == NULL) {
        native_finished(request, -1, failure != NULL ? failure->message : "The clipboard could not be read.");
        g_clear_error(&failure);
        return;
    }
    read_next(request);
}

static gboolean begin_read(gpointer data) {
    JSTILinuxClipboardRead *request = read_ref(data);
    g_mutex_lock(&request->mutex);
    GSource *queued = request->queued;
    request->queued = NULL;
    gboolean cancelled = request->done;
    g_mutex_unlock(&request->mutex);
    if (queued != NULL) g_source_unref(queued);
    if (cancelled) {
        read_unref(request);
        return G_SOURCE_REMOVE;
    }
    GdkDisplay *display = gdk_display_get_default();
    GType x11_type = g_type_from_name("GdkX11Display");
    if (display == NULL || x11_type == 0 || !G_TYPE_CHECK_INSTANCE_TYPE(display, x11_type)) {
        native_finished(request, 6, "Background clipboard command reads require an X11 display; Wayland is unsupported.");
        return G_SOURCE_REMOVE;
    }
    GdkClipboard *board = gdk_display_get_clipboard(display);
    GdkContentFormats *formats = gdk_clipboard_get_formats(board);
    if (!gdk_content_formats_contain_gtype(formats, G_TYPE_STRING) &&
        !gdk_content_formats_contain_mime_type(formats, "text/plain;charset=utf-8") &&
        !gdk_content_formats_contain_mime_type(formats, "text/plain")) {
        gsize mime_count = 0, type_count = 0;
        gdk_content_formats_get_mime_types(formats, &mime_count);
        gdk_content_formats_get_gtypes(formats, &type_count);
        if (mime_count == 0 && type_count == 0 && !gdk_clipboard_is_local(board)) {
            native_finished(request, -1, "Clipboard format metadata is unavailable; text absence cannot be confirmed.");
        } else {
            native_finished(request, 1, NULL);
        }
        return G_SOURCE_REMOVE;
    }
    static const gchar *mimes[] = {"text/plain;charset=utf-8", "text/plain", NULL};
    gdk_clipboard_read_async(board, mimes, G_PRIORITY_DEFAULT, request->cancellable, stream_finished, request);
    return G_SOURCE_REMOVE;
}

JSTILinuxClipboardRead *jsti_linux_clipboard_read_create(
    size_t maximum, uint32_t timeout, char *error, size_t capacity) {
    if (maximum == 0 || maximum >= G_MAXUINT || timeout == 0) {
        jsti_set_error(error, capacity, "Invalid clipboard read bounds.");
        return NULL;
    }
    JSTILinuxClipboardRead *request = g_new0(JSTILinuxClipboardRead, 1);
    request->references = 1;
    request->maximum = maximum;
    request->timeout = timeout;
    g_mutex_init(&request->mutex);
    g_cond_init(&request->changed);
    request->cancellable = g_cancellable_new();
    request->bytes = g_byte_array_new();
    return request;
}

static void cancel_native(JSTILinuxClipboardRead *request, GSource *queued) {
    g_cancellable_cancel(request->cancellable);
    if (queued != NULL) {
        g_source_destroy(queued);
        g_source_unref(queued);
    }
}

int32_t jsti_linux_clipboard_read_run(JSTILinuxClipboardRead *request,
    char *text, size_t text_capacity, char *error, size_t error_capacity) {
    if (request == NULL || text == NULL || text_capacity <= request->maximum) {
        jsti_set_error(error, error_capacity, "Invalid clipboard read output buffer.");
        return -1;
    }
    text[0] = '\0';
    g_mutex_lock(&request->mutex);
    if (request->started) {
        g_mutex_unlock(&request->mutex);
        jsti_set_error(error, error_capacity, "The clipboard request has already run.");
        return -1;
    }
    request->started = TRUE;
    if (!request->done) {
        if (!jsti_window_loop_running() || g_main_context_is_owner(g_main_context_default())) {
            terminal_locked(request, 6, "Clipboard command reads require an active GTK loop and a background caller.");
        } else if (!g_atomic_int_compare_and_exchange(&outstanding, 0, 1)) {
            terminal_locked(request, 7, "A previous clipboard read is still cleaning up.");
        } else {
            request->admitted = TRUE;
            request->queued = g_idle_source_new();
            g_source_set_callback(request->queued, begin_read, read_ref(request), read_unref);
            g_source_attach(request->queued, g_main_context_default());
        }
    }
    gint64 deadline = g_get_monotonic_time() + (gint64)request->timeout * 1000;
    while (!request->done && g_cond_wait_until(&request->changed, &request->mutex, deadline)) {}
    if (!request->done) terminal_locked(request, 4, "The clipboard did not respond before the read deadline.");
    GSource *queued = request->queued;
    request->queued = NULL;
    gint status = request->status;
    if (status == 0) g_strlcpy(text, request->text, text_capacity);
    else if (status != 1) jsti_set_error(error, error_capacity, "%s", request->error);
    g_mutex_unlock(&request->mutex);
    if (status == 4 || status == 5) cancel_native(request, queued);
    return status;
}

void jsti_linux_clipboard_read_cancel(JSTILinuxClipboardRead *request) {
    if (request == NULL) return;
    g_mutex_lock(&request->mutex);
    terminal_locked(request, 5, "The clipboard read was cancelled.");
    GSource *queued = request->queued;
    request->queued = NULL;
    g_mutex_unlock(&request->mutex);
    cancel_native(request, queued);
}

void jsti_linux_clipboard_read_destroy(JSTILinuxClipboardRead *request) {
    if (request != NULL) read_unref(request);
}

static gboolean stream_fixture(const gchar *input, gsize size, gsize maximum, gint expected,
                                gboolean cancel, GMainContext *context, char *error, size_t capacity) {
    JSTILinuxClipboardRead *request = jsti_linux_clipboard_read_create(maximum, 1000, error, capacity);
    if (request == NULL) return FALSE;
    request->stream = g_memory_input_stream_new_from_data(g_memdup2(input, size), (gssize)size, g_free);
    read_next(read_ref(request));
    if (cancel) jsti_linux_clipboard_read_cancel(request);
    gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
    while (g_atomic_int_get(&request->references) > 1 && g_get_monotonic_time() < deadline) {
        g_main_context_iteration(context, FALSE);
        g_usleep(100);
    }
    gboolean ok = request->done && request->status == expected &&
        g_atomic_int_get(&request->references) == 1 &&
        (expected != 0 || (request->text != NULL && strlen(request->text) == size)) &&
        (!cancel || request->text == NULL);
    if (!ok) jsti_set_error(error, capacity, "Synthetic clipboard stream fixture failed: status %d, expected %d.",
                            request->status, expected);
    if (g_atomic_int_get(&request->references) > 1) {
        jsti_linux_clipboard_read_cancel(request);
        deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
        while (g_atomic_int_get(&request->references) > 1 && g_get_monotonic_time() < deadline) {
            g_main_context_iteration(context, FALSE);
            g_usleep(100);
        }
    }
    read_unref(request);
    return ok;
}

int32_t jsti_linux_clipboard_read_self_test(char *error, size_t capacity) {
    GMainContext *context = g_main_context_new();
    g_main_context_push_thread_default(context);
    const gchar invalid[] = {(gchar)0xff};
    const gchar embedded_zero[] = {'a', '\0', 'b'};
    gboolean ok =
        stream_fixture("", 0, 8, 0, FALSE, context, error, capacity) &&
        stream_fixture("SYNTHETIC", 9, 9, 0, FALSE, context, error, capacity) &&
        stream_fixture("SYNTHETIC", 9, 8, 2, FALSE, context, error, capacity) &&
        stream_fixture("\xc3\xa9\xc3\xa9", 4, 4, 0, FALSE, context, error, capacity) &&
        stream_fixture("\xc3\xa9\xc3\xa9", 4, 3, 2, FALSE, context, error, capacity) &&
        stream_fixture(invalid, sizeof(invalid), 8, 3, FALSE, context, error, capacity) &&
        stream_fixture(embedded_zero, sizeof(embedded_zero), 8, 3, FALSE, context, error, capacity) &&
        stream_fixture("LATE SYNTHETIC", 14, 32, 5, TRUE, context, error, capacity);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
    return ok ? 0 : -1;
}
