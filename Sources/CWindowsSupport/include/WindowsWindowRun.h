#ifndef JSTI_WINDOWS_WINDOW_RUN_H
#define JSTI_WINDOWS_WINDOW_RUN_H
/* The main window: run, Escape cancellation, models, microphones, About and History filters. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "WindowsWindowEvents.h"

#ifdef __cplusplus
extern "C" {
#endif

int jsti_window_run(const char *const *model_names, size_t model_count, int selected_index,
                    JSTIWindowCallback callback, void *context, char *error, size_t error_capacity);
/* Pre-run only: opt in to passive Escape observation while recording/working.
 * Pass 0 for synthetic/screenshot windows. No listener is installed while idle. */
int jsti_window_configure_global_escape(int enabled);
/* Thread-safe saved preference, independent of the pre-run synthetic-window opt-in. */
int jsti_window_set_escape_cancellation(int enabled);
/* Publish the independent Voice Edit reason before its usual window state update. */
int jsti_window_set_voice_edit_escape(int active);
/* Thread-safe final Host admission check for a queued local/global Escape token. */
int jsti_window_global_escape_is_current(uint64_t token);
/* Optional pre-run mode catalogue with the same count/order as window_run's
 * full model array. Each mode is 0 remote batch, 1 remote live, 2 local batch
 * or 3 local live: bit 0 is live, bit 1 is local. The window shows a Source
 * picker (Remote, Local) when both sources have models, then a Mode picker
 * (Batch, Live) when the selected source has both. Preferences are global
 * indices of a remote batch, a remote live and a local batch row; -1 chooses
 * that mode's first model. Null/count0 restores the legacy all-batch
 * catalogue. Inputs are copied. window_run's selected_index overrides that
 * mode's preference. Every callback continues to report a global model index,
 * never a filtered combo row. */
int jsti_window_set_model_modes(const int *modes, size_t count, int preferred_batch_index,
                                int preferred_live_index, int preferred_local_index);
typedef struct JSTIModelRow {
    const char *id;
    const char *name;
    int is_live;
    int display_order; /* -1 hidden; otherwise unique visible rank, independent of slot index. */
    int is_local; /* 1 for an on-device model; the Source picker separates Local from Remote. */
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
/* Preview-only, bounded/coalesced, invalidated by native page/record/version changes.
 * Offer returns 1 for a stale ticket, -1 for an enqueue/validation failure. */
uint64_t jsti_window_begin_cleanup_preview(void);
int jsti_window_cleanup_preview(const char *text, uint64_t ticket);
void jsti_window_end_cleanup_preview(uint64_t ticket);
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
    /* The History card, worded by the shared DesktopHistoryRowSummary. Each may
     * be null or empty, which hides its badge. tone: 0 transcribed, 1 failed,
     * 2 not yet transcribed. */
    const char *created;
    const char *audio_length;
    const char *cost;
    const char *preview;
    const char *models;
    const char *context;
    int tone;
} JSTIHistoryRow;

typedef struct JSTIAboutLink {
    const char *title;
    const char *url;
} JSTIAboutLink;
/* Copies metadata and up to eight HTTPS links before window_run. No network,
 * updater or installation is started. Returns -1 for invalid input or a running window. */
int jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count);

typedef struct JSTIHistoryFilterModel {
    const char *id;
    const char *name;
    int selected;
} JSTIHistoryFilterModel;
/* Copies the complete used-model catalogue and current filter. Dates are
 * Gregorian YYYY-MM-DD, or empty for no boundary. Safe from any thread. */
int jsti_window_set_history_filters(const JSTIHistoryFilterModel *models, size_t count,
                                    int errors_only, const char *from_day, const char *through_day);

#ifdef __cplusplus
}
#endif
#endif
