#include "LinuxSupportInternal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/*
 * A minimal HTTP/1.1 listener bound to 127.0.0.1 only, as WindowsLoopback.cpp
 * is on Windows: the Apple ID sign-in callback, and loopback fake servers in
 * tests. It serves one connection at a time and nothing outside this computer
 * can connect to it. A connection that closes, or sends no complete request
 * within the request window, is dropped and listening goes on, so an idle
 * browser preconnection cannot hold the callback.
 */

struct jsti_loopback {
    GMutex lock;
    int socket;
    /* Readable once cancelled, and stays so: every later wait returns at once. */
    int cancel;
    gint64 request_window_ms;
};

struct jsti_loopback_connection {
    int socket;
    GByteArray *request;
};

enum { REQUEST_LIMIT = 1024 * 1024 };
enum { READY = 0, TIMED_OUT = 1, DROPPED = 2, CANCELLED = 3, FAILED = -1 };

static gint64 now_ms(void) { return g_get_monotonic_time() / 1000; }

/* Waits until `fd` is readable, the listener is cancelled or `deadline` (a
 * now_ms() instant, or -1 for none) passes. */
static int wait_readable(jsti_loopback *listener, int fd, gint64 deadline) {
    for (;;) {
        int timeout = -1;
        if (deadline >= 0) {
            gint64 remaining = deadline - now_ms();
            if (remaining <= 0) return TIMED_OUT;
            timeout = remaining > G_MAXINT ? G_MAXINT : (int)remaining;
        }
        struct pollfd fds[2] = { { .fd = fd, .events = POLLIN }, { .fd = listener->cancel, .events = POLLIN } };
        int ready = poll(fds, 2, timeout);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return FAILED;
        if (fds[1].revents != 0) return CANCELLED;
        if (ready == 0) continue;
        return READY;
    }
}

/* Bytes a complete request occupies once its header block is known, 0 before
 * that, or SIZE_MAX when it declares a body over the limit. */
static size_t expected_length(const GByteArray *bytes) {
    const char *text = (const char *)bytes->data;
    const char *end = g_strstr_len(text, bytes->len, "\r\n\r\n");
    if (end == NULL) return 0;
    size_t head = (size_t)(end - text);
    guint64 length = 0;
    const char *line = g_strstr_len(text, head, "\r\n");
    while (line != NULL && line < end) {
        const char *next = g_strstr_len(line + 2, (gssize)(end + 2 - (line + 2)), "\r\n");
        size_t size = (size_t)((next != NULL ? next : end) - (line + 2));
        if (size > 15 && g_ascii_strncasecmp(line + 2, "content-length:", 15) == 0) {
            gchar *value = g_strndup(line + 17, size - 15);
            length = g_ascii_strtoull(g_strstrip(value), NULL, 10);
            g_free(value);
        }
        line = next;
    }
    return length > REQUEST_LIMIT ? SIZE_MAX : head + 4 + (size_t)length;
}

/* Reads one complete request: READY, DROPPED when the peer closed early, sent
 * too much or not all of it in time, CANCELLED or FAILED. */
static int read_request(jsti_loopback *listener, int peer, GByteArray *request, gint64 deadline) {
    guint8 buffer[16 * 1024];
    int outcome = DROPPED;
    for (;;) {
        size_t expected = expected_length(request);
        if (expected == SIZE_MAX || request->len > REQUEST_LIMIT) break;
        if (expected != 0 && request->len >= expected) {
            outcome = READY;
            break;
        }
        int ready = wait_readable(listener, peer, deadline);
        if (ready == TIMED_OUT) break;
        if (ready != READY) {
            outcome = ready;
            break;
        }
        ssize_t received = recv(peer, buffer, sizeof buffer, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) break;
        g_byte_array_append(request, buffer, (guint)received);
    }
    explicit_bzero(buffer, sizeof buffer);
    return outcome;
}

static void wipe(GByteArray *bytes) {
    if (bytes == NULL) return;
    if (bytes->len > 0) explicit_bzero(bytes->data, bytes->len);
    g_byte_array_unref(bytes);
}

jsti_loopback *jsti_loopback_listen(
    uint16_t port, int32_t request_window_ms, uint16_t *bound_port, char *error, size_t capacity) {
    jsti_loopback *listener = g_new0(jsti_loopback, 1);
    g_mutex_init(&listener->lock);
    listener->request_window_ms = request_window_ms > 0 ? request_window_ms : 5000;
    listener->cancel = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    listener->socket = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(port) };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    /* Lets a new sign-in bind while the previous callback's connection is in
     * TIME_WAIT. On Linux this never lets two sockets listen on one port. */
    int reuse = 1;
    if (listener->cancel < 0 || listener->socket < 0 ||
        setsockopt(listener->socket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse) != 0 ||
        bind(listener->socket, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener->socket, 8) != 0) {
        int code = errno;
        if (code == EADDRINUSE) {
            jsti_set_error(error, capacity, "Another program is using 127.0.0.1:%u on this computer.", port);
        } else {
            jsti_set_error(error, capacity, "Could not listen on 127.0.0.1:%u: %s.", port, g_strerror(code));
        }
        jsti_loopback_destroy(listener);
        return NULL;
    }
    struct sockaddr_in bound = { 0 };
    socklen_t length = sizeof bound;
    if (getsockname(listener->socket, (struct sockaddr *)&bound, &length) != 0) {
        jsti_set_error(error, capacity, "Could not read the loopback port: %s.", g_strerror(errno));
        jsti_loopback_destroy(listener);
        return NULL;
    }
    if (bound_port != NULL) *bound_port = ntohs(bound.sin_port);
    return listener;
}

int32_t jsti_loopback_accept(
    jsti_loopback *listener, int32_t timeout_ms, jsti_loopback_connection **connection, char *error,
    size_t capacity) {
    if (listener == NULL || connection == NULL) {
        jsti_set_error(error, capacity, "Invalid loopback request.");
        return FAILED;
    }
    *connection = NULL;
    gint64 deadline = timeout_ms < 0 ? -1 : now_ms() + timeout_ms;
    for (;;) {
        int ready = wait_readable(listener, listener->socket, deadline);
        if (ready == FAILED) {
            jsti_set_error(error, capacity, "Waiting for a loopback connection failed: %s.", g_strerror(errno));
        }
        if (ready != READY) return ready;
        int peer = accept4(listener->socket, NULL, NULL, SOCK_CLOEXEC);
        if (peer < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNABORTED) continue;
            jsti_set_error(error, capacity, "Accepting a loopback connection failed: %s.", g_strerror(errno));
            return FAILED;
        }
        /* A peer that stops reading cannot hold a response write for long. */
        struct timeval send_timeout = { .tv_sec = 5 };
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof send_timeout);
        gint64 window = now_ms() + listener->request_window_ms;
        GByteArray *request = g_byte_array_new();
        int outcome = read_request(listener, peer, request, deadline >= 0 && deadline < window ? deadline : window);
        if (outcome == READY) {
            jsti_loopback_connection *accepted = g_new0(jsti_loopback_connection, 1);
            accepted->socket = peer;
            accepted->request = request;
            *connection = accepted;
            return READY;
        }
        wipe(request);
        close(peer);
        if (outcome == FAILED) {
            jsti_set_error(error, capacity, "Reading a loopback request failed: %s.", g_strerror(errno));
            return FAILED;
        }
        if (outcome == CANCELLED) return CANCELLED;
    }
}

const uint8_t *jsti_loopback_request(const jsti_loopback_connection *connection, size_t *count) {
    if (count != NULL) *count = connection != NULL ? connection->request->len : 0;
    return connection != NULL && connection->request->len > 0 ? connection->request->data : NULL;
}

int32_t jsti_loopback_respond(jsti_loopback_connection *connection, const uint8_t *bytes, size_t count) {
    if (connection == NULL || connection->socket < 0 || (bytes == NULL && count != 0)) return -1;
    size_t sent = 0;
    while (sent < count) {
        ssize_t written = send(connection->socket, bytes + sent, count - sent, MSG_NOSIGNAL);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        sent += (size_t)written;
    }
    shutdown(connection->socket, SHUT_WR);
    return 0;
}

void jsti_loopback_connection_destroy(jsti_loopback_connection *connection) {
    if (connection == NULL) return;
    if (connection->socket >= 0) close(connection->socket);
    wipe(connection->request);
    g_free(connection);
}

void jsti_loopback_cancel(jsti_loopback *listener) {
    if (listener == NULL) return;
    g_mutex_lock(&listener->lock);
    if (listener->cancel >= 0) {
        uint64_t one = 1;
        ssize_t written = write(listener->cancel, &one, sizeof one);
        (void)written;
    }
    g_mutex_unlock(&listener->lock);
}

void jsti_loopback_destroy(jsti_loopback *listener) {
    if (listener == NULL) return;
    g_mutex_lock(&listener->lock);
    if (listener->socket >= 0) close(listener->socket);
    if (listener->cancel >= 0) close(listener->cancel);
    listener->socket = -1;
    listener->cancel = -1;
    g_mutex_unlock(&listener->lock);
    g_mutex_clear(&listener->lock);
    g_free(listener);
}
