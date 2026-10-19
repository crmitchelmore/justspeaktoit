#ifndef JSTI_LINUX_ATSPI_H
#define JSTI_LINUX_ATSPI_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct JSTIAtspiTarget JSTIAtspiTarget;
/* Only the affirmative native dialog issues an offer. Stop synchronously
 * revokes and advances the generation before its Host action is queued. */
uint64_t jsti_atspi_offer_local_consent(void);
uint64_t jsti_atspi_revoke_local_consent(void);
int32_t jsti_atspi_consent_action_is_current(int32_t allowed, uint64_t token);
/* Consent is local to this process. Neither call waits for accessibility IPC. */
/* Zero token is allowed ONLY for unconditional local revocation, never grant. */
int32_t jsti_atspi_observational_consent(int32_t allowed, uint64_t token);
/* 0 off, 1 connecting, 2 ready, 3 unavailable, 4 cleanup failure,
 * 5 unsupported registry schema. Cached metadata only. */
int32_t jsti_atspi_observational_status(void);
/* Clones only an already-admitted focused control; never probes focus here. */
JSTIAtspiTarget *jsti_atspi_capture(void);
int32_t jsti_atspi_is_current(JSTIAtspiTarget *target);
void jsti_atspi_cancel(JSTIAtspiTarget *target);
void jsti_atspi_release(JSTIAtspiTarget *target);
/* 0 unavailable BEFORE dispatch; 1 observational span; -1 indeterminate AFTER
 * dispatch. A caller must never retry/paste after -1. This is never an ACK. */
int32_t jsti_atspi_insert(JSTIAtspiTarget *target, const char *text);
int32_t jsti_atspi_begin(JSTIAtspiTarget *target, const char *original);
int32_t jsti_atspi_read(JSTIAtspiTarget *target, char *output, size_t capacity);
/* Pure fixtures: no bus, UI, services or field access. */
int32_t jsti_atspi_contract_self_test(void);
int32_t jsti_vocabulary_learning_controls_contract_self_test(void);
#ifdef __cplusplus
}
#endif
#endif
