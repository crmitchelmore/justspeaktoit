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

typedef struct HotKeyThread {
    GThread *thread;
    int wake[2];
    uint32_t keysym;
    uint32_t modifiers;
    jsti_hotkey_fn callback;
    void *context;
    Display *display;
    KeyCode code;
} HotKeyThread;

static GMutex hotkey_lock;
static HotKeyThread *hotkey;

/* NumLock, CapsLock and ScrollLock must not defeat the grab. */
static const unsigned int lock_masks[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask, Mod5Mask,
                                           Mod5Mask | LockMask, Mod5Mask | Mod2Mask,
                                           Mod5Mask | LockMask | Mod2Mask };

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
            if (event.type == KeyPress && event.xkey.keycode == state->code && !pressed) {
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
    for (size_t index = 0; index < G_N_ELEMENTS(lock_masks); index++) {
        XUngrabKey(display, state->code, state->modifiers | lock_masks[index], root);
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
    Window root = DefaultRootWindow(display);
    grab_failed = 0;
    XErrorHandler previous = XSetErrorHandler(record_grab_error);
    for (size_t index = 0; index < G_N_ELEMENTS(lock_masks); index++) {
        XGrabKey(display, code, modifiers | lock_masks[index], root, False, GrabModeAsync, GrabModeAsync);
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
