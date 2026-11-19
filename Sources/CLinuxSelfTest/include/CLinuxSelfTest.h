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

/* The capture ring and writer, without a sound server: FIFO order, bounded
 * capacity with no overwrite, delivery off the producer thread before finish
 * returns, and one overflow or reported failure after the audio accepted
 * before it. */
int32_t jsti_pcm_writer_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
