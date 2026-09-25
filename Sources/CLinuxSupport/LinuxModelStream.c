#include "LinuxSupportInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A model file read on a thread of its own into a few chunk buffers. A read
 * from a network or FUSE file system, or a FIFO, can stall indefinitely, so
 * the loader never reads the file: it waits only on these buffers, and gives
 * up whenever its job is cancelled. A reader left blocked in a read keeps only
 * its thread, descriptor and buffers, and frees them once that read returns. */

enum { SLOT_COUNT = 4, POLL_MICROSECONDS = 50 * 1000 };

struct JSTIModelStream {
    gint references; /* The loader's and the reader's. */
    GMutex lock;
    GCond changed;
    gchar *path;
    guchar *slots[SLOT_COUNT];
    size_t lengths[SLOT_COUNT];
    size_t first;    /* The oldest filled slot. */
    size_t filled;   /* Filled slots, from `first`. */
    size_t offset;   /* Bytes already taken from the oldest slot. */
    size_t buffered; /* Bytes filled and not yet taken. */
    gboolean ended;
    gboolean failed;
    JSTIModelStreamFailure failure;
    gboolean closed; /* The loader is done with the stream. */
};

static void stream_unref(JSTIModelStream *stream) {
    if (!g_atomic_int_dec_and_test(&stream->references)) return;
    for (size_t index = 0; index < SLOT_COUNT; index++) g_free(stream->slots[index]);
    g_free(stream->path);
    g_mutex_clear(&stream->lock);
    g_cond_clear(&stream->changed);
    g_free(stream);
}

/* Opens without waiting (a FIFO would wait for a writer) and admits a regular
 * file or a FIFO, whose bytes end when its writer closes. A device, which may
 * never end, is refused before any read. */
static int open_model(const char *path, JSTIModelStreamFailure *failure) {
    *failure = JSTI_MODEL_STREAM_UNOPENED;
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
    if (descriptor < 0) return -1;
    struct stat info;
    int flags = fcntl(descriptor, F_GETFL);
    if (fstat(descriptor, &info) != 0 || !(S_ISREG(info.st_mode) || S_ISFIFO(info.st_mode))) {
        *failure = JSTI_MODEL_STREAM_NOT_A_FILE;
    } else if (flags != -1 && fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0) {
        *failure = JSTI_MODEL_STREAM_OK;
        return descriptor;
    }
    close(descriptor);
    return -1;
}

/* Fills `buffer` from `descriptor` until it is full or the file ends. Returns
 * the bytes read, or -1 on a read error. */
static ssize_t fill(int descriptor, guchar *buffer) {
    size_t length = 0;
    while (length < JSTI_MODEL_STREAM_CHUNK) {
        ssize_t count = read(descriptor, buffer + length, JSTI_MODEL_STREAM_CHUNK - length);
        if (count > 0) {
            length += (size_t)count;
        } else if (count == 0) {
            break;
        } else if (errno != EINTR) {
            return -1;
        }
    }
    return (ssize_t)length;
}

static gpointer stream_read(gpointer data) {
    JSTIModelStream *stream = data;
    JSTIModelStreamFailure failure = JSTI_MODEL_STREAM_OK;
    int descriptor = open_model(stream->path, &failure);
    g_mutex_lock(&stream->lock);
    stream->failed = descriptor < 0;
    stream->failure = failure;
    g_cond_broadcast(&stream->changed);
    while (descriptor >= 0 && !stream->closed && !stream->ended && !stream->failed) {
        if (stream->filled == SLOT_COUNT) {
            g_cond_wait(&stream->changed, &stream->lock);
            continue;
        }
        /* The slot after the filled ones is the reader's alone until published. */
        size_t slot = (stream->first + stream->filled) % SLOT_COUNT;
        g_mutex_unlock(&stream->lock);
        ssize_t count = fill(descriptor, stream->slots[slot]);
        g_mutex_lock(&stream->lock);
        if (count > 0) {
            stream->lengths[slot] = (size_t)count;
            stream->filled++;
            stream->buffered += (size_t)count;
        }
        if (count < JSTI_MODEL_STREAM_CHUNK) {
            stream->ended = count >= 0;
            stream->failed = count < 0;
            if (count < 0) stream->failure = JSTI_MODEL_STREAM_READ_ERROR;
        }
        g_cond_broadcast(&stream->changed);
    }
    g_mutex_unlock(&stream->lock);
    if (descriptor >= 0) close(descriptor);
    stream_unref(stream);
    return NULL;
}

JSTIModelStream *jsti_model_stream_open(const char *path, char *error, size_t capacity) {
    JSTIModelStream *stream = g_new0(JSTIModelStream, 1);
    stream->references = 2;
    g_mutex_init(&stream->lock);
    g_cond_init(&stream->changed);
    stream->path = g_strdup(path);
    for (size_t index = 0; index < SLOT_COUNT; index++) stream->slots[index] = g_malloc(JSTI_MODEL_STREAM_CHUNK);
    GError *failure = NULL;
    GThread *thread = g_thread_try_new("jsti-model-read", stream_read, stream, &failure);
    if (thread == NULL) {
        jsti_set_error(error, capacity, "Could not start reading the model: %s",
                       failure != NULL ? failure->message : "no thread");
        g_clear_error(&failure);
        stream->references = 1;
        stream_unref(stream);
        return NULL;
    }
    g_thread_unref(thread);
    return stream;
}

gboolean jsti_model_stream_wait(JSTIModelStream *stream, size_t bytes, jsti_stream_cancelled_fn cancelled,
                                gpointer data) {
    g_mutex_lock(&stream->lock);
    gboolean ready;
    while (!(ready = stream->buffered >= bytes || stream->ended || stream->failed) && !cancelled(data)) {
        g_cond_wait_until(&stream->changed, &stream->lock, g_get_monotonic_time() + POLL_MICROSECONDS);
    }
    g_mutex_unlock(&stream->lock);
    return ready;
}

size_t jsti_model_stream_take(JSTIModelStream *stream, void *output, size_t size, jsti_stream_cancelled_fn cancelled,
                              gpointer data, gboolean *was_cancelled) {
    guchar *bytes = output;
    size_t done = 0;
    *was_cancelled = FALSE;
    g_mutex_lock(&stream->lock);
    while (done < size) {
        if (stream->filled > 0) {
            size_t slot = stream->first;
            size_t count = MIN(size - done, stream->lengths[slot] - stream->offset);
            memcpy(bytes + done, stream->slots[slot] + stream->offset, count);
            done += count;
            stream->offset += count;
            stream->buffered -= count;
            if (stream->offset == stream->lengths[slot]) {
                stream->first = (slot + 1) % SLOT_COUNT;
                stream->filled--;
                stream->offset = 0;
                g_cond_broadcast(&stream->changed);
            }
        } else if (stream->ended || stream->failed) {
            break;
        } else if (cancelled(data)) {
            *was_cancelled = TRUE;
            break;
        } else {
            g_cond_wait_until(&stream->changed, &stream->lock, g_get_monotonic_time() + POLL_MICROSECONDS);
        }
    }
    g_mutex_unlock(&stream->lock);
    return done;
}

JSTIModelStreamFailure jsti_model_stream_failure(JSTIModelStream *stream) {
    g_mutex_lock(&stream->lock);
    JSTIModelStreamFailure failure = stream->failure;
    g_mutex_unlock(&stream->lock);
    return failure;
}

void jsti_model_stream_close(JSTIModelStream *stream) {
    if (stream == NULL) return;
    g_mutex_lock(&stream->lock);
    stream->closed = TRUE;
    g_cond_broadcast(&stream->changed);
    g_mutex_unlock(&stream->lock);
    stream_unref(stream);
}
