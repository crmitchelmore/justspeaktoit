#ifndef JSTI_WINDOWS_RECORDING_FEEDBACK_H
#define JSTI_WINDOWS_RECORDING_FEEDBACK_H
/* Recording feedback sounds. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Independent predecoded recording-feedback channel. No History/TTS state is shared.
 * create does not open files/devices. prepare runs off UI, once; cancellation may
 * run concurrently. play/stop enqueue commands only. cue: 0=start, 1=stop;
 * gain is finite 0...1 and applied to PCM, never endpoint volume.
 * failure is borrowed during callback on the owned worker; context must outlive
 * destroy. Callback must not destroy or block waiting for this channel.
 * The stream stays warm with silence; stop discards the pending cue and
 * emits silence on the next render event. Already submitted audio is bounded
 * by the negotiated 50 ms-or-smaller buffer (plus endpoint hardware latency).
 * destroy joins off UI, after prepare returns; it reports cleanup failures.
 * Command functions return 0 on success, -1 with an explicit error on failure;
 * diagnostic getters/checks document their own success values below. */
typedef struct JSTIRecordingFeedback JSTIRecordingFeedback;
typedef void (*JSTIRecordingFeedbackFailure)(const char *error, void *context);
JSTIRecordingFeedback *jsti_recording_feedback_create(JSTIRecordingFeedbackFailure failure, void *context,
                                                      char *error, size_t error_capacity);
int jsti_recording_feedback_prepare(JSTIRecordingFeedback *feedback, const char *start_path, const char *stop_path,
                                    char *error, size_t error_capacity);
void jsti_recording_feedback_cancel_preparation(JSTIRecordingFeedback *feedback);
int jsti_recording_feedback_play(JSTIRecordingFeedback *feedback, int cue, float gain,
                                 char *error, size_t error_capacity);
/* Diagnostic only: 0 before the current play's first PCM buffer is released,
 * -1 with error if failed/cancelled, otherwise command-admission-to-ReleaseBuffer
 * seconds. A superseded play cannot publish into a newer play's measurement.
 * This is queue latency, NOT audible or hardware latency. No endpoint calls. */
double jsti_recording_feedback_first_buffer_latency(JSTIRecordingFeedback *feedback,
                                                   char *error, size_t error_capacity);
void jsti_recording_feedback_stop(JSTIRecordingFeedback *feedback);
/* 1 once this stop's first silence buffer is released, 0 while pending, -1
 * with error on failure. Old submitted audio may still be in hardware. */
int jsti_recording_feedback_stop_acknowledged(JSTIRecordingFeedback *feedback,
                                             char *error, size_t error_capacity);
int jsti_recording_feedback_destroy(JSTIRecordingFeedback *feedback, char *error, size_t error_capacity);
/* Codec-only installed-MF validation: exactly eight actual asset paths. No
 * endpoint is opened. Also checks the production PCM fill/gain/restart seam. */
int jsti_recording_feedback_self_test(const char *const *paths, size_t count, char *error, size_t error_capacity);
/* Same resident-renderer seam, independent of optional MF and audio hardware. */
int jsti_recording_feedback_renderer_self_test(char *error, size_t error_capacity);
/* Device-free installed-codec check of a profile's start/stop AAC assets.
 * Returns 2 after both bounded decodes and cleanup, -1 with an explicit error. */
int jsti_recording_feedback_check_assets(const char *start_path, const char *stop_path,
                                        char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
