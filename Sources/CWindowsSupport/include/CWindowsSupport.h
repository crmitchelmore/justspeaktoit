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
    JSTI_EVENT_ERROR = 8
};

/* Runs on the UI thread. text is borrowed until callback returns. model_index
 * is the selected caller-supplied model. READY is sent after controls exist. */
typedef void (*JSTIWindowCallback)(int event, const char *text, int model_index, void *context);
int jsti_window_run(const char *const *model_names, size_t model_count, int selected_index,
                    JSTIWindowCallback callback, void *context, char *error, size_t error_capacity);
/* Thread safe; updates coalesce. Null status/transcript retains the prior value.
 * recording: -1 retains current value, 0 idle, 1 recording, 2 busy (disable controls). */
int jsti_window_update(const char *status, const char *transcript, int recording);
void jsti_window_request_close(void);

typedef struct JSTICapture JSTICapture;
/* Dedicated WASAPI worker, PCM16 little-endian, 16 kHz mono. Normally 1600
 * samples/100ms; stop flushes a final partial frame. Copy synchronously and
 * return promptly. Do not call capture stop/destroy from either callback. */
typedef void (*JSTIAudioCallback)(const int16_t *samples, size_t sample_count, void *context);
typedef void (*JSTIAudioErrorCallback)(const char *message, void *context);
JSTICapture *jsti_capture_create(JSTIAudioCallback callback, JSTIAudioErrorCallback error_callback,
                                 void *context);
/* Serialize start/stop/destroy on the caller side. start reports initialization
 * errors synchronously; later device/stream failures invoke error_callback. */
int jsti_capture_start(JSTICapture *capture, char *error, size_t error_capacity);
int jsti_capture_stop(JSTICapture *capture, char *error, size_t error_capacity);
void jsti_capture_destroy(JSTICapture *capture);

/* Capture at the recording hotkey before showing UI. Insertion is explicitly
 * addressed to the original native Edit/RichEdit control. Other applications
 * fail closed and should offer Copy. No global keystrokes or focus stealing. */
typedef struct JSTITextTarget {
    uintptr_t window;
    uintptr_t focused_control;
    uint32_t process_id;
    uint32_t thread_id;
} JSTITextTarget;
int jsti_target_capture(JSTITextTarget *target, char *error, size_t error_capacity);
int jsti_target_insert_text(const JSTITextTarget *target, const char *text,
                            char *error, size_t error_capacity);
int jsti_clipboard_write(const char *text, char *error, size_t error_capacity);

/* Generic credentials scoped to this Windows user; names are automatically
 * prefixed with com.justspeaktoit/. Read: 1 missing, 2 buffer too small (required
 * byte count returned). No terminator is appended to credential bytes. */
int jsti_credential_write(const char *name, const uint8_t *bytes, size_t count,
                          char *error, size_t error_capacity);
int jsti_credential_read(const char *name, uint8_t *bytes, size_t capacity, size_t *count,
                         char *error, size_t error_capacity);
int jsti_credential_delete(const char *name, char *error, size_t error_capacity);

/* Deterministic native checks: Unicode, frame boundaries, silence, invalid
 * insertion targets. Does not use microphone, clipboard or real credentials. */
int jsti_native_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
