#ifndef JSTI_WINDOWS_COMPARISON_H
#define JSTI_WINDOWS_COMPARISON_H
/* Model comparison window. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Comparison actions 100-107. Model rows: id TAB name TAB live(0/1), round rows:
 * id TAB name. Run payload: language LF tab-separated model ids LF file paths.
 * Rank payload: round id LF comma-separated ranks in persisted blind order. */
int jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                           const char *selected, int busy, int recording, int judgeable,
                           int sync_enabled, int sync_available, const char *references, const char *reference);
/* Thread-safe; false refuses hands-free if native lock/sleep observation failed. */
int jsti_window_hands_free_guard_ready(void);
/* Next-file action 128 carries the paused round ID; batch fields share the same presentation snapshot. */
int jsti_comparison_present_batch(const char *models, const char *rounds, const char *detail,
                                 const char *selected, int busy, int recording, int judgeable,
                                 int sync_enabled, int sync_available, const char *references, const char *reference,
                                 const char *batch_round, int batch_remaining, int can_next);
/* "Save results to History" opt-in state; toggling it emits comparison action 129 (index 0/1). */
int jsti_comparison_set_save_history(int enabled);

#ifdef __cplusplus
}
#endif
#endif
