#ifndef JSTI_WINDOWS_CLIPBOARD_READ_H
#define JSTI_WINDOWS_CLIPBOARD_READ_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTIWindowsClipboardRead JSTIWindowsClipboardRead;
/* Read-only, single-use request. Run off the UI/capture thread. Only one native
 * worker is admitted process-wide, including a delayed-render worker whose
 * caller already timed out. Cancellation never closes another thread's
 * clipboard or terminates its worker. Destroy after run/cancel calls return. */
JSTIWindowsClipboardRead *jsti_windows_clipboard_read_create(
    size_t maximum_bytes, uint32_t timeout_ms, char *error, size_t error_capacity);
/* 0 text (including empty); 1 genuinely non-text; 2 oversized; 3 invalid text;
 * 4 deadline; 5 cancelled; 6 unsupported; 7 previous worker still cleaning up;
 * -1 native failure. Every failure writes an explicit error. */
int32_t jsti_windows_clipboard_read_run(JSTIWindowsClipboardRead *request,
    char *text, size_t text_capacity, char *error, size_t error_capacity);
void jsti_windows_clipboard_read_cancel(JSTIWindowsClipboardRead *request);
void jsti_windows_clipboard_read_destroy(JSTIWindowsClipboardRead *request);
/* Synthetic decoding/worker fixtures; never reads the system clipboard. */
int32_t jsti_windows_clipboard_read_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
