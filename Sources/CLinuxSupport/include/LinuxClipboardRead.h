#ifndef JSTI_LINUX_CLIPBOARD_READ_H
#define JSTI_LINUX_CLIPBOARD_READ_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTILinuxClipboardRead JSTILinuxClipboardRead;
/* Single-use, read-only X11 request. Run outside the GTK/capture thread.
 * One outstanding request includes cancelled reads awaiting native cleanup.
 * Destroy only after run/cancel calls return. Wayland is explicitly unsupported. */
JSTILinuxClipboardRead *jsti_linux_clipboard_read_create(
    size_t maximum_bytes, uint32_t timeout_ms, char *error, size_t error_capacity);
/* Same status contract as Windows: 0 text, 1 genuinely non-text, 2 oversized,
 * 3 invalid text, 4 deadline, 5 cancelled, 6 unsupported, 7 cleanup busy,
 * -1 native failure. Output capacity must exceed maximum_bytes. */
int32_t jsti_linux_clipboard_read_run(JSTILinuxClipboardRead *request,
    char *text, size_t text_capacity, char *error, size_t error_capacity);
void jsti_linux_clipboard_read_cancel(JSTILinuxClipboardRead *request);
void jsti_linux_clipboard_read_destroy(JSTILinuxClipboardRead *request);
/* Synthetic GMemoryInputStream fixtures; never reads a display clipboard. */
int32_t jsti_linux_clipboard_read_self_test(char *error, size_t error_capacity);
#ifdef __cplusplus
}
#endif
#endif
