#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>
#include <string.h>

#define SNAPSHOT_LIMIT 1048576

typedef struct VoiceClipboardRead {
    gint references;
    JSTIMainCall *call;
    GCancellable *cancel;
    GInputStream *stream;
    GByteArray *bytes;
    guint timer;
    gint32 status;
    gchar *text;
} VoiceClipboardRead;

static void snapshot_unref(gpointer data) {
    VoiceClipboardRead *read = data;
    if (!g_atomic_int_dec_and_test(&read->references)) return;
    g_clear_object(&read->cancel);
    g_clear_object(&read->stream);
    g_byte_array_unref(read->bytes);
    g_free(read->text);
    g_free(read);
}

static void snapshot_complete(VoiceClipboardRead *read, gint32 status) {
    read->status = status;
    if (read->timer) g_source_remove(read->timer);
    read->timer = 0;
    jsti_main_call_complete(read->call);
}

static gboolean snapshot_timeout(gpointer data) {
    VoiceClipboardRead *read = data;
    read->timer = 0;
    g_cancellable_cancel(read->cancel);
    return G_SOURCE_REMOVE;
}

static void snapshot_chunk(GObject *source, GAsyncResult *result, gpointer data);

static void snapshot_next(VoiceClipboardRead *read) {
    g_input_stream_read_bytes_async(read->stream, MIN(65536, SNAPSHOT_LIMIT + 1 - read->bytes->len),
        G_PRIORITY_DEFAULT, read->cancel, snapshot_chunk, read);
}

static void snapshot_chunk(GObject *source, GAsyncResult *result, gpointer data) {
    VoiceClipboardRead *read = data;
    GError *error = NULL;
    GBytes *chunk = g_input_stream_read_bytes_finish(G_INPUT_STREAM(source), result, &error);
    if (chunk == NULL) {
        g_clear_error(&error);
        snapshot_complete(read, -1);
        return;
    }
    gsize count;
    const guint8 *bytes = g_bytes_get_data(chunk, &count);
    if (count) g_byte_array_append(read->bytes, bytes, count);
    g_bytes_unref(chunk);
    if (read->bytes->len > SNAPSHOT_LIMIT) {
        snapshot_complete(read, -1);
    } else if (count) {
        snapshot_next(read);
    } else if (!read->bytes->len) {
        snapshot_complete(read, 1);
    } else if (memchr(read->bytes->data, 0, read->bytes->len) != NULL ||
               !g_utf8_validate((const char *)read->bytes->data, read->bytes->len, NULL)) {
        snapshot_complete(read, -1);
    } else {
        read->text = g_strndup((const char *)read->bytes->data, read->bytes->len);
        snapshot_complete(read, 0);
    }
}

static void snapshot_opened(GObject *source, GAsyncResult *result, gpointer data) {
    VoiceClipboardRead *read = data;
    GError *error = NULL;
    read->stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, NULL, &error);
    if (read->stream == NULL) {
        const gboolean not_text = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED);
        g_clear_error(&error);
        snapshot_complete(read, not_text ? 1 : -1);
        return;
    }
    snapshot_next(read);
}

static void snapshot_start(JSTIMainCall *call, gpointer data) {
    VoiceClipboardRead *read = data;
    read->call = call;
    GdkDisplay *display = gdk_display_get_default();
    if (display == NULL) { snapshot_complete(read, -1); return; }
    GdkClipboard *board = gdk_display_get_clipboard(display);
    read->cancel = g_cancellable_new();
    read->timer = g_timeout_add(2500, snapshot_timeout, read);
    const char *formats[] = {"text/plain;charset=utf-8", "text/plain", NULL};
    gdk_clipboard_read_async(board, formats, G_PRIORITY_DEFAULT, read->cancel, snapshot_opened, read);
}

int32_t jsti_voice_command_clipboard_read(char **text, char *error, size_t capacity) {
    if (text == NULL) return -1;
    *text = NULL;
    if (g_main_context_is_owner(g_main_context_default())) {
        jsti_set_error(error, capacity, "Clipboard snapshots must not block the GTK thread.");
        return -1;
    }
    VoiceClipboardRead *read = g_new0(VoiceClipboardRead, 1);
    read->references = 2; /* caller and main-call lifetime, including delayed callbacks */
    read->bytes = g_byte_array_new();
    read->status = -1;
    const gboolean done = jsti_main_invoke_sync(snapshot_start, read, snapshot_unref, 3000);
    const gint32 status = done ? read->status : -1;
    if (status == 0) { *text = read->text; read->text = NULL; }
    if (status < 0) jsti_set_error(error, capacity, "Clipboard text unavailable, invalid, oversized or timed out.");
    snapshot_unref(read);
    return status;
}
