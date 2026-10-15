#define _GNU_SOURCE
#include "../Sources/CRecordingFileSupport/include/CRecordingFileSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
#include <unistd.h>

#if !defined(__linux__)
#error This observation requires Linux and the production Linux adapter.
#endif

static int failed(const char *operation) {
    fprintf(stderr, "diagnostic-error operation=%s errno=%d\n", operation, errno);
    return 2;
}

static int invalid(const char *operation) {
    fprintf(stderr, "diagnostic-error invariant=%s\n", operation);
    return 2;
}

static int private_root(const char *path, struct stat *identity) {
    char canonical[PATH_MAX];
    if (!realpath(path, canonical)) return -1;
    if (path[0] != '/' || strcmp(path, canonical)) { errno = EINVAL; return -1; }
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat named;
    if (fstat(fd, identity) || lstat(path, &named)) {
        int error = errno;
        if (close(fd)) fprintf(stderr, "diagnostic-error operation=close-root errno=%d\n", errno);
        errno = error;
        return -1;
    }
    if (!S_ISDIR(identity->st_mode) || identity->st_uid != geteuid() ||
        (identity->st_mode & 0777) != 0700 || named.st_dev != identity->st_dev ||
        named.st_ino != identity->st_ino || !S_ISDIR(named.st_mode)) {
        if (close(fd)) fprintf(stderr, "diagnostic-error operation=close-root errno=%d\n", errno);
        errno = EACCES;
        return -1;
    }
    return fd;
}

static int observe_filesystem(const char *label, const char *path, int fd, const struct stat *identity) {
    struct statfs held, named;
    struct stat current;
    if (fstatfs(fd, &held) || statfs(path, &named) || lstat(path, &current)) return failed("filesystem");
    if (held.f_type != named.f_type || held.f_fsid.__val[0] != named.f_fsid.__val[0] ||
        held.f_fsid.__val[1] != named.f_fsid.__val[1] ||
        current.st_dev != identity->st_dev || current.st_ino != identity->st_ino ||
        !S_ISDIR(current.st_mode)) return invalid("filesystem-path-identity");
    printf("%s path=%s dev=%ju major=%u minor=%u inode=%ju owner=%ju mode=%o "
           "fstatfsType=0x%jx statfsType=0x%jx fsid=%x:%x\n",
           label, path, (uintmax_t)identity->st_dev, major(identity->st_dev), minor(identity->st_dev),
           (uintmax_t)identity->st_ino, (uintmax_t)identity->st_uid,
           (unsigned)(identity->st_mode & 07777), (uintmax_t)held.f_type, (uintmax_t)named.f_type,
           (unsigned)held.f_fsid.__val[0], (unsigned)held.f_fsid.__val[1]);
    return 0;
}

static int observe_proc(dev_t device) {
    FILE *status = fopen("/proc/self/status", "re");
    if (!status) return failed("open-status");
    char line[4096];
    int zero_caps = 0;
    while (fgets(line, sizeof(line), status)) {
        if (!strchr(line, '\n')) { fclose(status); return invalid("status-line-budget"); }
        if (!strncmp(line, "CapEff:", 7)) {
            printf("%s", line);
            zero_caps = !strcmp(line, "CapEff:\t0000000000000000\n");
        }
    }
    int read_error = ferror(status);
    if (fclose(status)) return failed("close-status");
    if (read_error) return failed("read-status");
    if (!zero_caps) return invalid("effective-capabilities");
    FILE *mounts = fopen("/proc/self/mountinfo", "re");
    if (!mounts) return failed("open-mountinfo");
    unsigned matches = 0;
    while (fgets(line, sizeof(line), mounts)) {
        if (!strchr(line, '\n')) { fclose(mounts); return invalid("mountinfo-line-budget"); }
        unsigned observed_major, observed_minor;
        if (sscanf(line, "%*u %*u %u:%u", &observed_major, &observed_minor) != 2) {
            fclose(mounts);
            return invalid("mountinfo-record");
        }
        if (observed_major == major(device) && observed_minor == minor(device)) {
            printf("selected-mountinfo %s", line);
            if (++matches > 32) { fclose(mounts); return invalid("mountinfo-match-budget"); }
        }
    }
    read_error = ferror(mounts);
    if (fclose(mounts)) return failed("close-mountinfo");
    if (read_error) return failed("read-mountinfo");
    return matches ? 0 : invalid("mountinfo-device-missing");
}

static int unsupported(int code, int flag) {
    return flag == 1 && (code == EOPNOTSUPP || code == ENOSYS || code == ENODEV ||
                        code == ENOENT || code == ENOTDIR || code == EACCES || code == EPERM);
}

static int exercise(int directory) {
    jsti_recording_create_result created = jsti_recording_anonymous_create(directory);
    printf("native-create primary_errno=%d unsupported=%d owned_fd=%d cleanup_errno=%d\n",
           created.primary_errno, created.unsupported, created.owned_fd, created.cleanup_errno);
    if (created.owned_fd < 0) {
        if (created.cleanup_errno || !created.primary_errno) return invalid("create-outcome");
        if (unsupported(created.primary_errno, created.unsupported)) {
            printf("observation=unavailable stage=create noRetry=1 noFallback=1\n");
            return 0;
        }
        return invalid("unexpected-native-create-failure");
    }
    int result = 0;
    struct stat identity;
    if (created.primary_errno || created.cleanup_errno || created.unsupported) {
        result = invalid("create-owned-outcome");
    } else if (fstat(created.owned_fd, &identity)) {
        result = failed("fstat-anonymous");
    } else {
        printf("anonymous dev=%ju inode=%ju owner=%ju mode=%o nlink=%ju size=%jd\n",
               (uintmax_t)identity.st_dev, (uintmax_t)identity.st_ino, (uintmax_t)identity.st_uid,
               (unsigned)(identity.st_mode & 07777), (uintmax_t)identity.st_nlink, (intmax_t)identity.st_size);
        if (!S_ISREG(identity.st_mode) || identity.st_uid != geteuid() ||
            (identity.st_mode & 07777) != 0600 || identity.st_nlink != 0 || identity.st_size != 0) {
            result = invalid("anonymous-invariants");
        }
    }
    const unsigned char bytes[] = {74, 83, 84, 73};
    if (!result && write(created.owned_fd, bytes, sizeof(bytes)) != (ssize_t)sizeof(bytes)) {
        result = failed("write-diagnostic-bytes");
    }
    if (!result && (fchmod(created.owned_fd, 0400) || fsync(created.owned_fd))) result = failed("seal-diagnostic");
    if (!result) {
        jsti_recording_publish_result published =
            jsti_recording_anonymous_publish(created.owned_fd, directory, "registry.jloc");
        printf("native-publish primary_errno=%d unsupported=%d did_publish=%d cleanup_errno=%d\n",
               published.primary_errno, published.unsupported, published.did_publish, published.cleanup_errno);
        if (published.cleanup_errno || (published.did_publish != 0 && published.did_publish != 1)) {
            result = invalid("publish-outcome");
        } else if (published.primary_errno) {
            if (unsupported(published.primary_errno, published.unsupported)) {
                printf("observation=unavailable stage=publish published=%d noRetry=1 noFallback=1\n",
                       published.did_publish);
            } else result = invalid("unexpected-native-publish-failure");
        } else if (published.did_publish != 1 || published.unsupported) {
            result = invalid("publish-success-outcome");
        } else {
            struct stat named;
            unsigned char observed[sizeof(bytes)];
            if (fsync(directory) || fstat(created.owned_fd, &identity) ||
                fstatat(directory, "registry.jloc", &named, AT_SYMLINK_NOFOLLOW) ||
                pread(created.owned_fd, observed, sizeof(observed), 0) != (ssize_t)sizeof(observed)) {
                result = failed("verify-publication");
            } else if (!S_ISREG(named.st_mode) || named.st_dev != identity.st_dev ||
                       named.st_ino != identity.st_ino || identity.st_uid != geteuid() ||
                       (identity.st_mode & 07777) != 0400 || identity.st_nlink != 1 ||
                       identity.st_size != (off_t)sizeof(bytes) || memcmp(bytes, observed, sizeof(bytes))) {
                result = invalid("published-invariants");
            } else printf("observation=available published=1 mode=400 nlink=1 diagnosticBytesOnly=1\n");
        }
    }
    if (close(created.owned_fd)) result = failed("close-owned-anonymous");
    return result;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("DIAGNOSTIC ONLY: production anonymous capability, no root repair or cleanup.\n");
    if (argc != 4 || !*argv[3] || strspn(argv[3], "0123456789") != strlen(argv[3])) {
        return invalid("arguments: sourceRoot privateTMPDIR expectedUID");
    }
    errno = 0;
    uintmax_t expected = strtoumax(argv[3], NULL, 10);
    if (errno || expected != (uintmax_t)geteuid() || geteuid() == 0 || getuid() != geteuid()) {
        return invalid("expected-nonroot-identity");
    }
    printf("pid=%jd uid=%ju euid=%ju gid=%ju HOME=%s TMPDIR=%s\n", (intmax_t)getpid(),
           (uintmax_t)getuid(), (uintmax_t)geteuid(), (uintmax_t)getgid(), getenv("HOME") ? getenv("HOME") : "(unset)",
           getenv("TMPDIR") ? getenv("TMPDIR") : "(unset)");
    struct stat source, parent;
    int source_fd = private_root(argv[1], &source);
    if (source_fd < 0) return failed("open-source-root");
    int parent_fd = private_root(argv[2], &parent);
    int result = 0, directory = -1;
    if (parent_fd < 0) { result = failed("open-private-parent"); goto finish; }
    if (source.st_dev != parent.st_dev) { result = invalid("source-parent-filesystem"); goto finish; }
    result = observe_filesystem("source", argv[1], source_fd, &source);
    if (!result) result = observe_filesystem("parent", argv[2], parent_fd, &parent);
    if (!result) result = observe_proc(parent.st_dev);
    if (result) goto finish;
    unsigned char random[16];
    if (getrandom(random, sizeof(random), 0) != (ssize_t)sizeof(random)) {
        result = failed("getrandom"); goto finish;
    }
    char leaf[sizeof("jsti-registry-capability-") + sizeof(random) * 2];
    strcpy(leaf, "jsti-registry-capability-");
    for (size_t index = 0; index < sizeof(random); ++index) {
        snprintf(leaf + strlen("jsti-registry-capability-") + index * 2, 3, "%02x", (unsigned)random[index]);
    }
    if (mkdirat(parent_fd, leaf, 0700)) { result = failed("exclusive-fixture-create"); goto finish; }
    printf("fixture=%s/%s retained=1\n", argv[2], leaf);
    directory = openat(parent_fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) { result = failed("open-owned-fixture"); goto finish; }
    struct stat held, named;
    if (fstat(directory, &held) || fstatat(parent_fd, leaf, &named, AT_SYMLINK_NOFOLLOW)) {
        result = failed("fixture-identity"); goto finish;
    }
    if (!S_ISDIR(held.st_mode) || held.st_uid != geteuid() || (held.st_mode & 07777) != 0700 ||
        !S_ISDIR(named.st_mode) || named.st_dev != held.st_dev || named.st_ino != held.st_ino) {
        result = invalid("private-fixture-identity"); goto finish;
    }
    result = exercise(directory);
finish:
    if (directory >= 0 && close(directory)) result = failed("close-fixture");
    if (parent_fd >= 0 && close(parent_fd)) result = failed("close-parent");
    if (close(source_fd)) result = failed("close-source");
    printf("diagnostic-exit=%d retainedFixture=1\n", result);
    return result;
}
