#define _GNU_SOURCE
#include "LinuxSupportInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

static gboolean publication_cancelled(jsti_file_publication_cancelled_fn cancelled, void *context) {
    return cancelled != NULL && cancelled(context) != 0;
}

static gboolean private_regular_file(int descriptor, char *error, size_t capacity) {
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077) != 0) {
        jsti_set_error(error, capacity, "Export requires a private regular file owned by the current user.");
        return FALSE;
    }
    return TRUE;
}

static int copy_private_file(int source, int output, const struct stat *original,
                            jsti_file_publication_cancelled_fn cancelled, void *context,
                            char *error, size_t capacity) {
    if (error != NULL && capacity > 0) error[0] = 0;
    unsigned char buffer[64 * 1024];
    off_t remaining = original->st_size;
    while (remaining > 0) {
        if (publication_cancelled(cancelled, context)) return 2;
        size_t requested = remaining < (off_t)sizeof buffer ? (size_t)remaining : sizeof buffer;
        ssize_t count = read(source, buffer, requested);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            jsti_set_error(error, capacity, "Could not read private export: %s", g_strerror(errno));
            return -1;
        }
        if (count == 0) {
            jsti_set_error(error, capacity, "The private export source changed while it was being copied.");
            return -1;
        }
        for (ssize_t offset = 0; offset < count;) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                jsti_set_error(error, capacity, "Could not write private export: %s", g_strerror(errno));
                return -1;
            }
            offset += written;
        }
        remaining -= count;
    }
    if (publication_cancelled(cancelled, context)) return 2;
    struct stat current;
    if (fstat(source, &current) != 0 || current.st_size != original->st_size ||
        current.st_mtim.tv_sec != original->st_mtim.tv_sec ||
        current.st_mtim.tv_nsec != original->st_mtim.tv_nsec ||
        current.st_ctim.tv_sec != original->st_ctim.tv_sec ||
        current.st_ctim.tv_nsec != original->st_ctim.tv_nsec) {
        jsti_set_error(error, capacity, "The private export source changed while it was being copied.");
        return -1;
    }
    if (fsync(output) != 0) {
        jsti_set_error(error, capacity, "Could not flush private export: %s", g_strerror(errno));
        return -1;
    }
    return 0;
}

static int create_publication_file(int parent, gchar **name, char *error, size_t capacity) {
    int output = openat(parent, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
    if (output >= 0) return output;
    if (errno != EOPNOTSUPP && errno != EINVAL && errno != EISDIR && errno != ENOSYS) {
        jsti_set_error(error, capacity, "Could not create anonymous private export staging: %s", g_strerror(errno));
        return -1;
    }
    struct stat info;
    if (fstat(parent, &info) != 0 || info.st_uid != geteuid() || (info.st_mode & 0022) != 0) {
        jsti_set_error(error, capacity,
                       "This destination does not support anonymous private staging. Choose a folder "
                       "owned by your account that other accounts cannot modify.");
        return -1;
    }
    gchar *identifier = g_uuid_string_random();
    *name = g_strconcat(".jsti-export-", identifier, ".partial", NULL);
    g_free(identifier);
    output = openat(parent, *name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) jsti_set_error(error, capacity, "Could not create private export: %s", g_strerror(errno));
    return output;
}

static int commit_publication(int parent, int output, const char *name, const char *target,
                              char *error, size_t capacity) {
    if (name != NULL) {
        if (syscall(SYS_renameat2, parent, name, parent, target, RENAME_NOREPLACE) == 0) return 0;
    } else {
        if (linkat(output, "", parent, target, AT_EMPTY_PATH) == 0) return 0;
        if (errno == EPERM || errno == ENOENT) {
            /* Documented unprivileged O_TMPFILE publication through the held fd. */
            char source[64];
            snprintf(source, sizeof source, "/proc/self/fd/%d", output);
            if (linkat(AT_FDCWD, source, parent, target, AT_SYMLINK_FOLLOW) == 0) return 0;
        }
    }
    jsti_set_error(error, capacity, "Could not publish export without replacing an existing file: %s",
                   g_strerror(errno));
    return -1;
}

static void close_publication_file(int descriptor, int *result, char *error, size_t capacity) {
    if (descriptor < 0 || close(descriptor) == 0) return;
    gboolean committed = *result == 0 || *result == 3;
    jsti_set_error(error, capacity, "%s a native file handle could not be closed: %s",
                   committed ? "The export was published, but" : "Export failed and", g_strerror(errno));
    *result = committed ? 3 : -1;
}

int32_t jsti_private_file_publish(const char *source_path, const char *destination,
                                  jsti_file_publication_cancelled_fn cancelled, void *context,
                                  char *error, size_t capacity) {
    if (publication_cancelled(cancelled, context)) return 2;
    if (source_path == NULL || source_path[0] != '/' || destination == NULL || destination[0] != '/') {
        jsti_set_error(error, capacity, "Private export requires absolute source and destination paths.");
        return -1;
    }
    if (destination[strlen(destination) - 1] == '/') {
        jsti_set_error(error, capacity, "Private export requires a destination filename, not a folder.");
        return -1;
    }
    int result = -1;
    int source = -1, parent = -1, output = -1;
    gchar *folder = g_path_get_dirname(destination);
    gchar *target = g_path_get_basename(destination);
    gchar *name = NULL;
    struct stat original;
    if (strcmp(target, ".") == 0 || strcmp(target, "..") == 0) {
        jsti_set_error(error, capacity, "Private export requires a destination filename, not a folder.");
        goto done;
    }
    source = open(source_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (source < 0 || !private_regular_file(source, error, capacity)) {
        if (source < 0) jsti_set_error(error, capacity, "Could not open private export: %s", g_strerror(errno));
        goto done;
    }
    if (fstat(source, &original) != 0 || original.st_size < 0) {
        jsti_set_error(error, capacity, "Could not inspect private export size: %s", g_strerror(errno));
        goto done;
    }
    parent = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent < 0) {
        jsti_set_error(error, capacity, "Could not open export folder: %s", g_strerror(errno));
        goto done;
    }
    output = create_publication_file(parent, &name, error, capacity);
    if (output < 0 || !private_regular_file(output, error, capacity)) goto done;
    result = copy_private_file(source, output, &original, cancelled, context, error, capacity);
    if (result != 0) goto done;
    if (publication_cancelled(cancelled, context)) {
        result = 2;
        goto done;
    }
    result = commit_publication(parent, output, name, target, error, capacity);
    if (result == 0 && fsync(parent) != 0) {
        jsti_set_error(error, capacity, "Export was published, but its folder could not be flushed: %s",
                       g_strerror(errno));
        result = 3;
    }
done:
    if (result != 0 && result != 3 && name != NULL && output >= 0 && unlinkat(parent, name, 0) != 0) {
        jsti_set_error(error, capacity, "Export failed and private staging %s could not be removed: %s",
                       name, g_strerror(errno));
        result = -1;
    }
    close_publication_file(output, &result, error, capacity);
    close_publication_file(parent, &result, error, capacity);
    close_publication_file(source, &result, error, capacity);
    g_free(folder);
    g_free(target);
    g_free(name);
    return result;
}
