#ifndef JSTI_WINDOWS_SUPPORT_H
#define JSTI_WINDOWS_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* UTF-8 strings throughout. Zero is success; -1 is failure with a caller-owned
 * error buffer. No API logs credential or transcript contents. Windows only. */
enum JSTIWindowEvent {
    JSTI_EVENT_TOGGLE_RECORDING = 1,
    JSTI_EVENT_IMPORT_AUDIO = 2,
    JSTI_EVENT_COPY_TRANSCRIPT = 3,
    JSTI_EVENT_SAVE_CREDENTIAL = 4,
    JSTI_EVENT_MODEL_CHANGED = 5,
    JSTI_EVENT_CLOSING = 6,
    JSTI_EVENT_READY = 7,
    JSTI_EVENT_ERROR = 8,
    JSTI_EVENT_HISTORY_SELECTED = 9,
    JSTI_EVENT_HISTORY_RETRY = 10,
    JSTI_EVENT_HISTORY_EXPORT = 11,
    JSTI_EVENT_HISTORY_OPEN_AUDIO = 12,
    JSTI_EVENT_MICROPHONE_CHANGED = 13,
    JSTI_EVENT_CANCEL_TRANSCRIPTION = 14,
    JSTI_EVENT_HISTORY_SEARCH = 15,
    JSTI_EVENT_TRANSCRIPT_VARIANT = 16,
    JSTI_EVENT_REFRESH_MODELS = 20
};

/* Runs on the UI thread. text is borrowed until callback returns. model_index
 * is the selected caller-supplied model. READY is sent after controls exist.
 * COPY_TRANSCRIPT carries the selected history ID, or empty if none is selected.
 * MICROPHONE_CHANGED and TOGGLE_RECORDING carry the selected microphone ID;
 * empty selects the default communications microphone. HISTORY_SEARCH carries
 * the current search text (empty when cleared); the host filters the rows it
 * supplies through jsti_window_set_history. TRANSCRIPT_VARIANT carries the
 * selected record ID after the user chose a transcript version; pair it with
 * jsti_window_transcript_variant() synchronously inside the callback. */
typedef void (*JSTIWindowCallback)(int event, const char *text, int model_index, void *context);
int jsti_window_run(const char *const *model_names, size_t model_count, int selected_index,
                    JSTIWindowCallback callback, void *context, char *error, size_t error_capacity);
/* Optional pre-run mode catalogue. is_live contains only 0/1 and must have the
 * same count/order as window_run's full model array. Preferences are global
 * indices of their respective mode; -1 chooses that mode's first model.
 * Null/count0 restores the legacy all-batch catalogue. Inputs are copied.
 * window_run's selected_index overrides that mode's preference. Every callback
 * continues to report a global model index, never a filtered combo row. */
int jsti_window_set_model_modes(const int *is_live, size_t count,
                                int preferred_batch_index, int preferred_live_index);
typedef struct JSTIModelRow {
    const char *id;
    const char *name;
    int is_live;
    int display_order; /* -1 hidden; otherwise unique visible rank, independent of slot index. */
} JSTIModelRow;
/* Deep-copies a model snapshot. Configure before window_run, then append-only
 * identity slots may be updated from any thread. Existing IDs/modes must stay
 * at the same indices; labels and visible order may change. Current selections
 * remain visible and selected even when their display_order becomes -1.
 * Programmatic refresh never emits MODEL_CHANGED or changes recording state.
 * status/refreshing update a separate discovery control; event20 requests a
 * refresh. No network operation runs inside the native window loop. */
int jsti_window_set_model_catalog(const JSTIModelRow *rows, size_t count,
                                   const char *status, int refreshing);
/* Thread safe; updates coalesce. Null status/transcript retains the prior value.
 * recording: -1 retains current value, 0 idle, 1 recording, 2 busy (disable controls). */
int jsti_window_update(const char *status, const char *transcript, int recording);
void jsti_window_request_close(void);
/* Copies IDs/names before return; also valid before window_run. Caller may
 * include a synthetic default row with an empty ID. Selection updates are
 * programmatic; a user change emits MICROPHONE_CHANGED with its device ID. */
int jsti_window_set_microphones(const char *const *ids, const char *const *names,
                                size_t count, const char *selected_id);


/* A complete active capture-device snapshot; borrowed only during the callback.
 * Endpoint IDs are opaque; an empty ID is reserved for the system-default row. */
typedef struct JSTIAudioDevice {
    const char *id;
    const char *name;
    int is_default;
} JSTIAudioDevice;
/* Latest-only refresh on the UI thread. Does not change the selected ID or emit
 * selection events; a missing selection becomes an unavailable row. Snapshots
 * received while recording/busy are deferred until idle. Error-only snapshots
 * (non-null error) retain the prior list. Must be called after window creation. */
int jsti_window_refresh_microphones(const JSTIAudioDevice *devices, size_t count, const char *error);
/* One owned worker registers endpoint notifications and enumerates off the UI
 * and capture threads. OS callbacks only signal coalesced work. The callback
 * receives a complete snapshot or an error, never a partial list; it must return
 * promptly and must not destroy the monitor. No credentials or capture access. */
typedef void (*JSTIAudioDevicesChangedCallback)(const JSTIAudioDevice *devices, size_t count,
                                               const char *error, void *context);
typedef struct JSTIAudioDeviceMonitor JSTIAudioDeviceMonitor;
JSTIAudioDeviceMonitor *jsti_audio_device_monitor_create(JSTIAudioDevicesChangedCallback callback, void *context,
                                                        char *error, size_t error_capacity);
/* Nonblocking and valid from the callback. No later snapshot is dispatched once
 * cancellation is observed; an already-running callback finishes normally. */
void jsti_audio_device_monitor_cancel(JSTIAudioDeviceMonitor *monitor);
/* Cancels, unregisters off the notification callback, drains and joins. The
 * caller retains context until success. Returns -1 without destroying when
 * called by the snapshot worker, preventing self-join. Do not call concurrently
 * with another destroy. Call outside the UI/actor after the window loop ends. */
int jsti_audio_device_monitor_destroy(JSTIAudioDeviceMonitor *monitor, char *error, size_t error_capacity);
int jsti_audio_device_monitor_self_test(char *error, size_t error_capacity);

typedef struct JSTIHistoryRow {
    const char *id;
    const char *title;
    const char *detail;
} JSTIHistoryRow;
/* Atomically replaces history; synchronously deep-copies all UTF-8 strings.
 * selected_id: null preserves the current selection if it still exists, an
 * empty string clears it. Programmatic updates do not emit selection events.
 * Events 9-12 and 16 carry the selected record ID in their borrowed text
 * argument. Rows are whatever the host chose to show (for example a search
 * result); the window never filters, reorders or edits them itself. Clearing
 * or changing the selected row also resets the displayed transcript variant
 * until the host reports one. */
int jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id);
/* Which retained transcript the window shows for record_id. It is applied only
 * while that record is still the selected row, so a late report can never
 * describe a different record; null/empty record_id clears the control.
 * selected: -1 none, 0 processed, 1 original. can_switch (0/1) lets the user
 * choose between both versions; otherwise the control only reports the one
 * displayed. Thread safe; updates coalesce with jsti_window_update. A user
 * choice emits TRANSCRIPT_VARIANT and is retained until the selection changes. */
int jsti_window_set_transcript_variant(const char *record_id, int selected, int can_switch);
/* The displayed transcript variant: -1 none, 0 processed, 1 original. UI thread
 * only; call synchronously from the COPY_TRANSCRIPT, HISTORY_EXPORT or
 * TRANSCRIPT_VARIANT callback so it pairs with that event's record ID. */
int jsti_window_transcript_variant(void);
/* Call synchronously from the UI event callback, capturing the event's record
 * ID first. Returns 0 chosen (UTF-8 path), 1 cancelled, -1 failed. A too-small
 * output buffer is an error; paths are never silently truncated. */
int jsti_window_choose_export_path(const char *suggested_filename, char *path, size_t path_capacity,
                                   char *error, size_t error_capacity);
/* Opens an existing audio file through its registered Windows application.
 * Only recognised audio filename extensions are accepted; never executes an
 * arbitrary imported file. Shell activation errors are returned. */
int jsti_shell_open_file(const char *path, char *error, size_t error_capacity);

/* Atomic Apply callback from the native settings dialog, on the UI thread.
 * prompt/new_key are borrowed until return. Empty new_key means keep the saved
 * credential; no saved credential is read back into the password field. */
typedef void (*JSTIPostProcessingCallback)(int enabled, int model_index, const char *prompt,
                                          const char *new_key, void *context);
/* Thread safe; deep-copies model labels and persisted settings. Remote
 * processing remains unavailable until configured, and defaults disabled. */
int jsti_window_set_postprocessing(const char *const *model_names, size_t model_count,
                                   int selected_index, int enabled, const char *prompt,
                                   JSTIPostProcessingCallback callback, void *context);

/* Borrowed UTF-8 draft values. Choice -1 inherits the app setting, -2 preserves
 * an existing unavailable value, otherwise indexes the supplied catalogue.
 * polish_mode: 0 inherit, 1 disabled, 2 enabled. Paths are newline-separated. */
typedef struct JSTIProfileDraft {
    const char *id, *name, *paths, *prompt, *output_language, *notes;
    int transcription, polish_mode, polish_model, language;
} JSTIProfileDraft;
/* UI-thread callback: action 1 validates/copies all drafts for an atomic save;
 * return -1 with a readable error to keep the editor open. Action 0 cancels.
 * All pointers expire on return. Never block waiting for a Swift actor. */
typedef int (*JSTIProfilesCallback)(int action, const JSTIProfileDraft *drafts, size_t count,
                                  void *context, char *error, size_t error_capacity);
int jsti_window_set_profiles(const JSTIProfileDraft *drafts, size_t count,
                            const char *const *transcription_names, size_t transcription_count,
                            const char *const *polish_names, size_t polish_count,
                            const char *const *language_names, size_t language_count,
                            const char *notice,
                            JSTIProfilesCallback callback, void *context);
/* Posts an open request to the native UI thread. Ignored during recording. */
void jsti_window_request_profiles(void);

typedef struct JSTICapture JSTICapture;
/* Active capture endpoints only; the default marker means eCommunications.
 * Callbacks run synchronously after enumeration succeeds; strings are borrowed
 * until callback return. A successful empty list means no active microphones.
 * Enumeration does not activate a microphone or request recording access. */
typedef void (*JSTIAudioDeviceCallback)(const char *id, const char *name, int is_default, void *context);
int jsti_audio_devices_enumerate(JSTIAudioDeviceCallback callback, void *context,
                                 char *error, size_t error_capacity);
/* Dedicated bounded writer callback, PCM16 little-endian mono at the capture's
 * sample rate: 16 kHz unless created by jsti_capture_create_with_format. Normally
 * one 100 ms frame of sample_rate/10 samples (1600 at 16 kHz, 2400 at 24 kHz);
 * stop flushes a final partial frame. Copy synchronously and return promptly.
 * Do not call capture stop/destroy from either callback. */
typedef void (*JSTIAudioCallback)(const int16_t *samples, size_t sample_count, void *context);
typedef void (*JSTIAudioErrorCallback)(const char *message, void *context);
/* Default communications microphone at 16 kHz. */
JSTICapture *jsti_capture_create(JSTIAudioCallback callback, JSTIAudioErrorCallback error_callback,
                                 void *context);
/* Copies the opaque endpoint ID and captures at 16 kHz. Null/empty chooses the
 * default communications microphone at start. An explicit ID must still be
 * active and a capture device; it never silently falls back to another
 * microphone. On success an error buffer is cleared rather than left stale. */
JSTICapture *jsti_capture_create_with_device(const char *device_id, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback error_callback, void *context,
                                             char *error, size_t error_capacity);
/* As create_with_device, capturing directly at sample_rate: exactly 16000 or
 * 24000 (OpenAI Realtime canonical PCM) Hz PCM16 mono. The Windows audio engine
 * converts to the selected rate in a single pass; frames carry sample_rate/10
 * samples. Any other rate fails here with a descriptive error before any
 * microphone is activated. The rate is fixed for the capture's lifetime; create
 * a new capture to change it. */
JSTICapture *jsti_capture_create_with_format(const char *device_id, uint32_t sample_rate,
                                             JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback error_callback, void *context,
                                             char *error, size_t error_capacity);
/* Serialize start/stop/destroy on the caller side. start reports initialization
 * errors synchronously; later device/stream failures invoke error_callback. */
int jsti_capture_start(JSTICapture *capture, char *error, size_t error_capacity);
int jsti_capture_stop(JSTICapture *capture, char *error, size_t error_capacity);
void jsti_capture_destroy(JSTICapture *capture);

/* Legacy direct path, retained for source/ABI compatibility. Capture at the
 * recording hotkey before showing UI. Insertion is explicitly addressed to the
 * original native Edit/RichEdit control only; other applications fail closed
 * and should offer Copy. This entrypoint never sends keystrokes or touches the
 * clipboard. New callers use the opaque jsti_insertion_* API below. */
typedef struct JSTITextTarget {
    uintptr_t window;
    uintptr_t focused_control;
    uint32_t process_id;
    uint32_t thread_id;
} JSTITextTarget;
int jsti_target_capture(JSTITextTarget *target, char *error, size_t error_capacity);
int jsti_target_insert_text(const JSTITextTarget *target, const char *text,
                            char *error, size_t error_capacity);
/* Deliberate user copy: plain CF_UNICODETEXT, eligible for clipboard history. */
int jsti_clipboard_write(const char *text, char *error, size_t error_capacity);

/* Opaque insertion target with explicit lifetime. Capture synchronously at the
 * recording hotkey: it records the foreground window, its thread and the
 * focused control immediately and never blocks on the target application. A
 * dedicated worker resolves the snapshotted focus event to its exact UI
 * Automation element so later insertion can prove field identity; startup
 * never waits for that provider. Every insertion re-verifies the original
 * process, thread, window and focused control, refuses password/read-only
 * fields and never steals focus or types into another application.
 *
 * Methods, in order of preference for the captured control:
 *  1. Native Unicode Edit/RichEdit: EM_REPLACESEL to the captured control
 *     (inserts at the caret or replaces the selection).
 *  2. UI Automation Value pattern SetValue, used only when it is exactly
 *     equivalent to insertion: the field is empty or the whole text is
 *     selected (or the replace-field flag is set). UI Automation's Text
 *     pattern is read-only and cannot insert; the field is never replaced
 *     wholesale to emulate a caret insertion.
 *  3. Guarded clipboard paste: the current clipboard is snapshotted, the text
 *     is placed as CF_UNICODETEXT excluded from clipboard history/cloud sync,
 *     Ctrl+V is sent while the captured control still owns focus, the field is
 *     read back through UI Automation where possible, and the previous
 *     clipboard content is restored unless it changed meanwhile.
 * Insertion into a process of higher integrity (for example an elevated app)
 * fails closed because Windows UIPI blocks both messages and input.
 *
 * Insert blocks the caller for a bounded time (about six seconds worst case)
 * and may be called at most once at a time per target. Destroy is nonblocking:
 * a worker still blocked inside a provider call is detached and
 * releases its own resources when that call returns. Destroy after insert
 * returns, never from another thread concurrently with insert. */
typedef struct JSTIInsertionTarget JSTIInsertionTarget;
enum JSTIInsertionFlags {
    /* Replace the whole field instead of inserting at the caret. Native
     * controls select all first; UI Automation requires a writable Value
     * pattern; the clipboard fallback is never used for replacement. */
    JSTI_INSERTION_REPLACE_FIELD = 1u << 0,
    /* Leave the transcript on the clipboard after a paste instead of
     * restoring the previous content (macOS "restore clipboard" off). */
    JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD = 1u << 1,
    /* Never use the clipboard/keystroke fallback; fail closed instead. */
    JSTI_INSERTION_NO_PASTE_FALLBACK = 1u << 2
};
enum JSTIInsertionMethod {
    JSTI_INSERTION_METHOD_NONE = 0,
    JSTI_INSERTION_METHOD_NATIVE_EDIT = 1,
    JSTI_INSERTION_METHOD_UIA_VALUE = 2,
    JSTI_INSERTION_METHOD_PASTE = 3
};
enum JSTIInsertionIdentity {
    /* Process, thread, foreground window and focused control matched. */
    JSTI_INSERTION_IDENTITY_WINDOW = 1,
    /* Additionally the same UI Automation element that had focus at capture. */
    JSTI_INSERTION_IDENTITY_FIELD = 2
};
enum JSTIInsertionClipboard {
    JSTI_INSERTION_CLIPBOARD_UNTOUCHED = 0,
    JSTI_INSERTION_CLIPBOARD_RESTORED = 1,
    /* Restored what fit; oversized or non-memory formats were not preserved. */
    JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY = 2,
    /* The transcript was intentionally left on the clipboard. */
    JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT = 3,
    JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED = 4,
    /* Another application changed the clipboard meanwhile; it was left alone. */
    JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE = 5
};
typedef struct JSTIInsertionResult {
    int method;    /* JSTIInsertionMethod */
    int verified;  /* 1 when the field was read back and contains the text */
    int identity;  /* JSTIInsertionIdentity */
    int clipboard; /* JSTIInsertionClipboard */
} JSTIInsertionResult;
/* Start the bounded focus-event observer during normal application startup. */
void jsti_insertion_prepare(void);
/* Null with an error when no external application field is focused. */
JSTIInsertionTarget *jsti_insertion_capture(char *error, size_t error_capacity);
/* Zero: input was submitted by result->method; verified reports read-back.
 * -1: no text mutation was submitted. 1: mutation may have occurred or shortcut
 * submission was partial; do not retry automatically. Clipboard state is
 * reported in result->clipboard. Text must be non-empty UTF-8. */
int jsti_insertion_insert(JSTIInsertionTarget *target, const char *text, unsigned flags,
                          JSTIInsertionResult *result, char *error, size_t error_capacity);
/* Thread-safe nonblocking abandonment. Prevents pending mutations; an operation
 * already dispatched may complete, and insert then reports its actual/uncertain
 * outcome. The target remains owned until insert returns and destroy is called. */
void jsti_insertion_cancel(JSTIInsertionTarget *target);
/* Explicit clipboard-only output, guarded by the captured request's cancellation
 * state immediately before replacement. Does not follow or mutate field focus. */
int jsti_insertion_copy_text(JSTIInsertionTarget *target, const char *text, JSTIInsertionResult *result,
                              char *error, size_t error_capacity);
/* Original captured process handle, never a fresh focus/PID lookup. required_bytes
 * includes the NUL; 0 success, 2 insufficient buffer, -1 unavailable. */
int jsti_insertion_executable_path(const JSTIInsertionTarget *target, char *path, size_t path_capacity,
                                   size_t *required_bytes, char *error, size_t error_capacity);
void jsti_insertion_destroy(JSTIInsertionTarget *target);
/* Deterministic native checks on app-owned synthetic hidden controls with
 * injected foreground, clipboard and keystroke seams: caret/selection
 * insertion, surrogate pairs, stale identity, password/read-only refusal,
 * UI Automation value/paste paths, timeouts and worker cleanup. Never sends
 * real input, touches the system clipboard or inserts into another app. */
int jsti_text_output_self_test(char *error, size_t error_capacity);

/* Generic credentials scoped to this Windows user; names are automatically
 * prefixed with com.justspeaktoit/. Read: 1 missing, 2 buffer too small (required
 * byte count returned). No terminator is appended to credential bytes. */
int jsti_credential_write(const char *name, const uint8_t *bytes, size_t count,
                          char *error, size_t error_capacity);
int jsti_credential_read(const char *name, uint8_t *bytes, size_t capacity, size_t *count,
                         char *error, size_t error_capacity);
int jsti_credential_delete(const char *name, char *error, size_t error_capacity);

/* App-owned multipart staging only. Absolute local paths; relative paths,
 * alternate data streams and all reparse points in the path are rejected.
 * Directory preparation creates/repairs only the supplied leaf directory; its
 * parent must exist and an existing leaf must belong to the current user.
 * Both APIs apply an explicit protected DACL granting only the current user
 * and SYSTEM full control. File creation is exclusive: existing files are
 * never opened, truncated or followed. No parent ACL is changed. */
int jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
int jsti_private_file_create(const char *path, char *error, size_t error_capacity);
/* Uses a unique temporary directory and synthetic bytes only; verifies ACLs,
 * directory repair, existing-file preservation and junction refusal. */
int jsti_private_storage_self_test(char *error, size_t error_capacity);

typedef struct JSTIWebSocket JSTIWebSocket;
enum JSTIWebSocketEvent {
    JSTI_WEBSOCKET_OPEN = 1,
    JSTI_WEBSOCKET_TEXT = 2,
    JSTI_WEBSOCKET_BINARY = 3,
    JSTI_WEBSOCKET_SEND_COMPLETE = 4,
    JSTI_WEBSOCKET_CLOSED = 5,
    JSTI_WEBSOCKET_ERROR = 6
};
/* All callbacks run serially on one dedicated worker. Bytes are borrowed until
 * return; copy synchronously. Messages are complete and bounded to 4 MiB. Code
 * is the native error for ERROR/SEND_COMPLETE (zero means send succeeded), or
 * the peer close status for CLOSED. Error bytes never include URL/header data.
 * Callbacks may send or cancel, but must not destroy this socket. */
typedef void (*JSTIWebSocketCallback)(int event, const uint8_t *bytes, size_t count,
                                     int code, void *context);
/* Copies all inputs. wss is required except ws on literal loopback addresses
 * or localhost for local probes. Credentials in URLs and redirects are refused.
 * Header names/values are validated; WinHTTP owns the upgrade control headers. */
JSTIWebSocket *jsti_websocket_create(const char *url, const char *const *header_names,
                                     const char *const *header_values, size_t header_count,
                                     JSTIWebSocketCallback callback, void *context,
                                     char *error, size_t error_capacity);
int jsti_websocket_start(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Copies at most 4 MiB. Exactly one send may be outstanding. A return of zero
 * guarantees one later SEND_COMPLETE callback, including during cancellation. */
int jsti_websocket_send(JSTIWebSocket *socket, const uint8_t *bytes, size_t count,
                        int is_text, char *error, size_t error_capacity);
/* Thread safe cancellation, including during the HTTP upgrade. No join. */
void jsti_websocket_cancel(JSTIWebSocket *socket);
/* Serialize destruction against all caller API calls. Cancels, drains native
 * callbacks and joins the worker. On failure the socket/context remain owned
 * by the caller and must be retained; zero releases the socket permanently. */
int jsti_websocket_destroy(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Deterministic URL/header validation; no network or credentials. */
int jsti_websocket_self_test(char *error, size_t error_capacity);

typedef struct JSTIAudioConversion JSTIAudioConversion;
/* One completion on the dedicated conversion worker after start succeeds.
 * status: 0 success, 1 cancelled, -1 failure. Duration/sample_count describe the
 * actual canonical16kHz mono PCM16 output only on success. Error is borrowed
 * until callback returns. Retain context until destroy succeeds; never destroy
 * from this callback. The input is never changed. */
typedef void (*JSTIAudioConversionCallback)(int status, double duration_seconds,
                                           uint64_t sample_count, const char *error, void *context);
/* Absolute local regular-file input; maximum25,000,000 input/output bytes.
 * Output must not exist, and its parent must already have been prepared by
 * jsti_private_directory_prepare. Conversion uses installed Media Foundation
 * decoders; support for compressed formats depends on the Windows installation.
 * Partial outputs are removed by their owned handle on failure/cancellation. */
JSTIAudioConversion *jsti_audio_conversion_create(const char *input_path, const char *output_path,
                                                  JSTIAudioConversionCallback callback, void *context,
                                                  char *error, size_t error_capacity);
int jsti_audio_conversion_start(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Thread safe request. Pending sample reads are flushed on the worker;
 * cancellation is checked between setup stages and output writes. */
void jsti_audio_conversion_cancel(JSTIAudioConversion *conversion);
/* Serialize against caller operations. Cancels and joins; zero frees the job.
 * On failure retain the job/context and retry outside its callback thread. */
int jsti_audio_conversion_destroy(JSTIAudioConversion *conversion, char *error, size_t error_capacity);
/* Synthetic WAV decode/resample, bounds/collision/refusal/cancellation checks.
 * No microphone, credentials, provider requests, or user recordings. */
int jsti_audio_conversion_self_test(char *error, size_t error_capacity);

/* Deterministic native checks: Unicode, 16/24 kHz frame boundaries, silence,
 * fixed queue capacity, writer drain, capture creation and sample-rate
 * validation, invalid insertion targets. Does not use microphone, clipboard or
 * real credentials. */
int jsti_native_self_test(char *error, size_t error_capacity);
int jsti_audio_devices_self_test(char *error, size_t error_capacity);
/* Call on the UI thread from READY in smoke-test mode. Verifies native control
 * bounds, history updates/events, search/filter selection handling, transcript
 * variant action identities and an invisible settings Apply round-trip.
 * Restores history afterwards; never uses microphone, clipboard or credentials. */
int jsti_window_self_test(char *error, size_t error_capacity);
/* Smoke-test diagnostics only: writes a 32-bit BMP of this application's client
 * window and controls. Call on the UI thread after READY. Never captures the
 * desktop or another app; caller provides a smoke-test state without secrets. */
int jsti_window_save_snapshot(const char *path, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
