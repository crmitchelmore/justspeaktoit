#ifndef JSTI_LINUX_CREDENTIALS_H
#define JSTI_LINUX_CREDENTIALS_H
/* Secret Service credentials. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* libsecret Secret Service (GNOME Keyring, KWallet, or the Secret portal in
 * Flatpak). Returns 1 when no secret is stored. */
int32_t jsti_credential_read(
    const char *name, uint8_t *buffer, size_t capacity, size_t *count, char *error, size_t error_capacity);
int32_t jsti_credential_write(
    const char *name, const uint8_t *bytes, size_t count, char *error, size_t error_capacity);
int32_t jsti_credential_delete(const char *name, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
