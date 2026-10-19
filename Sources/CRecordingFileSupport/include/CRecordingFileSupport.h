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

#ifdef __cplusplus
}
#endif
#endif
