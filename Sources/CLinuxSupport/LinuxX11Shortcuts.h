#ifndef JSTI_LINUX_X11_SHORTCUTS_H
#define JSTI_LINUX_X11_SHORTCUTS_H

#include "LinuxSupportInternal.h"
#include <X11/Xlib.h>

typedef struct HotKeyMasks {
    unsigned int ignored, values[256];
    guint count;
} HotKeyMasks;

typedef struct JSTIX11Grab {
    KeyCode code;
    unsigned int modifiers;
    HotKeyMasks masks;
} JSTIX11Grab;

gboolean jsti_x11_prepare_grab(
    Display *display, uint32_t keysym, uint32_t modifiers, JSTIX11Grab *grab, char *error, size_t capacity);
gboolean jsti_x11_register_grab(Display *display, const JSTIX11Grab *grab, char *error, size_t capacity);
void jsti_x11_release_grab(Display *display, const JSTIX11Grab *grab);
gboolean jsti_x11_grabs_overlap(const JSTIX11Grab *left, const JSTIX11Grab *right);
gboolean jsti_x11_grab_matches(const JSTIX11Grab *grab, unsigned int code, unsigned int modifiers);

#endif
