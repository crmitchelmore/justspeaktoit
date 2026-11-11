#ifndef JSTI_LINUX_SELF_TEST_H
#define JSTI_LINUX_SELF_TEST_H
/* The window checks behind SpeakLinux --ui-smoke-test. They live in their own
 * target so CLinuxSupport holds product code only. The executable still links
 * them: CI and the installed-Flatpak checks qualify the exact shipped binary. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Main thread only: exercises widget construction and event plumbing. */
int32_t jsti_window_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
