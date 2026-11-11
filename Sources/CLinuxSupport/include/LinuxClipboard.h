#ifndef JSTI_LINUX_CLIPBOARD_H
#define JSTI_LINUX_CLIPBOARD_H
/* The GTK and X11 clipboard. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The GTK clipboard of this app's display. Safe from any thread: the work runs
 * on the GTK main thread and the caller waits (bounded). Wayland compositors
 * only accept a selection from the focused client; see jsti_portal_*. */
int32_t jsti_clipboard_write(const char *text, char *error, size_t error_capacity);
/* X11-only owned selection and atomic restore. Restore returns 2 when another
 * copy superseded the receipt, even if its text is identical. */
int32_t jsti_clipboard_write_owned(const char *text, uint64_t *ownership, char *error, size_t error_capacity);
int32_t jsti_clipboard_restore(const char *text, uint64_t ownership, char *error, size_t error_capacity);
int32_t jsti_clipboard_ownership_self_test(char *error, size_t error_capacity);
/* Returns 1 when the clipboard holds no text. `*text` is malloc'ed. */
int32_t jsti_clipboard_read(char **text, char *error, size_t error_capacity);
/* Read-only, bounded GTK async stream with a 2.5 second cancellation budget.
 * Must be called off the GTK thread. Returns 1 for non-text. Free with jsti_free. */
int32_t jsti_voice_command_clipboard_read(char **text, char *error, size_t error_capacity);
void jsti_free(void *pointer);

#ifdef __cplusplus
}
#endif
#endif
