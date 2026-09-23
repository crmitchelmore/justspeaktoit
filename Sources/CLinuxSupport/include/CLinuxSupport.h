#ifndef JSTI_LINUX_SUPPORT_H
#define JSTI_LINUX_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The narrow C ABI between the Swift Linux host and GTK 4/libadwaita, libpulse,
 * libsecret, X11/XTest and the XDG desktop portals. It mirrors the Windows
 * adapter: every fallible call returns 0 on success and writes a user-facing
 * UTF-8 message into `error` otherwise. Strings passed in are copied before the
 * call returns. Callbacks never run after the matching stop/destroy returns.
 */

/* ------------------------------------------------------------------ window */

/* Events the window reports on the GTK main thread. Values match Windows. */
enum {
    JSTI_EVENT_TOGGLE_RECORDING = 1, /* text: microphone id, index: model slot */
    JSTI_EVENT_IMPORT = 2,           /* text: path, index: model slot */
    JSTI_EVENT_COPY = 3,
    JSTI_EVENT_SAVE_KEY = 4,         /* text: key, index: model slot */
    JSTI_EVENT_SELECT_MODEL = 5,     /* index: model slot */
    JSTI_EVENT_CLOSING = 6,
    JSTI_EVENT_READY = 7,
    JSTI_EVENT_SELECT_HISTORY = 9,   /* text: record id */
    JSTI_EVENT_RETRY_HISTORY = 10,   /* text: record id */
    JSTI_EVENT_EXPORT_HISTORY = 11,  /* text: destination path */
    JSTI_EVENT_OPEN_AUDIO = 12,      /* text: record id */
    JSTI_EVENT_SELECT_MICROPHONE = 13,
    JSTI_EVENT_CANCEL = 14,
    JSTI_EVENT_SEARCH_HISTORY = 15,  /* text: query */
    JSTI_EVENT_TRANSCRIPT_VERSION = 16, /* text: record id */
    JSTI_EVENT_PLAYBACK_TOGGLE = 18, /* text: record id */
    JSTI_EVENT_PLAYBACK_STOP = 19,
    JSTI_EVENT_REFRESH_MODELS = 20,
    JSTI_EVENT_SHORTCUT_PRESSED = 21,  /* text: microphone id, index: model slot */
    JSTI_EVENT_SHORTCUT_RELEASED = 22,
    JSTI_EVENT_TEXT_OUTPUT = 30,       /* index: method, text: "restore" or "" */
    JSTI_EVENT_COMMAND_TOGGLE = 31,    /* --toggle from another process or action */
    JSTI_EVENT_SHORTCUT_STYLE = 32     /* index: 0 press, 1 hold, 2 double-tap, 3 hold and double-tap */
};

/* Recording state for jsti_window_update: -1 keeps the current state. */
enum { JSTI_STATE_IDLE = 0, JSTI_STATE_RECORDING = 1, JSTI_STATE_WORKING = 2 };

typedef void (*jsti_window_event_fn)(int32_t event, const char *text, int32_t index, void *context);

typedef struct JSTIModelRow {
    const char *id;
    const char *name;
    int32_t is_live;
    /* Position in the picker, or -1 when hidden. */
    int32_t display_order;
} JSTIModelRow;

typedef struct JSTIHistoryRow {
    const char *id;
    const char *title;
    const char *detail;
} JSTIHistoryRow;

enum { JSTI_WINDOW_SMOKE_TEST = 1 };

/* Runs the GTK application on the calling (main) thread until the window
 * closes. `app_id` is the reverse-DNS application ID. A second instance
 * started with --toggle forwards JSTI_EVENT_COMMAND_TOGGLE to this one. */
int32_t jsti_window_run(
    const char *app_id, int argc, char **argv, const JSTIModelRow *models, size_t model_count,
    int32_t selected_model, jsti_window_event_fn callback, void *context, int32_t flags,
    char *error, size_t error_capacity);

/* Safe from any thread; applied on the GTK main thread. No-ops before the
 * window exists or after it closes. `status` or `transcript` may be NULL. */
int32_t jsti_window_update(const char *status, const char *transcript, int32_t state);
int32_t jsti_window_set_model_catalog(
    const JSTIModelRow *rows, size_t count, int32_t selected, const char *status, int32_t refreshing);
int32_t jsti_window_set_microphones(
    const char *const *ids, const char *const *names, size_t count, const char *selected);
int32_t jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id);
/* variant: 0 processed, 1 original, -1 none. */
int32_t jsti_window_set_history_presentation(
    const char *record_id, int32_t variant, int32_t switchable, const char *text, const char *status);
int32_t jsti_window_set_transcript_variant(const char *record_id, int32_t variant, int32_t switchable);
/* method: 0 paste into the focused app, 1 clipboard only. */
int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard, const char *shortcut_hint);
/* The shortcut behaviour picker, indexed as JSTI_EVENT_SHORTCUT_STYLE. */
int32_t jsti_window_set_shortcut_style(int32_t index);
/* Main thread only: the transcript and version the window displays now. */
int32_t jsti_window_transcript_snapshot(char *buffer, size_t capacity, size_t *required);
int32_t jsti_window_transcript_variant(void);
void jsti_window_request_close(void);
/* 1 while this app's window has keyboard focus. Safe from any thread. */
int32_t jsti_window_is_active(void);
/* Desktop notification through GNotification (portal-backed in Flatpak). */
void jsti_notify(const char *title, const char *body);
/* Main thread only: exercises widget construction and event plumbing. */
int32_t jsti_window_self_test(char *error, size_t error_capacity);
/* Main thread only: renders the window to a PNG for visual review. */
int32_t jsti_window_save_snapshot(const char *path, char *error, size_t error_capacity);

/* --------------------------------------------------------------- clipboard */

/* The GTK clipboard of this app's display. Safe from any thread: the work runs
 * on the GTK main thread and the caller waits (bounded). Wayland compositors
 * only accept a selection from the focused client; see jsti_portal_*. */
int32_t jsti_clipboard_write(const char *text, char *error, size_t error_capacity);
/* Returns 1 when the clipboard holds no text. `*text` is malloc'ed. */
int32_t jsti_clipboard_read(char **text, char *error, size_t error_capacity);
void jsti_free(void *pointer);

/* ------------------------------------------------------------- credentials */

/* libsecret Secret Service (GNOME Keyring, KWallet, or the Secret portal in
 * Flatpak). Returns 1 when no secret is stored. */
int32_t jsti_credential_read(
    const char *name, uint8_t *buffer, size_t capacity, size_t *count, char *error, size_t error_capacity);
int32_t jsti_credential_write(
    const char *name, const uint8_t *bytes, size_t count, char *error, size_t error_capacity);
int32_t jsti_credential_delete(const char *name, char *error, size_t error_capacity);

/* ----------------------------------------------------------------- capture */

typedef struct jsti_capture jsti_capture;
typedef void (*jsti_capture_audio_fn)(const int16_t *samples, size_t count, void *context);
typedef void (*jsti_capture_error_fn)(const char *message, void *context);

/* Mono PCM16 at `sample_rate` in frames of `frame_ms` from a PulseAudio source
 * (PipeWire's pulse server on current desktops). "" is the default source. */
jsti_capture *jsti_capture_create(
    const char *device, uint32_t sample_rate, uint32_t frame_ms, jsti_capture_audio_fn audio,
    jsti_capture_error_fn failure, void *context, char *error, size_t error_capacity);
int32_t jsti_capture_start(jsti_capture *capture, char *error, size_t error_capacity);
/* Drains buffered audio; no callback runs after it returns. */
int32_t jsti_capture_stop(jsti_capture *capture, char *error, size_t error_capacity);
void jsti_capture_destroy(jsti_capture *capture);

typedef void (*jsti_audio_device_fn)(const char *id, const char *name, int32_t is_default, void *context);
int32_t jsti_audio_devices_enumerate(jsti_audio_device_fn callback, void *context, char *error, size_t error_capacity);

/* Reports (on the audio thread) that microphones were added, removed or
 * changed, or that the default changed. Callers re-enumerate. */
typedef void (*jsti_audio_devices_changed_fn)(void *context);
int32_t jsti_audio_device_monitor_start(
    jsti_audio_devices_changed_fn callback, void *context, char *error, size_t error_capacity);
/* No callback runs after this returns. */
void jsti_audio_device_monitor_stop(void);

/* ------------------------------------------------------------------- files */

/* Creates a directory (and parents) readable only by the current user, or
 * tightens an existing one. Refuses symbolic links. */
int32_t jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
/* Creates a new empty file with mode 0600; refuses existing paths and links. */
int32_t jsti_private_file_create(const char *path, char *error, size_t error_capacity);
int32_t jsti_open_path(const char *path, char *error, size_t error_capacity);

/* --------------------------------------------------------------------- X11 */

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
/* Grabs `keysym` with `modifiers` (X11 masks) on the root window from a
 * dedicated thread and reports presses and releases. */
int32_t jsti_x11_hotkey_start(
    uint32_t keysym, uint32_t modifiers, jsti_hotkey_fn callback, void *context, char *error, size_t error_capacity);
void jsti_x11_hotkey_stop(void);

/* ------------------------------------------------------------------ portals */

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

/* --------------------------------------------------------------- self-test */

/* Deterministic checks of file security, UTF-8 handling and PCM framing that
 * need no display, microphone or keyring. */
int32_t jsti_native_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
