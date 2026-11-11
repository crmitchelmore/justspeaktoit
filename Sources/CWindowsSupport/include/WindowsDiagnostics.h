#ifndef JSTI_WINDOWS_DIAGNOSTICS_H
#define JSTI_WINDOWS_DIAGNOSTICS_H
/* Console streams and smoke-test diagnostics. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Gives the GUI-subsystem app a valid stdout/stderr: missing streams bind to
 * the parent console when attach_parent is nonzero and one exists, otherwise
 * to NUL. Returns 1 when it attached to the parent console, 0 otherwise. */
int32_t jsti_console_prepare(int32_t attach_parent);
int jsti_audio_devices_self_test(char *error, size_t error_capacity);
/* Call on the UI thread from READY in smoke-test mode. Verifies native control
 * bounds, history updates/events, search/filter selection handling, transcript
 * variant action identities, an invisible settings Apply round-trip and the Text
 * output dialog: every choice through its controls, Cancel/Escape/Enter,
 * keyboard order, minimum bounds and its modal loop blocking recording.
 * Restores history and text output configuration afterwards; never uses
 * microphone, clipboard or credentials. */
int jsti_window_self_test(char *error, size_t error_capacity);
/* Smoke-test diagnostics only: writes a 32-bit BMP of this application's client
 * window and controls. Call on the UI thread after READY. Never captures the
 * desktop or another app; caller provides a smoke-test state without secrets. */
int jsti_window_save_snapshot(const char *path, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
