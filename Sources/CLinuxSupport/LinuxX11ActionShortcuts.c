#include "LinuxX11Shortcuts.h"
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <errno.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>

enum { MAX_ACTION_SHORTCUTS = 64 };

typedef struct ActionSlot {
    JSTIX11Grab grab;
    int32_t identifier;
    gboolean registered;
    char error[256];
} ActionSlot;

struct JSTIX11ActionShortcuts {
    Display *display;
    GThread *thread;
    int wake[2], closing, lost;
    size_t count;
    ActionSlot slots[MAX_ACTION_SHORTCUTS];
    gboolean held[256];
    Time released_at[256];
    jsti_action_shortcut_fn callback;
    void *context;
};

static gboolean safe_combination(const JSTIX11ActionShortcut *row) {
    return row->keysym != NoSymbol && !(row->modifiers & ~(ShiftMask | ControlMask | Mod1Mask)) &&
        ((row->modifiers & (ControlMask | Mod1Mask)) || (row->keysym >= XK_F13 && row->keysym <= XK_F24));
}

static void action_event(JSTIX11ActionShortcuts *state, const XKeyEvent *event) {
    if (event->send_event || event->keycode >= G_N_ELEMENTS(state->held) ||
        g_atomic_int_get(&state->closing)) return;
    gboolean known = FALSE;
    for (size_t index = 0; index < state->count; ++index)
        known |= state->slots[index].registered && state->slots[index].grab.code == event->keycode;
    if (!known) return;
    if (event->type == KeyRelease) {
        state->held[event->keycode] = FALSE;
        state->released_at[event->keycode] = event->time;
        return;
    }
    if (event->type != KeyPress || state->held[event->keycode]) return;
    if (event->time != 0 && state->released_at[event->keycode] == event->time) {
        state->held[event->keycode] = TRUE;
        return;
    }
    state->held[event->keycode] = TRUE;
    for (size_t index = 0; index < state->count; ++index) {
        ActionSlot *slot = &state->slots[index];
        if (slot->registered && jsti_x11_grab_matches(&slot->grab, event->keycode, event->state)) {
            state->callback(slot->identifier, state->context);
            return;
        }
    }
}

static gpointer action_run(gpointer data) {
    JSTIX11ActionShortcuts *state = data;
    Bool detectable = False;
    XkbSetDetectableAutoRepeat(state->display, True, &detectable);
    struct pollfd descriptors[2] = {
        { ConnectionNumber(state->display), POLLIN, 0 }, { state->wake[0], POLLIN, 0 }
    };
    gboolean failed = FALSE;
    while (!g_atomic_int_get(&state->closing)) {
        while (!g_atomic_int_get(&state->closing) && XPending(state->display) > 0) {
            XEvent event;
            XNextEvent(state->display, &event);
            if (event.type == KeyPress || event.type == KeyRelease) action_event(state, &event.xkey);
        }
        if (g_atomic_int_get(&state->closing)) break;
        const int result = poll(descriptors, 2, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { failed = TRUE; break; }
        if (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
            failed = !g_atomic_int_get(&state->closing);
            break;
        }
        if (descriptors[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
            failed = TRUE;
            break;
        }
    }
    if (failed && !g_atomic_int_get(&state->closing)) {
        g_atomic_int_set(&state->lost, 1);
        state->callback(-1, state->context);
    }
    return NULL;
}

static void register_slot(JSTIX11ActionShortcuts *state, const JSTIX11ActionShortcut *row, size_t index) {
    ActionSlot *slot = &state->slots[index];
    slot->identifier = row->identifier;
    if (!safe_combination(row)) {
        g_strlcpy(slot->error, "Add Ctrl or Alt, or use F13-F24, for an all-app shortcut.", sizeof slot->error);
        return;
    }
    if (!jsti_x11_prepare_grab(
        state->display, row->keysym, row->modifiers, &slot->grab, slot->error, sizeof slot->error)) return;
    for (size_t prior = 0; prior < index; ++prior) {
        if (state->slots[prior].registered && jsti_x11_grabs_overlap(&state->slots[prior].grab, &slot->grab)) {
            g_strlcpy(slot->error, "An earlier action uses this physical shortcut.", sizeof slot->error);
            return;
        }
    }
    slot->registered = jsti_x11_register_grab(state->display, &slot->grab, slot->error, sizeof slot->error);
}

JSTIX11ActionShortcuts *jsti_x11_action_shortcuts_start(
    const JSTIX11ActionShortcut *rows, size_t count, jsti_action_shortcut_fn callback, void *context,
    char *error, size_t capacity
) {
    if (rows == NULL || count == 0 || count > MAX_ACTION_SHORTCUTS || callback == NULL) {
        jsti_set_error(error, capacity, "The action shortcut group is invalid.");
        return NULL;
    }
    for (size_t index = 0; index < count; ++index) {
        if (rows[index].identifier < 0 || rows[index].identifier >= MAX_ACTION_SHORTCUTS) {
            jsti_set_error(error, capacity, "An action shortcut identifier is invalid.");
            return NULL;
        }
        for (size_t prior = 0; prior < index; ++prior) {
            if (rows[index].identifier == rows[prior].identifier) {
                jsti_set_error(error, capacity, "Action shortcut identifiers must be unique.");
                return NULL;
            }
        }
    }
    JSTIX11ActionShortcuts *state = g_new0(JSTIX11ActionShortcuts, 1);
    state->wake[0] = state->wake[1] = -1;
    state->display = XOpenDisplay(NULL);
    if (state->display == NULL) {
        jsti_set_error(error, capacity, "The X server is unavailable.");
        g_free(state);
        return NULL;
    }
    state->count = count; state->callback = callback; state->context = context;
    gboolean any = FALSE;
    for (size_t index = 0; index < count; ++index) {
        register_slot(state, &rows[index], index);
        any |= state->slots[index].registered;
    }
    if (!any) { XCloseDisplay(state->display); state->display = NULL; return state; }
    GError *failure = NULL;
    if (!g_unix_open_pipe(state->wake, FD_CLOEXEC, &failure)) {
        jsti_set_error(error, capacity, "Could not create the action shortcut listener: %s", failure->message);
        g_clear_error(&failure);
        jsti_x11_action_shortcuts_stop(state);
        return NULL;
    }
    XSelectInput(state->display, DefaultRootWindow(state->display), KeyPressMask | KeyReleaseMask);
    XFlush(state->display);
    state->thread = g_thread_try_new("jsti-x11-actions", action_run, state, &failure);
    if (state->thread == NULL) {
        jsti_set_error(error, capacity, "Could not start the action shortcut listener: %s", failure->message);
        g_clear_error(&failure);
        jsti_x11_action_shortcuts_stop(state);
        return NULL;
    }
    return state;
}

int32_t jsti_x11_action_shortcuts_result(
    JSTIX11ActionShortcuts *state, size_t row, char *error, size_t capacity
) {
    if (state == NULL || row >= state->count) {
        jsti_set_error(error, capacity, "The action shortcut result index is invalid.");
        return -1;
    }
    if (g_atomic_int_get(&state->lost)) {
        jsti_set_error(error, capacity, "The X11 action shortcut listener stopped.");
        return -1;
    }
    if (!state->slots[row].registered) {
        jsti_set_error(error, capacity, "%s", state->slots[row].error);
        return -1;
    }
    return 0;
}

void jsti_x11_action_shortcuts_stop(JSTIX11ActionShortcuts *state) {
    if (state == NULL) return;
    g_atomic_int_set(&state->closing, 1);
    if (state->thread != NULL) {
        const char byte = 1;
        ssize_t result;
        do { result = write(state->wake[1], &byte, 1); } while (result < 0 && errno == EINTR);
        if (result < 0) { close(state->wake[1]); state->wake[1] = -1; }
        g_thread_join(state->thread);
    }
    if (state->display != NULL) XCloseDisplay(state->display);
    for (size_t index = 0; index < G_N_ELEMENTS(state->wake); ++index)
        if (state->wake[index] >= 0) close(state->wake[index]);
    g_free(state);
}

typedef struct ActionFixture { int count, identifier; } ActionFixture;
static void fixture_action(int32_t identifier, void *context) {
    ActionFixture *fixture = context;
    fixture->identifier = identifier;
    ++fixture->count;
}

int32_t jsti_x11_action_shortcuts_self_test(char *error, size_t capacity) {
    ActionFixture fixture = { 0 };
    JSTIX11ActionShortcuts state = { .count = 3, .callback = fixture_action, .context = &fixture };
    state.slots[0] = (ActionSlot){ .identifier = 7, .registered = TRUE, .grab = {
        .code = 38, .modifiers = ControlMask, .masks = { .ignored = LockMask | Mod2Mask,
            .values = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask }, .count = 4 } } };
    state.slots[1] = (ActionSlot){ .identifier = 11, .registered = TRUE, .grab = {
        .code = 38, .modifiers = ControlMask | ShiftMask, .masks = { .values = { 0 }, .count = 1 } } };
    state.slots[2] = state.slots[0]; state.slots[2].registered = FALSE;
    gboolean okay = !jsti_x11_grabs_overlap(&state.slots[0].grab, &state.slots[1].grab) &&
        jsti_x11_grabs_overlap(&state.slots[0].grab, &state.slots[2].grab);
    XKeyEvent event = { .type = KeyPress, .keycode = 38, .state = ControlMask | Mod5Mask };
    action_event(&state, &event);
    event.state = ControlMask;
    action_event(&state, &event);
    okay = okay && fixture.count == 0;
    event.type = KeyRelease;
    action_event(&state, &event);
    for (unsigned int locks = 0; locks < 4; ++locks) {
        event.state = ControlMask | ((locks & 1u) ? LockMask : 0) | ((locks & 2u) ? Mod2Mask : 0);
        event.type = KeyPress;
        action_event(&state, &event);
        action_event(&state, &event);
        okay = okay && fixture.count == (int)locks + 1 && fixture.identifier == 7;
        event.state = ControlMask | ShiftMask;
        action_event(&state, &event);
        okay = okay && fixture.count == (int)locks + 1;
        event.type = KeyRelease;
        action_event(&state, &event);
    }
    event.type = KeyPress; event.state = ControlMask | ShiftMask;
    action_event(&state, &event);
    okay = okay && fixture.count == 5 && fixture.identifier == 11;
    event.type = KeyRelease; event.time = 99; action_event(&state, &event);
    event.type = KeyPress; action_event(&state, &event);
    okay = okay && fixture.count == 5;
    event.type = KeyRelease; event.time = 100; action_event(&state, &event);
    event.type = KeyPress; event.time = 101; action_event(&state, &event);
    okay = okay && fixture.count == 6;
    g_atomic_int_set(&state.closing, 1);
    event.type = KeyRelease; action_event(&state, &event);
    event.type = KeyPress; action_event(&state, &event);
    okay = okay && fixture.count == 6;
    const JSTIX11ActionShortcut safe = { .keysym = XK_t, .modifiers = ControlMask };
    const JSTIX11ActionShortcut unsafe = { .keysym = XK_space, .modifiers = ShiftMask };
    const JSTIX11ActionShortcut function = { .keysym = XK_F13 };
    okay = okay && safe_combination(&safe) && !safe_combination(&unsafe) && safe_combination(&function);
    if (!okay) {
        jsti_set_error(error, capacity, "X11 action shortcut lock, repeat, overlap or shutdown checks failed.");
        return -1;
    }
    return 0;
}
