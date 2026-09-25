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
    JSTI_EVENT_SHORTCUT_STYLE = 32,    /* index: 0 press, 1 hold, 2 double-tap, 3 hold and double-tap */
    /* Apply in Post-processing. index: model index, or -1 - index when
     * disabled; text: prompt, U+001F, then a new OpenRouter key or nothing. */
    JSTI_EVENT_POST_PROCESSING = 33,
    /* Apply in Azure Speech resource. text: the endpoint as typed ("" clears). */
    JSTI_EVENT_AZURE_RESOURCE = 34
};

/* Read aloud. Linux-only numbers 40-44. */
enum {
    /* text: the selected record id; the displayed transcript is captured
     * with jsti_window_transcript_snapshot while this event runs. */
    JSTI_EVENT_READ_ALOUD = 40,
    JSTI_EVENT_VOICE_OUTPUT = 41 /* index: position in the voice list */
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
/* The Post-processing group: shared remote model names and saved choices. */
int32_t jsti_window_set_post_processing(
    const char *const *models, size_t count, int32_t enabled, int32_t selected, const char *prompt);
/* Shows the saved Azure Speech resource endpoint ("" for none). */
int32_t jsti_window_set_azure_resource(const char *endpoint);
/* The shortcut behaviour picker, indexed as JSTI_EVENT_SHORTCUT_STYLE. */
int32_t jsti_window_set_shortcut_style(int32_t index);
/* The Read aloud voices in picker order and the saved one. Read aloud is
 * offered once at least one voice is listed. */
int32_t jsti_window_set_voices(const char *const *names, size_t count, int32_t selected);
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

/* ------------------------------------------------------------- iCloud sync */

/* The window's iCloud sync group reports these on the GTK main thread. */
enum {
    /* Apply. index: bit 0 Sync History, bit 1 Import API keys; text: the
     * passphrase as typed ("" when none), cleared from its entry once sent. */
    JSTI_EVENT_CLOUD_SYNC_APPLY = 60,
    JSTI_EVENT_CLOUD_SYNC_SIGN_IN = 61,
    JSTI_EVENT_CLOUD_SYNC_SIGN_OUT = 62,
    JSTI_EVENT_CLOUD_SYNC_NOW = 63
};

typedef struct JSTICloudSyncView {
    const char *status;
    int32_t available;
    int32_t signed_in;
    int32_t history_enabled;
    int32_t key_import_enabled;
} JSTICloudSyncView;

/* Shows sync state in the iCloud sync group. Until the first call, and while
 * `available` is 0, none of its actions can be used. A switch follows the
 * state only when that value changed, so a refresh keeps unapplied choices.
 * Safe from any thread, like jsti_window_update. */
int32_t jsti_window_set_cloud_sync(const JSTICloudSyncView *view);

/* OpenSSL (libcrypto) primitives for the API-key sync envelope, the same ones
 * CNG provides on Windows: PBKDF2-HMAC-SHA256, and AES-256-GCM with a fresh
 * random 96-bit nonce, no associated data and a 128-bit tag kept apart from
 * the ciphertext. open returns 1 when the tag does not verify, and releases no
 * plaintext then. All return -1 on other failures. */
int32_t jsti_crypto_pbkdf2_sha256(
    const uint8_t *password, size_t password_count, const uint8_t *salt, size_t salt_count, uint64_t iterations,
    uint8_t *key, size_t key_count, char *error, size_t error_capacity);
int32_t jsti_crypto_aes_gcm_seal(
    const uint8_t *key, size_t key_count, const uint8_t *plaintext, size_t count, uint8_t *nonce12,
    uint8_t *ciphertext, uint8_t *tag16, char *error, size_t error_capacity);
int32_t jsti_crypto_aes_gcm_open(
    const uint8_t *key, size_t key_count, const uint8_t *nonce12, const uint8_t *ciphertext, size_t count,
    const uint8_t *tag16, uint8_t *plaintext, char *error, size_t error_capacity);
int32_t jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t error_capacity);

/* A 127.0.0.1-only HTTP/1.1 listener, for the Apple ID sign-in callback and
 * loopback fake servers in tests; port 0 picks a free port. It serves one
 * connection at a time. A connection that closes, or sends no complete request
 * (at most 1 MiB) within `request_window_ms` (0: five seconds), is dropped and
 * listening goes on. accept returns 0 with a connection, 1 once
 * `timeout_milliseconds` (-1: none) passes, 3 once cancelled and -1 on failure.
 * cancel is safe from any thread; destroy only after every accept returned. */
typedef struct jsti_loopback jsti_loopback;
typedef struct jsti_loopback_connection jsti_loopback_connection;
jsti_loopback *jsti_loopback_listen(
    uint16_t port, int32_t request_window_ms, uint16_t *bound_port, char *error, size_t error_capacity);
int32_t jsti_loopback_accept(
    jsti_loopback *listener, int32_t timeout_milliseconds, jsti_loopback_connection **connection, char *error,
    size_t error_capacity);
/* The complete request, valid until the connection is destroyed. */
const uint8_t *jsti_loopback_request(const jsti_loopback_connection *connection, size_t *count);
/* Who owns the socket at the other end, from /proc/net/tcp and tcp6: 0 a
 * process of this (effective) user, 1 another user's, -1 when that cannot be
 * determined. Only while the peer's socket is open. */
int32_t jsti_loopback_peer_owner(const jsti_loopback_connection *connection);
/* The same decision over given table texts (either may be NULL), for tests:
 * addresses as in sin_addr.s_addr, ports in host order. */
int32_t jsti_loopback_peer_owner_in_tables(
    const char *tcp, const char *tcp6, uint32_t peer_address, uint16_t peer_port, uint32_t local_address,
    uint16_t local_port, uint32_t user);
/* Writes a complete response and ends the connection's sending side. */
int32_t jsti_loopback_respond(jsti_loopback_connection *connection, const uint8_t *bytes, size_t count);
/* Closes the connection and wipes its request. */
void jsti_loopback_connection_destroy(jsti_loopback_connection *connection);
void jsti_loopback_cancel(jsti_loopback *listener);
void jsti_loopback_destroy(jsti_loopback *listener);

/* Opens an https page on apple.com or icloud.com (or a subdomain) in the
 * default browser, through the OpenURI portal inside Flatpak. Any other
 * address is refused. */
int32_t jsti_open_sign_in_page(const char *url, char *error, size_t error_capacity);

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

/* ------------------------------------------------------------------ decode */

/* Decodes any audio GStreamer's installed plugins understand to mono PCM16
 * at `sample_rate`, delivered in chunks on the calling thread. Stops early
 * (returning 1) once `*cancelled` becomes nonzero. */
int32_t jsti_audio_decode(
    const char *path, uint32_t sample_rate, jsti_capture_audio_fn chunk, void *context, const volatile int32_t *cancelled,
    char *error, size_t error_capacity);

/* ---------------------------------------------------------------- playback */

/* Plays mono PCM16 through the sound server. The samples are copied. */
typedef struct jsti_player jsti_player;
enum { JSTI_PLAYER_PLAYING = 0, JSTI_PLAYER_PAUSED = 1, JSTI_PLAYER_FINISHED = 2, JSTI_PLAYER_FAILED = 3 };
jsti_player *jsti_player_create(
    const int16_t *samples, size_t count, uint32_t sample_rate, char *error, size_t error_capacity);
int32_t jsti_player_set_paused(jsti_player *player, int32_t paused);
/* Seconds heard so far, and one of JSTI_PLAYER_*. */
double jsti_player_position(jsti_player *player);
int32_t jsti_player_state(jsti_player *player);
/* Stops output and releases the stream; safe from any thread. */
void jsti_player_destroy(jsti_player *player);

/* Record-bound playback controls; state 0 stopped, 1 playing, 2 paused. The
 * window ignores reports for a record that is no longer selected. */
int32_t jsti_window_set_playback(const char *record_id, int32_t state, const char *text);

/* ------------------------------------------------------------------- files */

/* Creates a directory (and parents) readable only by the current user, or
 * tightens an existing one. Refuses symbolic links. */
int32_t jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
/* Creates a new empty file with mode 0600; refuses existing paths and links. */
int32_t jsti_private_file_create(const char *path, char *error, size_t error_capacity);
int32_t jsti_open_path(const char *path, char *error, size_t error_capacity);

/* ------------------------------------------------------------ local models */

/* The Local models group reports these with the row index. */
enum {
    JSTI_EVENT_LOCAL_MODEL_DOWNLOAD = 50, /* index: row; downloads or resumes */
    JSTI_EVENT_LOCAL_MODEL_CANCEL = 51,   /* index: row */
    JSTI_EVENT_LOCAL_MODEL_REMOVE = 52,   /* index: row */
    JSTI_EVENT_LOCAL_MODEL_GPU = 53       /* index: 1 on, 0 off */
};

enum {
    JSTI_LOCAL_MODEL_NOT_INSTALLED = 0,
    JSTI_LOCAL_MODEL_PARTIAL = 1,
    JSTI_LOCAL_MODEL_DOWNLOADING = 2,
    JSTI_LOCAL_MODEL_INSTALLED = 3,
    JSTI_LOCAL_MODEL_REMOVING = 4
};

typedef struct JSTILocalModelRow {
    const char *name;
    const char *detail;
    /* Licence and provenance, shown as the row's tooltip. */
    const char *about;
    int32_t state;
} JSTILocalModelRow;

/* Rows of the on-device models the host offers, in its order. `gpu` is -1 to
 * hide the GPU switch (the runtime has no GPU backend), otherwise 0 or 1.
 * Safe from any thread, like the other window setters. */
int32_t jsti_window_set_local_models(
    const JSTILocalModelRow *rows, size_t count, const char *runtime_status, int32_t gpu);

/* Streaming SHA-256 through GLib's GChecksum. One object per digest; finish
 * writes 64 lowercase hex characters plus a terminator and ends the object's
 * use. destroy is always required. */
typedef struct JSTISHA256 JSTISHA256;
JSTISHA256 *jsti_sha256_create(char *error, size_t error_capacity);
int32_t jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error, size_t error_capacity);
int32_t jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hex_capacity, char *error, size_t error_capacity);
void jsti_sha256_destroy(JSTISHA256 *hasher);

/* On-device transcription through whisper.cpp, loaded at run time with the
 * same ABI as the Windows adapter.
 *
 * open loads libggml-base.so.0, libggml.so.0 and libwhisper.so.1 by absolute
 * path from `directory` (absolute; it and the libraries must not be writable
 * by other users), so their dependencies resolve to those copies and nothing
 * is searched for. It refuses any whisper_version() but the pinned one, then
 * registers the best-scoring libggml-cpu-*.so from that directory and, when
 * allow_gpu is 1 and libggml-vulkan.so is there, Vulkan. Process-wide: a
 * second open must name the same directory. NULL with an error otherwise. */
typedef struct JSTIWhisperRuntime JSTIWhisperRuntime;
JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int32_t allow_gpu, char *error, size_t error_capacity);
/* A short description such as "whisper.cpp 1.9.4; CPU". */
int32_t jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity);
/* 1 when a GPU device is registered and would be used, otherwise 0. */
int32_t jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime);

/* A cancellation token for one transcription; cancel is thread safe and may
 * come before, during or after transcribe. */
typedef struct JSTIWhisperJob JSTIWhisperJob;
JSTIWhisperJob *jsti_whisper_job_create(void);
void jsti_whisper_job_cancel(JSTIWhisperJob *job);
void jsti_whisper_job_destroy(JSTIWhisperJob *job);

enum {
    JSTI_WHISPER_OK = 0,
    JSTI_WHISPER_FAILED = -1,
    JSTI_WHISPER_CANCELLED = 1,
    JSTI_WHISPER_MODEL_MISMATCH = 2
};
/* Transcribes 16 kHz mono float samples with the model at the absolute
 * `model_path`, whose pinned SHA-256 is the 64 hex digits `model_sha256`.
 * Loading hashes every byte as it hands it to whisper.cpp, through one open
 * file, and a model whose bytes do not match is freed unused with
 * JSTI_WHISPER_MODEL_MISMATCH, so no byte that was not verified is ever
 * recognised with. The loaded model is cached for later calls with the same
 * path and digest and released when another model is used or release_model is
 * called; its file is closed once loaded. Calls are serialised. `language` is
 * a Whisper code such as "en"; NULL, empty or unknown detects it. On success
 * `*text` is a heap UTF-8 string for jsti_whisper_free_text. */
int32_t jsti_whisper_transcribe(
    JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256, const float *samples,
    size_t sample_count, const char *language, int32_t threads, JSTIWhisperJob *job, char **text, char *error,
    size_t error_capacity);
void jsti_whisper_free_text(char *text);
/* Frees the cached model, waiting for a running transcription to finish. */
void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime);
/* Frees the cached model only if it was loaded from `model_path`, atomically
 * with loading, so a model loaded in its place stays cached. 1 when freed, 0
 * when another model or none is cached, -1 for an invalid argument. */
int32_t jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *model_path);

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
