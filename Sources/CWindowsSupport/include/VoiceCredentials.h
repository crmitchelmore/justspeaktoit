#ifndef JSTI_VOICE_CREDENTIALS_H
#define JSTI_VOICE_CREDENTIALS_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* All strings are borrowed for the callback only. Only replace carries a secret.
   open/cancel carry the purpose and request UUID; other fields are empty.
   replace/remove carry the exact canonical slot and selection epoch.
   UUID spelling is case-insensitive; opaque credential slots are exact. */
typedef void (*JSTIVoiceCredentialCallback)(
    const char *operation, const char *purpose, const char *identifier,
    const char *requestID, const char *selectionEpoch, const char *secret, void *context);

int32_t jsti_window_set_voice_credential_handler(JSTIVoiceCredentialCallback callback, void *context);
void jsti_window_clear_voice_credentials(void);

/* -1 saved means unavailable, 0 missing, 1 saved. No secret is returned to UI. */
int32_t jsti_window_set_voice_credential(
    const char *requestID, const char *selectionEpoch, const char *identifier,
    const char *label, const char *privacy, const char *status, int32_t saved, int32_t canSave);
int32_t jsti_window_finish_voice_credential(
    const char *requestID, const char *selectionEpoch, int32_t success, const char *message);

#ifdef __cplusplus
}
#endif
#endif
