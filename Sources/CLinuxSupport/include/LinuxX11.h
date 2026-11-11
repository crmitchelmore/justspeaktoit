#ifndef JSTI_LINUX_X11_H
#define JSTI_LINUX_X11_H
/* X11 shortcuts, input and selection. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the process can reach an X server through $DISPLAY. */
int32_t jsti_x11_available(void);
/* The focused top-level window (_NET_ACTIVE_WINDOW) and its WM_CLASS class
 * and pid (_NET_WM_PID, 0 if unknown). Returns 1 when none is active. */
int32_t jsti_x11_active_window(
    uint64_t *window, char *wm_class, size_t wm_class_capacity, int32_t *pid, char *error, size_t error_capacity);
/* Sends Ctrl+V (Ctrl+Shift+V when `shift`) with XTest, only if `window` is
 * still the active window. */
int32_t jsti_x11_paste(uint64_t window, int32_t shift, char *error, size_t error_capacity);

typedef void (*jsti_hotkey_fn)(int32_t pressed, void *context);
/* Grabs `keysym` with `modifiers` (the low eight X11 modifier bits) on the root
 * window from a dedicated thread and reports presses and releases. Requires a
 * non-null callback. Lock-only slots are discovered at registration, never
 * guessed from Mod2/Mod5; mixed or explicitly required slots are not ignored.
 * Runtime keyboard remapping still requires restarting the listener. */
int32_t jsti_x11_hotkey_start(
    uint32_t keysym, uint32_t modifiers, jsti_hotkey_fn callback, void *context, char *error, size_t error_capacity);
void jsti_x11_hotkey_stop(void);

/* Separate action group: never replaces the dictation listener. Each row needs
 * Ctrl/Alt or F13-F24. Result lookup is valid until stop; failures are per row.
 * callback receives a canonical action index on first press, -1 on listener loss.
 * Stop joins callbacks and must not run on that callback thread. */
typedef struct JSTIX11ActionShortcuts JSTIX11ActionShortcuts;
typedef struct JSTIX11ActionShortcut {
    uint32_t keysym, modifiers;
    int32_t identifier;
} JSTIX11ActionShortcut;
typedef void (*jsti_action_shortcut_fn)(int32_t identifier, void *context);
JSTIX11ActionShortcuts *jsti_x11_action_shortcuts_start(
    const JSTIX11ActionShortcut *rows, size_t count, jsti_action_shortcut_fn callback, void *context,
    char *error, size_t error_capacity);
int32_t jsti_x11_action_shortcuts_result(
    JSTIX11ActionShortcuts *listener, size_t row, char *error, size_t error_capacity);
void jsti_x11_action_shortcuts_stop(JSTIX11ActionShortcuts *listener);

#ifdef __cplusplus
}
#endif
#endif
