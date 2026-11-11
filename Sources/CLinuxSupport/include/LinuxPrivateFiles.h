#ifndef JSTI_LINUX_PRIVATE_FILES_H
#define JSTI_LINUX_PRIVATE_FILES_H
/* Private files and directories. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Creates a directory (and parents) readable only by the current user, or
 * tightens an existing one. Refuses symbolic links. */
int32_t jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
int32_t jsti_private_directory_create(const char *path, char *error, size_t error_capacity);
/* Creates a new empty file with mode 0600; refuses existing paths and links. */
int32_t jsti_private_file_create(const char *path, char *error, size_t error_capacity);
/* Private bounded copy and exclusive publication; source retained.
 * Returns 0 committed, 2 cancelled before commit, -1 failed, or 3 committed
 * with a cleanup/durability error. Never retry or remove a result-3 destination.
 * A filesystem without exclusive publication support fails explicitly. */
typedef int (*jsti_file_publication_cancelled_fn)(void *context);
int32_t jsti_private_file_publish(const char *source, const char *destination,
                                  jsti_file_publication_cancelled_fn cancelled, void *context,
                                  char *error, size_t error_capacity);
int32_t jsti_open_path(const char *path, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
