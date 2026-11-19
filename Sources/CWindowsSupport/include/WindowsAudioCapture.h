#ifndef JSTI_WINDOWS_AUDIO_CAPTURE_H
#define JSTI_WINDOWS_AUDIO_CAPTURE_H
/* Microphone capture (WASAPI). Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTICapture JSTICapture;
/* Active capture endpoints only; the default marker means eCommunications.
 * Callbacks run synchronously after enumeration succeeds; strings are borrowed
 * until callback return. A successful empty list means no active microphones.
 * Enumeration does not activate a microphone or request recording access. */
typedef void (*JSTIAudioDeviceCallback)(const char *id, const char *name, int is_default, void *context);
int jsti_audio_devices_enumerate(JSTIAudioDeviceCallback callback, void *context,
                                 char *error, size_t error_capacity);
/* Dedicated bounded writer callback, PCM16 little-endian mono at the capture's
 * sample rate: 16 kHz unless explicitly configured. Legacy constructors emit
 * 100 ms frames; create_with_options selects 20 or 100 ms. Stop flushes a final
 * partial frame without padding. Copy synchronously and return promptly.
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
/* As create_with_format, with an explicit frame duration of exactly 20 or
 * 100 ms. Rejects other durations before device activation. PCM storage stays
 * fixed and the writer queue retains 12.8 seconds at either duration/rate.
 * This sets application batching only, not the audio driver's packet period.
 * Choose a duration compatible with the provider; AssemblyAI requires at least
 * 50 ms and should use 100 ms. Legacy constructors always retain 100 ms. */
JSTICapture *jsti_capture_create_with_options(const char *device_id, uint32_t sample_rate,
                                              uint32_t frame_milliseconds, JSTIAudioCallback callback,
                                              JSTIAudioErrorCallback error_callback, void *context,
                                              char *error, size_t error_capacity);
/* Serialize start/stop/destroy on the caller side. start reports initialization
 * errors synchronously; later device/stream failures invoke error_callback. */
int jsti_capture_start(JSTICapture *capture, char *error, size_t error_capacity);
int jsti_capture_stop(JSTICapture *capture, char *error, size_t error_capacity);
void jsti_capture_destroy(JSTICapture *capture);

/* Package-only owned capture, never selected by the production factory.
 * Calls are serialized by one owner, outside all native callbacks. run_id is
 * immutable for the handle lifetime; an owner slot must not be copied/reused.
 * Open may block in the OS and may return a partial non-null owner on failure.
 * Never pass this distinct handle to legacy capture_destroy.
 * Receipt size/version must be initialized by the caller. Only retire success
 * nulls the slot, after actual producer join and thread-affine resource release.
 * Audio failure is separate from safety: safe retirement can retain AUDIO_FAILED.
 * On control/join failure retain owner AND callback context for explicit retry. */
typedef struct JSTIOwnedCapture JSTIOwnedCapture;
enum {
    JSTI_OWNED_CAPTURE_VERSION = 1,
    JSTI_OWNED_PRODUCER_QUIESCED = 1,
    JSTI_OWNED_CALLBACKS_DRAINED = 2,
    JSTI_OWNED_AUDIO_FAILED = 4,
    JSTI_OWNED_RESOURCES_RETIRED = 8,
    JSTI_OWNED_OWNERSHIP_RETAINED = 16
};
typedef struct JSTIOwnedCaptureReceipt {
    uint32_t size;
    uint32_t version;
    uint32_t flags;
    uint64_t delivered_samples;
    char first_audio_error[1024];
} JSTIOwnedCaptureReceipt;
int jsti_owned_capture_open(JSTIOwnedCapture **owner, const char *run_id, const char *device_id,
                            uint32_t sample_rate, uint32_t frame_ms, JSTIAudioCallback audio,
                            JSTIAudioErrorCallback failure, void *context,
                            JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
int jsti_owned_capture_quiesce(JSTIOwnedCapture *owner, const char *run_id,
                               JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
int jsti_owned_capture_retire(JSTIOwnedCapture **owner, const char *run_id,
                              JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);
/* Hardware-free qualification only: bits 1 stop-signal failure, 2 producer-join
 * failure, 4 writer-join failure (each once), 8 late audio error, 16 partial-open
 * failure. Uses real threads/events/Frames/writer; emits one final 73-sample tail.
 * No environment switch or production fallback selects this entrypoint. */
int jsti_owned_capture_open_fixture(JSTIOwnedCapture **owner, const char *run_id, uint32_t faults,
                                    uint32_t sample_rate, uint32_t frame_ms, JSTIAudioCallback audio,
                                    JSTIAudioErrorCallback failure, void *context,
                                    JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
