#ifndef JSTI_LINUX_DIAGNOSTICS_H
#define JSTI_LINUX_DIAGNOSTICS_H
/* Deterministic native self-test. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Deterministic checks of file security, UTF-8 handling and PCM framing that
 * need no display, microphone or keyring. */
int32_t jsti_native_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
