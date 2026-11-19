#ifndef JSTI_LINUX_AUDIO_CAPTURE_H
#define JSTI_LINUX_AUDIO_CAPTURE_H
/* PulseAudio microphone capture and device change reports. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

#ifdef __cplusplus
}
#endif
#endif
