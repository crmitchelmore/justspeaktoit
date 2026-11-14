#ifndef JSTI_LINUX_WINDOW_RUN_H
#define JSTI_LINUX_WINDOW_RUN_H
/* Running the window and its main-thread updates: Escape, cleanup preview, vocabulary,
 * models, History, migration and setup. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>
#include "LinuxWindowEvents.h"
#include "LinuxWindowModels.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Before running GTK: root contains the executable's bundled hicolor theme. */
int32_t jsti_app_icon_configure(const char *root, char *error, size_t error_capacity);

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
/* Thread-safe saved policy and final Host admission check for window-local Escape.
 * Policy/state transitions retire old tokens before queued GTK presentation. */
int32_t jsti_window_set_escape_cancellation(int32_t enabled);
int32_t jsti_window_escape_is_current(uint64_t token);
/* Preview-only; one pending value. Native navigation retires the ticket.
 * Offer returns 1 for a stale ticket, -1 for an enqueue/validation failure. */
uint64_t jsti_window_begin_cleanup_preview(void);
int32_t jsti_window_cleanup_preview(const char *text, uint64_t ticket);
void jsti_window_end_cleanup_preview(uint64_t ticket);
/* Events 70 (action), 71 (load), index 0 corrections / 1 pronunciation;
 * event 72 reads a selected recording's correction snapshot (kind 2).
 * Kind 4 edits the separate legacy word-to-pronunciation preference map. */
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh);
int32_t jsti_window_set_model_catalog(
    const JSTIModelRow *rows, size_t count, int32_t selected, const char *status, int32_t refreshing);
/* Remembered global slots for Remote Batch/Live and Local Batch/Live.
 * Queued before window construction; -1 means no saved model for that mode. */
int32_t jsti_window_set_preferred_models(int32_t batch, int32_t live, int32_t local, int32_t local_live);
/* Queued inactive Local choices only; -1 leaves a slot unchanged. No selection event. */
int32_t jsti_window_set_local_model_preferences(int32_t batch, int32_t live);
int32_t jsti_window_set_microphones(
    const char *const *ids, const char *const *names, size_t count, const char *selected);
int32_t jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selected_id);
/* Complete retained IDs, including filtered-out rows. Copied for Clear confirmation. */
int32_t jsti_window_set_history_management(const char *identifiers);
int32_t jsti_window_confirm_audio_cleanup(const char *token, size_t count);
int32_t jsti_window_show_migration_report(const char *text);
/* Owned, modal preview; Replace requires a second affirmative response.
 * Both stages default to Cancel. Called from the Host's ordered publication path. */
int32_t jsti_window_confirm_migration_restore(const char *token, const char *text, int32_t offers_replace);
/* Modeless setup guide. Commands: 0 opened, 1 next, 2 back, 3 skip,
 * 4 finish, 5 step action, 6 check again. A revision admits one response. */
typedef void (*jsti_setup_fn)(uint64_t revision, int32_t command, int32_t step, const char *action, void *context);
typedef struct { const char *title; const char *action; } JSTILinuxSetupAction;
typedef struct {
    int32_t step, has_previous, is_last;
    const char *title, *progress, *detail, *status;
} JSTILinuxSetupPage;
int32_t jsti_setup_configure(jsti_setup_fn callback, void *context);
void jsti_setup_clear(void);
uint64_t jsti_setup_revision(void);
int32_t jsti_setup_set_page(
    const JSTILinuxSetupPage *page, const JSTILinuxSetupAction *actions, size_t count, uint64_t revision);
int32_t jsti_setup_finish(uint64_t revision);
int32_t jsti_window_request_setup(void);
/* The dashboard totals (`all` saved records) and the History header totals
 * (`visible`, the records the search shows). */
int32_t jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible);
/* Applies and shows the saved appearance, indexed as JSTI_EVENT_APPEARANCE. */
int32_t jsti_window_set_appearance(int32_t appearance);

#ifdef __cplusplus
}
#endif
#endif
