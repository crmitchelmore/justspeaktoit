#ifndef JSTI_LINUX_PORTALS_H
#define JSTI_LINUX_PORTALS_H
/* XDG desktop portals: shortcuts, remote desktop and background. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "LinuxX11.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when org.freedesktop.portal.Desktop exposes `interface` (for example
 * "org.freedesktop.portal.GlobalShortcuts") on the session bus. */
int32_t jsti_portal_available(const char *interface_name, uint32_t *version);

/* GlobalShortcuts: binds one shortcut and reports Activated (1) and
 * Deactivated (0). The desktop may ask the user to confirm the trigger. */
int32_t jsti_shortcuts_start(
    const char *shortcut_id, const char *description, const char *preferred_trigger, jsti_hotkey_fn callback,
    void *context, char *trigger_description, size_t trigger_capacity, char *error, size_t error_capacity);
void jsti_shortcuts_stop(void);

/* RemoteDesktop with keyboard access and the Clipboard portal in one session.
 * `restore_token` may be NULL or empty; a new token (persist mode 2) is
 * written to `new_token` when the portal returns one. The first call shows the
 * desktop's consent dialog. */
int32_t jsti_remote_desktop_start(
    const char *restore_token, char *new_token, size_t new_token_capacity, char *error, size_t error_capacity);
/* 0 inactive, 1 keyboard only, 2 keyboard with the shared clipboard. */
int32_t jsti_remote_desktop_active(void);
/* Offers `text` as the session clipboard selection (NULL offers nothing),
 * then presses Ctrl+V (Ctrl+Shift+V when `shift`) through keysyms, so the
 * compositor maps them for the active keyboard layout. */
int32_t jsti_remote_desktop_paste(const char *text, int32_t shift, char *error, size_t error_capacity);
void jsti_remote_desktop_stop(void);

/* Background: asks the desktop to start the app at login with `commandline`
 * (autostart 1) or no longer (0), inside Flatpak, where the sandbox cannot
 * write the autostart entry itself. The desktop may ask the user first; this
 * waits up to five minutes for the answer. `reached`: 0 off, 1 on, 2 refused
 * by the user or the desktop, which keeps refusing until its settings allow it. */
int32_t jsti_background_request(
    int32_t autostart, const char *reason, const char *const *commandline, int32_t *reached, char *error,
    size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
