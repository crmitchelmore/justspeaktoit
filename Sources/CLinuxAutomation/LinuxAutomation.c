#define _GNU_SOURCE
#include "include/CLinuxAutomation.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

enum { MAX_CONNECTIONS = 4 };
struct JSTIAutomationConnection {
    int fd;
    JSTIAutomationListener *owner;
    struct JSTIAutomationConnection *next;
};
struct JSTIAutomationListener {
    int fd, cancel[2], directory;
    char name[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    struct stat receipt;
    bool has_receipt, stopped;
    pthread_mutex_t lock;
    size_t count;
    JSTIAutomationConnection *connections;
};

uint32_t jsti_automation_uid(void) { return (uint32_t)geteuid(); }
int jsti_automation_peer_allowed(uint32_t peer_uid) { return peer_uid == (uint32_t)geteuid(); }
int jsti_automation_private_metadata(uint32_t owner, uint32_t mode, int directory) {
    return jsti_automation_peer_allowed(owner) && (mode & 07777) == (directory ? 0700 : 0600)
        && (directory ? S_ISDIR(mode) : S_ISSOCK(mode));
}
static uint64_t now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}
uint64_t jsti_automation_deadline(uint32_t milliseconds) { return now_ms() + milliseconds; }

static int wait_fd(int fd, short events, int cancel, uint64_t deadline) {
    for (;;) {
        uint64_t now = now_ms();
        if (now >= deadline) return JSTI_AUTOMATION_TIMEOUT;
        int timeout = (int)((deadline - now) > INT_MAX ? INT_MAX : deadline - now);
        struct pollfd descriptors[2] = {{fd, events, 0}, {cancel, POLLIN, 0}};
        int result = poll(descriptors, cancel < 0 ? 1 : 2, timeout);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return JSTI_AUTOMATION_IO;
        if (result == 0) continue;
        if (cancel >= 0 && descriptors[1].revents) return JSTI_AUTOMATION_CANCELLED;
        if (descriptors[0].revents & POLLNVAL) return JSTI_AUTOMATION_IO;
        if (descriptors[0].revents & (events | POLLHUP | POLLERR)) return JSTI_AUTOMATION_OK;
    }
}

static bool safe_ancestor(const struct stat *value) {
    if (!S_ISDIR(value->st_mode) || (value->st_uid != 0 && value->st_uid != geteuid())) return false;
    /* Root-owned sticky directories (notably /tmp) are shared, never chmodded. */
    return !(value->st_mode & 0022) || (value->st_uid == 0 && (value->st_mode & S_ISVTX));
}

/* Walk from / through descriptors: no symlink component, relative path, . or ...
 * Only the final, private directory may be created. */
static int open_directory(const char *path, bool create, char *name, int *output) {
    if (!path || path[0] != '/' || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path))
        return JSTI_AUTOMATION_UNSAFE;
    char copy[sizeof(((struct sockaddr_un *)0)->sun_path)];
    strcpy(copy, path);
    char *slash = strrchr(copy, '/');
    if (!slash || !slash[1] || slash == copy) return JSTI_AUTOMATION_UNSAFE;
    strcpy(name, slash + 1);
    if (!strcmp(name, ".") || !strcmp(name, "..")) return JSTI_AUTOMATION_UNSAFE;
    *slash = 0;
    int directory = open("/", O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) return JSTI_AUTOMATION_IO;
    char *save = NULL;
    char *component = strtok_r(copy + 1, "/", &save);
    while (component) {
        char *next = strtok_r(NULL, "/", &save);
        if (!strcmp(component, ".") || !strcmp(component, "..")) {
            close(directory);
            return JSTI_AUTOMATION_UNSAFE;
        }
        int child = openat(directory, component, O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (child < 0 && errno == ENOENT && !next && create) {
            if (mkdirat(directory, component, 0700) == 0 || errno == EEXIST)
                child = openat(directory, component, O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        }
        if (child < 0) {
            int failure = errno;
            close(directory);
            return failure == ENOENT ? JSTI_AUTOMATION_UNAVAILABLE : JSTI_AUTOMATION_UNSAFE;
        }
        struct stat value;
        bool safe = fstat(child, &value) == 0 && safe_ancestor(&value);
        if (!next) safe = safe && jsti_automation_private_metadata(value.st_uid, value.st_mode, 1);
        close(directory);
        if (!safe) { close(child); return JSTI_AUTOMATION_UNSAFE; }
        directory = child;
        component = next;
    }
    *output = directory;
    return JSTI_AUTOMATION_OK;
}

static bool socket_receipt(int directory, const char *name, struct stat *value) {
    errno = 0;
    return fstatat(directory, name, value, AT_SYMLINK_NOFOLLOW) == 0
        && S_ISSOCK(value->st_mode) && value->st_uid == geteuid();
}

static bool directory_identity(const char *path, int owned) {
    int current = -1;
    char name[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (open_directory(path, false, name, &current) != JSTI_AUTOMATION_OK) return false;
    struct stat before, after;
    bool same = fstat(owned, &before) == 0 && fstat(current, &after) == 0
        && before.st_dev == after.st_dev && before.st_ino == after.st_ino;
    close(current);
    return same;
}

int jsti_automation_listener_status(JSTIAutomationListener *listener) {
    pthread_mutex_lock(&listener->lock);
    bool stopped = listener->stopped;
    pthread_mutex_unlock(&listener->lock);
    if (stopped) return JSTI_AUTOMATION_CANCELLED;
    struct stat current;
    return listener->has_receipt && directory_identity(listener->path, listener->directory)
        && socket_receipt(listener->directory, listener->name, &current)
        && jsti_automation_private_metadata(current.st_uid, current.st_mode, 0)
        && current.st_dev == listener->receipt.st_dev && current.st_ino == listener->receipt.st_ino
        ? JSTI_AUTOMATION_OK : JSTI_AUTOMATION_UNSAFE;
}

static void remove_owned(JSTIAutomationListener *listener) {
    /* Receipt check and unlink are separate syscalls, not an atomic namespace CAS.
     * A replacement already visible is preserved; concurrent same-user writers
     * must cooperate during cleanup. */
    struct stat current;
    if (listener->has_receipt && socket_receipt(listener->directory, listener->name, &current)
        && current.st_dev == listener->receipt.st_dev && current.st_ino == listener->receipt.st_ino) {
        if (unlinkat(listener->directory, listener->name, 0) != 0)
            fprintf(stderr, "Automation could not remove its owned socket: %s\n", strerror(errno));
    }
}

static int address_at(int directory, const char *name, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    int length = snprintf(address->sun_path, sizeof(address->sun_path), "/proc/self/fd/%d/%s", directory, name);
    return length > 0 && (size_t)length < sizeof(address->sun_path) ? JSTI_AUTOMATION_OK : JSTI_AUTOMATION_UNSAFE;
}

static bool same_user(int fd) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) == 0
        && size == sizeof(peer) && jsti_automation_peer_allowed(peer.uid);
}

static bool secure_socket(JSTIAutomationListener *listener) {
    int socket = openat(listener->directory, listener->name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (socket < 0) return false;
    struct stat value;
    char anchored[64];
    int length = snprintf(anchored, sizeof(anchored), "/proc/self/fd/%d", socket);
    bool secured = fstat(socket, &value) == 0 && S_ISSOCK(value.st_mode)
        && value.st_uid == geteuid() && value.st_dev == listener->receipt.st_dev
        && value.st_ino == listener->receipt.st_ino && length > 0 && (size_t)length < sizeof(anchored)
        && chmod(anchored, 0600) == 0;
    close(socket);
    return secured;
}

int jsti_automation_listen(const char *path, JSTIAutomationListener **output) {
    *output = NULL;
    JSTIAutomationListener *listener = calloc(1, sizeof(*listener));
    if (!listener) return JSTI_AUTOMATION_IO;
    listener->fd = listener->directory = listener->cancel[0] = listener->cancel[1] = -1;
    pthread_mutex_init(&listener->lock, NULL);
    int result = open_directory(path, true, listener->name, &listener->directory);
    if (result != JSTI_AUTOMATION_OK) goto failure;
    strcpy(listener->path, path);
    struct sockaddr_un address;
    result = address_at(listener->directory, listener->name, &address);
    if (result != JSTI_AUTOMATION_OK) goto failure;
    listener->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    result = JSTI_AUTOMATION_IO;
    if (listener->fd < 0 || pipe2(listener->cancel, O_CLOEXEC | O_NONBLOCK) != 0) goto failure;
    /* Never unlink an existing endpoint, even if it appears stale. */
    if (bind(listener->fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        result = errno == EADDRINUSE ? JSTI_AUTOMATION_UNAVAILABLE : JSTI_AUTOMATION_IO;
        goto failure;
    }
    listener->has_receipt = socket_receipt(listener->directory, listener->name, &listener->receipt);
    if (!listener->has_receipt || !secure_socket(listener)
        || listen(listener->fd, MAX_CONNECTIONS) != 0) goto failure;
    struct stat current;
    if (!socket_receipt(listener->directory, listener->name, &current)
        || current.st_dev != listener->receipt.st_dev || current.st_ino != listener->receipt.st_ino
        || (current.st_mode & 07777) != 0600) {
        result = JSTI_AUTOMATION_UNSAFE;
        goto failure;
    }
    result = jsti_automation_listener_status(listener);
    if (result != JSTI_AUTOMATION_OK) goto failure;
    *output = listener;
    return JSTI_AUTOMATION_OK;
failure:
    jsti_automation_release(listener);
    return result;
}

int jsti_automation_accept(JSTIAutomationListener *listener, JSTIAutomationConnection **output) {
    *output = NULL;
    for (;;) {
        int result = wait_fd(listener->fd, POLLIN, listener->cancel[0], UINT64_MAX);
        if (result != JSTI_AUTOMATION_OK) return result;
        result = jsti_automation_listener_status(listener);
        if (result != JSTI_AUTOMATION_OK) return result;
        int fd = accept4(listener->fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (fd < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (fd < 0) return JSTI_AUTOMATION_IO;
        if (!same_user(fd)) { close(fd); continue; }
        JSTIAutomationConnection *connection = calloc(1, sizeof(*connection));
        if (!connection) { close(fd); return JSTI_AUTOMATION_IO; }
        pthread_mutex_lock(&listener->lock);
        bool admitted = !listener->stopped && listener->count < MAX_CONNECTIONS;
        if (admitted) {
            connection->fd = fd;
            connection->owner = listener;
            connection->next = listener->connections;
            listener->connections = connection;
            listener->count++;
        }
        bool stopped = listener->stopped;
        pthread_mutex_unlock(&listener->lock);
        if (!admitted) {
            close(fd); free(connection);
            if (stopped) return JSTI_AUTOMATION_CANCELLED;
            continue;
        }
        *output = connection;
        return JSTI_AUTOMATION_OK;
    }
}

void jsti_automation_stop(JSTIAutomationListener *listener) {
    pthread_mutex_lock(&listener->lock);
    if (!listener->stopped) {
        listener->stopped = true;
        char byte = 1;
        /* Cancellation pipe is private and remains open until accept has joined. */
        (void)write(listener->cancel[1], &byte, 1);
        for (JSTIAutomationConnection *item = listener->connections; item; item = item->next)
            shutdown(item->fd, SHUT_RDWR);
    }
    pthread_mutex_unlock(&listener->lock);
}

void jsti_automation_release(JSTIAutomationListener *listener) {
    if (!listener) return;
    remove_owned(listener);
    if (listener->fd >= 0) close(listener->fd);
    if (listener->directory >= 0) close(listener->directory);
    if (listener->cancel[0] >= 0) close(listener->cancel[0]);
    if (listener->cancel[1] >= 0) close(listener->cancel[1]);
    pthread_mutex_destroy(&listener->lock);
    free(listener);
}

int jsti_automation_connect(const char *path, uint64_t deadline, JSTIAutomationConnection **output) {
    *output = NULL;
    int directory = -1;
    char name[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int result = open_directory(path, false, name, &directory);
    if (result != JSTI_AUTOMATION_OK) return result;
    struct stat value;
    if (!socket_receipt(directory, name, &value)
        || !jsti_automation_private_metadata(value.st_uid, value.st_mode, 0)) {
        result = errno == ENOENT ? JSTI_AUTOMATION_UNAVAILABLE : JSTI_AUTOMATION_UNSAFE;
        close(directory); return result;
    }
    struct sockaddr_un address;
    result = address_at(directory, name, &address);
    if (result != JSTI_AUTOMATION_OK) { close(directory); return result; }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) { close(directory); return JSTI_AUTOMATION_IO; }
    int connected = connect(fd, (struct sockaddr *)&address, sizeof(address));
    int failure = errno;
    if (connected != 0) {
        if (failure != EINPROGRESS) {
            close(fd); close(directory);
            return failure == ECONNREFUSED || failure == ENOENT ? JSTI_AUTOMATION_UNAVAILABLE : JSTI_AUTOMATION_IO;
        }
        result = wait_fd(fd, POLLOUT, -1, deadline);
        int error = 0;
        socklen_t size = sizeof(error);
        if (result != JSTI_AUTOMATION_OK || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error) {
            close(fd); close(directory);
            return result == JSTI_AUTOMATION_OK ? JSTI_AUTOMATION_UNAVAILABLE : result;
        }
    }
    struct stat current;
    bool unchanged = directory_identity(path, directory) && socket_receipt(directory, name, &current)
        && jsti_automation_private_metadata(current.st_uid, current.st_mode, 0)
        && current.st_dev == value.st_dev && current.st_ino == value.st_ino;
    close(directory);
    if (!unchanged || !same_user(fd)) { close(fd); return JSTI_AUTOMATION_UNSAFE; }
    JSTIAutomationConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { close(fd); return JSTI_AUTOMATION_IO; }
    connection->fd = fd;
    *output = connection;
    return JSTI_AUTOMATION_OK;
}

static int exchange(JSTIAutomationConnection *connection, void *bytes, size_t count, uint64_t deadline, bool writing) {
    size_t offset = 0;
    while (offset < count) {
        int result = wait_fd(connection->fd, writing ? POLLOUT : POLLIN,
                             connection->owner ? connection->owner->cancel[0] : -1, deadline);
        if (result != JSTI_AUTOMATION_OK) return result;
        ssize_t transferred = writing
            ? send(connection->fd, (const char *)bytes + offset, count - offset, MSG_NOSIGNAL)
            : recv(connection->fd, (char *)bytes + offset, count - offset, 0);
        if (transferred > 0) { offset += (size_t)transferred; continue; }
        if (transferred < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return JSTI_AUTOMATION_UNAVAILABLE;
    }
    return JSTI_AUTOMATION_OK;
}
int jsti_automation_read(JSTIAutomationConnection *connection, void *bytes, size_t count, uint64_t deadline) {
    return exchange(connection, bytes, count, deadline, false);
}
int jsti_automation_write(JSTIAutomationConnection *connection, const void *bytes, size_t count, uint64_t deadline) {
    return exchange(connection, (void *)bytes, count, deadline, true);
}
void jsti_automation_close(JSTIAutomationConnection *connection) {
    if (!connection) return;
    JSTIAutomationListener *listener = connection->owner;
    if (listener) {
        pthread_mutex_lock(&listener->lock);
        JSTIAutomationConnection **slot = &listener->connections;
        while (*slot && *slot != connection) slot = &(*slot)->next;
        if (*slot) { *slot = connection->next; listener->count--; }
        close(connection->fd);
        pthread_mutex_unlock(&listener->lock);
    } else close(connection->fd);
    free(connection);
}
