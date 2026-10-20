#include "LinuxSupportInternal.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>

/*
 * X11 sessions only. Wayland clients cannot observe or inject into other
 * clients; there the portal paths in LinuxPortal.c apply. Each call opens its
 * own display connection, so nothing here shares Xlib state with GTK.
 */

static int ignore_errors(Display *display, XErrorEvent *event) {
    (void)display;
    (void)event;
    return 0;
}

int32_t jsti_x11_available(void) {
    const char *name = g_getenv("DISPLAY");
    if (name == NULL || name[0] == '\0') return 0;
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) return 0;
    int event_base, error_base, major, minor;
    int available = XTestQueryExtension(display, &event_base, &error_base, &major, &minor);
    XCloseDisplay(display);
    return available ? 1 : 0;
}

static Window active_window(Display *display) {
    Atom property = XInternAtom(display, "_NET_ACTIVE_WINDOW", True);
    if (property == None) return None;
    Atom type;
    int format;
    unsigned long count, remaining;
    unsigned char *data = NULL;
    Window window = None;
    if (XGetWindowProperty(display, DefaultRootWindow(display), property, 0, 1, False, XA_WINDOW, &type, &format,
                           &count, &remaining, &data) == Success && data != NULL) {
        if (type == XA_WINDOW && format == 32 && count == 1) window = *(Window *)data;
        XFree(data);
    }
    return window;
}

int32_t jsti_x11_active_window(
    uint64_t *window, char *wm_class, size_t wm_class_capacity, int32_t *pid, char *error, size_t capacity) {
    *window = 0;
    *pid = 0;
    if (wm_class != NULL && wm_class_capacity > 0) wm_class[0] = '\0';
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        jsti_set_error(error, capacity, "The X server is unavailable.");
        return -1;
    }
    XErrorHandler previous = XSetErrorHandler(ignore_errors);
    Window active = active_window(display);
    if (active == None) {
        XSetErrorHandler(previous);
        XCloseDisplay(display);
        return 1;
    }
    *window = active;
    XClassHint hint = { 0 };
    if (XGetClassHint(display, active, &hint)) {
        if (wm_class != NULL && hint.res_class != NULL) g_strlcpy(wm_class, hint.res_class, wm_class_capacity);
        if (hint.res_name != NULL) XFree(hint.res_name);
        if (hint.res_class != NULL) XFree(hint.res_class);
    }
    Atom pid_atom = XInternAtom(display, "_NET_WM_PID", True);
    if (pid_atom != None) {
        Atom type;
        int format;
        unsigned long count, remaining;
        unsigned char *data = NULL;
        if (XGetWindowProperty(display, active, pid_atom, 0, 1, False, XA_CARDINAL, &type, &format, &count,
                               &remaining, &data) == Success && data != NULL) {
            if (format == 32 && count == 1) *pid = (int32_t)*(unsigned long *)data;
            XFree(data);
        }
    }
    XSync(display, False);
    XSetErrorHandler(previous);
    XCloseDisplay(display);
    return 0;
}

static gboolean send_key(Display *display, KeySym symbol, Bool press) {
    KeyCode code = XKeysymToKeycode(display, symbol);
    if (code == 0) return FALSE;
    return XTestFakeKeyEvent(display, code, press, CurrentTime) != 0;
}

int32_t jsti_x11_paste(uint64_t window, int32_t shift, char *error, size_t capacity) {
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        jsti_set_error(error, capacity, "The X server is unavailable.");
        return -1;
    }
    int event_base, error_base, major, minor;
    if (!XTestQueryExtension(display, &event_base, &error_base, &major, &minor)) {
        XCloseDisplay(display);
        jsti_set_error(error, capacity, "The X server does not offer the XTest extension.");
        return -1;
    }
    XErrorHandler previous = XSetErrorHandler(ignore_errors);
    /* Re-verify focus immediately before delivery: text never goes to a
     * window the user switched to after pressing the shortcut. */
    if (window == 0 || active_window(display) != (Window)window) {
        XSetErrorHandler(previous);
        XCloseDisplay(display);
        jsti_set_error(error, capacity, "The focused window changed.");
        return 2;
    }
    /* Release modifiers the user may still hold from the shortcut. */
    KeySym held[] = { XK_Alt_L, XK_Alt_R, XK_Super_L, XK_Super_R, XK_Shift_R, XK_Control_R };
    for (size_t index = 0; index < G_N_ELEMENTS(held); index++) send_key(display, held[index], False);
    gboolean sent = send_key(display, XK_Control_L, True);
    if (shift) sent = sent && send_key(display, XK_Shift_L, True);
    sent = sent && send_key(display, XK_v, True) && send_key(display, XK_v, False);
    if (shift) send_key(display, XK_Shift_L, False);
    send_key(display, XK_Control_L, False);
    XSync(display, False);
    XSetErrorHandler(previous);
    XCloseDisplay(display);
    if (!sent) {
        jsti_set_error(error, capacity, "The paste keystroke could not be sent.");
        return -1;
    }
    return 0;
}

/* --------------------------------------------------------------- hotkey */

typedef struct HotKeyMasks {
    unsigned int ignored, values[256];
    guint count;
} HotKeyMasks;

enum { MODIFIER_LOCK = 1, MODIFIER_OTHER = 2 };

static guint8 modifier_key_traits(const KeySym *symbols, gint count) {
    guint8 traits = 0;
    for (gint index = 0; index < count; ++index) {
        if (symbols[index] == NoSymbol) continue;
        gboolean lock = symbols[index] == XK_Caps_Lock || symbols[index] == XK_Shift_Lock ||
            symbols[index] == XK_Num_Lock || symbols[index] == XK_Scroll_Lock;
        traits |= lock ? MODIFIER_LOCK : MODIFIER_OTHER;
    }
    return traits != 0 ? traits : MODIFIER_OTHER;
}

static unsigned int modifier_lock_bits(const XModifierKeymap *map, const guint8 traits[256]) {
    unsigned int ignored = 0;
    for (gint modifier = 0; modifier < 8; ++modifier) {
        guint8 combined = 0;
        for (gint key = 0; key < map->max_keypermod; ++key) {
            KeyCode code = map->modifiermap[modifier * map->max_keypermod + key];
            if (code != 0) combined |= traits[code];
        }
        /* A slot shared with AltGr, a group switch or any ordinary key is not
         * a lock-only slot, even if one of its keys is NumLock/ScrollLock. */
        if (combined == MODIFIER_LOCK) ignored |= 1u << modifier;
    }
    return ignored;
}

static HotKeyMasks hotkey_masks(unsigned int lock_bits, unsigned int required) {
    HotKeyMasks masks = { .ignored = lock_bits & ~required, .count = 1 };
    for (guint bit = 0; bit < 8; ++bit) {
        unsigned int modifier = 1u << bit;
        if (!(masks.ignored & modifier)) continue;
        guint count = masks.count;
        for (guint index = 0; index < count; ++index)
            masks.values[masks.count++] = masks.values[index] | modifier;
    }
    return masks;
}

static gboolean read_hotkey_masks(
    Display *display, unsigned int required, HotKeyMasks *result, char *error, size_t capacity
) {
    XModifierKeymap *map = XGetModifierMapping(display);
    gint minimum, maximum, symbols_per_key = 0;
    XDisplayKeycodes(display, &minimum, &maximum);
    KeySym *symbols = minimum > 0 && maximum >= minimum && maximum < 256
        ? XGetKeyboardMapping(display, (KeyCode)minimum, maximum - minimum + 1, &symbols_per_key) : NULL;
    if (map == NULL || map->max_keypermod < 0 || map->max_keypermod > 256 ||
        (map->max_keypermod > 0 && map->modifiermap == NULL) ||
        symbols == NULL || symbols_per_key <= 0) {
        if (map != NULL) XFreeModifiermap(map);
        if (symbols != NULL) XFree(symbols);
        jsti_set_error(error, capacity, "The keyboard modifier map could not be read safely.");
        return FALSE;
    }
    guint8 traits[256];
    memset(traits, MODIFIER_OTHER, sizeof(traits));
    for (gint code = minimum; code <= maximum; ++code)
        traits[code] = modifier_key_traits(symbols + (code - minimum) * symbols_per_key, symbols_per_key);
    *result = hotkey_masks(modifier_lock_bits(map, traits), required);
    XFree(symbols);
    XFreeModifiermap(map);
    return TRUE;
}

static gboolean hotkey_modifiers_match(unsigned int state, unsigned int required, unsigned int ignored) {
    return (state & 0xffu & ~ignored) == required;
}

typedef struct HotKeyThread {
    GThread *thread;
    int wake[2];
    uint32_t keysym;
    uint32_t modifiers;
    jsti_hotkey_fn callback;
    void *context;
    Display *display;
    KeyCode code;
    HotKeyMasks masks;
} HotKeyThread;

static GMutex hotkey_lock;
static HotKeyThread *hotkey;

static gpointer hotkey_run(gpointer data) {
    HotKeyThread *state = data;
    Display *display = state->display;
    Window root = DefaultRootWindow(display);
    Bool supported = False;
    XkbSetDetectableAutoRepeat(display, True, &supported);
    gboolean pressed = FALSE;
    struct pollfd descriptors[2] = { { ConnectionNumber(display), POLLIN, 0 }, { state->wake[0], POLLIN, 0 } };
    for (;;) {
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == KeyPress && event.xkey.keycode == state->code && !pressed &&
                hotkey_modifiers_match(event.xkey.state, state->modifiers, state->masks.ignored)) {
                pressed = TRUE;
                state->callback(1, state->context);
            } else if (event.type == KeyRelease && event.xkey.keycode == state->code && pressed) {
                pressed = FALSE;
                state->callback(0, state->context);
            }
        }
        if (poll(descriptors, 2, -1) < 0) continue;
        if (descriptors[1].revents & POLLIN) break;
    }
    for (guint index = 0; index < state->masks.count; index++) {
        XUngrabKey(display, state->code, state->modifiers | state->masks.values[index], root);
    }
    XSync(display, False);
    return NULL;
}

static int grab_failed;
static int record_grab_error(Display *display, XErrorEvent *event) {
    (void)display;
    if (event->error_code == BadAccess) grab_failed = 1;
    return 0;
}

int32_t jsti_x11_hotkey_start(
    uint32_t keysym, uint32_t modifiers, jsti_hotkey_fn callback, void *context, char *error, size_t capacity) {
    if (keysym == NoSymbol || (modifiers & ~0xffu) != 0 || callback == NULL) {
        jsti_set_error(error, capacity, "The shortcut key, callback or modifier bits are invalid.");
        return -1;
    }
    jsti_x11_hotkey_stop();
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        jsti_set_error(error, capacity, "The X server is unavailable.");
        return -1;
    }
    KeyCode code = XKeysymToKeycode(display, keysym);
    if (code == 0) {
        XCloseDisplay(display);
        jsti_set_error(error, capacity, "The shortcut key is not on this keyboard layout.");
        return -1;
    }
    HotKeyMasks masks;
    if (!read_hotkey_masks(display, modifiers, &masks, error, capacity)) {
        XCloseDisplay(display);
        return -1;
    }
    Window root = DefaultRootWindow(display);
    grab_failed = 0;
    XErrorHandler previous = XSetErrorHandler(record_grab_error);
    for (guint index = 0; index < masks.count; index++) {
        XGrabKey(display, code, modifiers | masks.values[index], root, False, GrabModeAsync, GrabModeAsync);
    }
    XSync(display, False);
    XSetErrorHandler(previous);
    if (grab_failed) {
        XCloseDisplay(display);
        jsti_set_error(error, capacity, "Another application already uses this shortcut.");
        return -1;
    }
    XSelectInput(display, root, KeyPressMask | KeyReleaseMask);
    HotKeyThread *state = g_new0(HotKeyThread, 1);
    if (pipe(state->wake) != 0) {
        XCloseDisplay(display);
        g_free(state);
        jsti_set_error(error, capacity, "Could not start the shortcut listener.");
        return -1;
    }
    state->keysym = keysym;
    state->modifiers = modifiers;
    state->callback = callback;
    state->context = context;
    state->display = display;
    state->code = code;
    state->masks = masks;
    g_mutex_lock(&hotkey_lock);
    hotkey = state;
    state->thread = g_thread_new("jsti-x11-hotkey", hotkey_run, state);
    g_mutex_unlock(&hotkey_lock);
    return 0;
}

void jsti_x11_hotkey_stop(void) {
    g_mutex_lock(&hotkey_lock);
    HotKeyThread *state = hotkey;
    hotkey = NULL;
    g_mutex_unlock(&hotkey_lock);
    if (state == NULL) return;
    char byte = 1;
    if (write(state->wake[1], &byte, 1) < 0) { /* the thread still exits on close */ }
    g_thread_join(state->thread);
    XCloseDisplay(state->display);
    close(state->wake[0]);
    close(state->wake[1]);
    g_free(state);
}

int32_t jsti_x11_modifier_self_test(char *error, size_t capacity) {
    guint8 traits[256];
    memset(traits, MODIFIER_OTHER, sizeof(traits));
    traits[10] = traits[11] = traits[13] = MODIFIER_LOCK;
    KeyCode keys[16] = { 0 };
    keys[2] = 10;  /* Lock: CapsLock. */
    keys[8] = 11;  /* Mod2: NumLock. */
    keys[10] = 13; /* Mod3: ScrollLock, not the historical Mod5 guess. */
    keys[14] = 12; /* Mod5: AltGr. */
    XModifierKeymap map = { .max_keypermod = 2, .modifiermap = keys };
    unsigned int locks = LockMask | Mod2Mask | Mod3Mask;
    gboolean okay = modifier_lock_bits(&map, traits) == locks;
    HotKeyMasks masks = hotkey_masks(locks, ControlMask | Mod1Mask);
    okay = okay && masks.count == 8 && masks.ignored == locks;
    unsigned int seen = 0;
    for (guint index = 0; index < masks.count; ++index) {
        unsigned int compact = ((masks.values[index] & LockMask) ? 1u : 0u) |
            ((masks.values[index] & Mod2Mask) ? 2u : 0u) | ((masks.values[index] & Mod3Mask) ? 4u : 0u);
        okay = okay && !(masks.values[index] & ~locks) && !(seen & (1u << compact));
        seen |= 1u << compact;
        okay = okay && hotkey_modifiers_match(
            ControlMask | Mod1Mask | masks.values[index] | Button1Mask, ControlMask | Mod1Mask, masks.ignored);
    }
    okay = okay && seen == 0xffu && !hotkey_modifiers_match(
        ControlMask | Mod1Mask | Mod5Mask, ControlMask | Mod1Mask, masks.ignored);
    okay = okay && !hotkey_modifiers_match(
        ControlMask | Mod1Mask | ShiftMask, ControlMask | Mod1Mask, masks.ignored);
    masks = hotkey_masks(locks, ControlMask | Mod2Mask);
    okay = okay && masks.count == 4 && !(masks.ignored & Mod2Mask) &&
        !hotkey_modifiers_match(ControlMask, ControlMask | Mod2Mask, masks.ignored);
    keys[9] = 12;
    okay = okay && modifier_lock_bits(&map, traits) == (LockMask | Mod3Mask);
    keys[9] = 0;
    traits[11] = MODIFIER_LOCK | MODIFIER_OTHER;
    okay = okay && modifier_lock_bits(&map, traits) == (LockMask | Mod3Mask);
    const KeySym lock[] = { XK_Num_Lock, NoSymbol, XK_Num_Lock };
    const KeySym mixed[] = { XK_Scroll_Lock, XK_ISO_Level3_Shift };
    const KeySym unknown[] = { NoSymbol };
    okay = okay && modifier_key_traits(lock, G_N_ELEMENTS(lock)) == MODIFIER_LOCK &&
        modifier_key_traits(mixed, G_N_ELEMENTS(mixed)) == (MODIFIER_LOCK | MODIFIER_OTHER) &&
        modifier_key_traits(unknown, G_N_ELEMENTS(unknown)) == MODIFIER_OTHER;
    masks = hotkey_masks(0, ControlMask);
    okay = okay && masks.count == 1 && masks.values[0] == 0 && masks.ignored == 0;
    masks = hotkey_masks(0xffu, 0);
    okay = okay && masks.count == 256;
    for (guint index = 0; index < masks.count; ++index)
        okay = okay && masks.values[index] == index;
    if (!okay) {
        jsti_set_error(error, capacity, "X11 lock-only modifier discovery, expansion or matching failed.");
        return -1;
    }
    return 0;
}
