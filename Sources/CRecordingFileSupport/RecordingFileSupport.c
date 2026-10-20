#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "CRecordingFileSupport.h"
#include <errno.h>

#if defined(__linux__)
#include <fcntl.h>
#include <linux/magic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

static int secure_directory(int fd, uid_t owner, int private_leaf) {
    struct stat value;
    if (fstat(fd, &value) != 0) return errno;
    if (!S_ISDIR(value.st_mode) || value.st_uid != owner ||
        (value.st_mode & (private_leaf ? 0077 : 0022))) return EACCES;
    return 0;
}

static int proc_directory(int fd, uid_t owner, int *unsupported) {
    struct statfs filesystem;
    int error = secure_directory(fd, owner, 0);
    if (error) return error;
    if (fstatfs(fd, &filesystem) != 0) return errno;
    if (filesystem.f_type != PROC_SUPER_MAGIC) {
        *unsupported = 1;
        return ENODEV;
    }
    return 0;
}

static int immutable_file(int fd, nlink_t links, struct stat *value) {
    if (fstat(fd, value) != 0) return errno;
    if (!S_ISREG(value->st_mode) || value->st_uid != geteuid() ||
        (value->st_mode & 0777) != 0400 || value->st_nlink != links ||
        value->st_size <= 0 || value->st_size > 16384) return EACCES;
    return 0;
}

static int canonical_leaf(const char *leaf) {
    if (!leaf) return 0;
    if (!strcmp(leaf, "registry.jloc")) return 1;
    const char *id;
    if (!strncmp(leaf, "registration-", 13)) id = leaf + 13;
    else if (!strncmp(leaf, "ownership-", 10)) id = leaf + 10;
    else return 0;
    if (strlen(id) != 41 || strcmp(id + 36, ".jloc")) return 0;
    for (int index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (id[index] != '-') return 0;
        } else if (!((id[index] >= '0' && id[index] <= '9') || (id[index] >= 'A' && id[index] <= 'F'))) {
            return 0;
        }
    }
    return 1;
}

static void close_owned(int fd, int *cleanup) {
    if (fd >= 0 && close(fd) != 0 && !*cleanup) *cleanup = errno;
}

static int unavailable_proc(int error) {
    return error == ENOENT || error == ENOTDIR || error == EACCES || error == EPERM || error == ENOSYS;
}

jsti_recording_create_result jsti_recording_anonymous_create(int directory) {
    jsti_recording_create_result result = {-1, 0, 0, 0};
    result.primary_errno = secure_directory(directory, geteuid(), 1);
    if (result.primary_errno) return result;
    int fd = openat(directory, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) {
        result.primary_errno = errno;
        result.unsupported = errno == EOPNOTSUPP || errno == ENOSYS;
        return result;
    }
    struct stat value;
    if (fstat(fd, &value) != 0) result.primary_errno = errno;
    else if (!S_ISREG(value.st_mode) || value.st_uid != geteuid() || value.st_nlink != 0 ||
             (value.st_mode & 0777) != 0600 || value.st_size != 0) result.primary_errno = EACCES;
    if (result.primary_errno) close_owned(fd, &result.cleanup_errno);
    else result.owned_fd = fd;
    return result;
}

jsti_recording_publish_result jsti_recording_anonymous_publish(int file, int directory, const char *leaf) {
    jsti_recording_publish_result result = {0, 0, 0, 0};
    int root = -1, proc = -1, process = -1, fds = -1, view = -1;
    struct stat before, observed, after, named;
    char pid[32], number[32];
    if (!canonical_leaf(leaf)) { result.primary_errno = EINVAL; goto finish; }
    result.primary_errno = secure_directory(directory, geteuid(), 1);
    if (result.primary_errno) goto finish;
    result.primary_errno = immutable_file(file, 0, &before);
    if (result.primary_errno) goto finish;
    root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { result.primary_errno = errno; goto finish; }
    result.primary_errno = secure_directory(root, 0, 0);
    if (result.primary_errno) goto finish;
    proc = openat(root, "proc", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (proc < 0) { result.primary_errno = errno; result.unsupported = unavailable_proc(errno); goto finish; }
    result.primary_errno = proc_directory(proc, 0, &result.unsupported);
    if (result.primary_errno) goto finish;
    snprintf(pid, sizeof(pid), "%ld", (long)getpid());
    process = openat(proc, pid, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (process < 0) { result.primary_errno = errno; result.unsupported = unavailable_proc(errno); goto finish; }
    result.primary_errno = proc_directory(process, geteuid(), &result.unsupported);
    if (result.primary_errno) goto finish;
    fds = openat(process, "fd", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fds < 0) { result.primary_errno = errno; result.unsupported = unavailable_proc(errno); goto finish; }
    result.primary_errno = proc_directory(fds, geteuid(), &result.unsupported);
    if (result.primary_errno) goto finish;
    snprintf(number, sizeof(number), "%d", file);
    /* Only the kernel FD entry under the held, verified real procfs chain is followed. */
    view = openat(fds, number, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (view < 0) { result.primary_errno = errno; result.unsupported = unavailable_proc(errno); goto finish; }
    if (fstat(view, &observed) != 0) { result.primary_errno = errno; goto finish; }
    if (observed.st_dev != before.st_dev || observed.st_ino != before.st_ino) {
        result.primary_errno = ESTALE; goto finish;
    }
    close_owned(view, &result.cleanup_errno);
    view = -1;
    if (result.cleanup_errno) goto finish;
    if (linkat(fds, number, directory, leaf, AT_SYMLINK_FOLLOW) != 0) {
        result.primary_errno = errno;
        result.unsupported = errno == ENOSYS || errno == EOPNOTSUPP;
        goto finish;
    }
    result.did_publish = 1;
    result.primary_errno = immutable_file(file, 1, &after);
    if (result.primary_errno) goto finish;
    if (fstatat(directory, leaf, &named, AT_SYMLINK_NOFOLLOW) != 0) {
        result.primary_errno = errno; goto finish;
    }
    if (after.st_dev != before.st_dev || after.st_ino != before.st_ino ||
        named.st_dev != after.st_dev || named.st_ino != after.st_ino || !S_ISREG(named.st_mode)) {
        result.primary_errno = ESTALE;
    }
finish:
    close_owned(view, &result.cleanup_errno);
    close_owned(fds, &result.cleanup_errno);
    close_owned(process, &result.cleanup_errno);
    close_owned(proc, &result.cleanup_errno);
    close_owned(root, &result.cleanup_errno);
    return result;
}
#else
jsti_recording_create_result jsti_recording_anonymous_create(int directory) {
    (void)directory;
    jsti_recording_create_result result = {-1, ENOSYS, 0, 1};
    return result;
}
jsti_recording_publish_result jsti_recording_anonymous_publish(int file, int directory, const char *leaf) {
    (void)file; (void)directory; (void)leaf;
    jsti_recording_publish_result result = {ENOSYS, 0, 0, 1};
    return result;
}
#endif
