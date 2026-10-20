#ifndef JSTI_C_RECORDING_FILE_SUPPORT_H
#define JSTI_C_RECORDING_FILE_SUPPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int owned_fd;
    int primary_errno;
    int cleanup_errno;
    int unsupported;
} jsti_recording_create_result;

typedef struct {
    int primary_errno;
    int cleanup_errno;
    int did_publish;
    int unsupported;
} jsti_recording_publish_result;

/* Transfers one anonymous FD on success; otherwise closes its own allocation once. */
jsti_recording_create_result jsti_recording_anonymous_create(int borrowed_directory_fd);

/* Borrows both FDs. did_publish is irreversible even when verification/teardown fails. */
jsti_recording_publish_result jsti_recording_anonymous_publish(
    int borrowed_file_fd, int borrowed_directory_fd, const char *canonical_leaf);

/* Atomically replaces a sibling name and consumes staging only on success.
 * Both paths are borrowed, NUL-terminated UTF-8. Returns 0 on success, otherwise
 * the captured Win32 error on Windows or errno on POSIX. Never copies/unlinks. */
uint32_t jsti_file_replace(const char *staging_path, const char *destination_path);

typedef struct jsti_scratch_owner jsti_scratch_owner;

/* The caller prepares a private, app-owned root first. A competing owner,
 * including one in this process, is refused until close/process exit.
 * Only uppercase UUID leaves containing instruction.wav (or nothing) are
 * mutable. Links, extra entries and changed/unsafe objects are refused. */
uint32_t jsti_scratch_open(const char *root, jsti_scratch_owner **owner);
uint32_t jsti_scratch_create(jsti_scratch_owner *owner, const char *run);
uint32_t jsti_scratch_remove(jsti_scratch_owner *owner, const char *run);
uint32_t jsti_scratch_close(jsti_scratch_owner *owner);

#ifdef __cplusplus
}
#endif
#endif
