#ifndef JSTI_LINUX_COMPARISON_H
#define JSTI_LINUX_COMPARISON_H
/* The model comparison window: rounds, batches and the save-to-History opt-in. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                               const char *selected, int32_t busy, int32_t recording, int32_t judgeable,
                               int32_t sync_enabled, int32_t sync_available,
                               const char *references, const char *reference);
int32_t jsti_comparison_present_batch(const char *models, const char *rounds, const char *detail,
                                     const char *selected, int32_t busy, int32_t recording, int32_t judgeable,
                                     int32_t sync_enabled, int32_t sync_available,
                                     const char *references, const char *reference,
                                     const char *batch_round, int32_t batch_remaining, int32_t can_next);
/* "Save results to History" opt-in state; toggling it emits comparison action 129 (index 0/1). */
int32_t jsti_comparison_set_save_history(int32_t enabled);

#ifdef __cplusplus
}
#endif
#endif
