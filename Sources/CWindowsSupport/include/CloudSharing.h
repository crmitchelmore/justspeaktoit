#ifndef JSTI_CLOUD_SHARING_H
#define JSTI_CLOUD_SHARING_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* One cloud AI provider, as the host words it. Strings are copied before the
   calls below return. policy_url is an https URL or "" when the provider has none. */
typedef struct JSTICloudSharingRow {
    const char *identifier;
    const char *name;
    const char *detail;
    const char *policy_url;
    /* The accessible name of this provider's Withdraw button. */
    const char *withdraw_label;
} JSTICloudSharingRow;

/* Asks, once, before the first upload to these providers. The window shows title, intro and
   one row per provider with a link to its privacy policy, then reports
   JSTI_EVENT_CLOUD_CONSENT_RESPONSE (WindowsWindowEvents.h / LinuxWindowEvents.h) with
   token as the text and index 1 for allow, 0 for not now. Closing the window answers
   not now. Returns -1 when the window is unavailable, so the host can fail closed. */
int32_t jsti_window_request_cloud_sharing(
    const char *token, const char *title, const char *intro, const JSTICloudSharingRow *rows, size_t count,
    const char *allow_title, const char *not_now_title);

/* The providers the user has allowed. The About page's "Privacy settings…" button opens a
   window of this snapshot; each Withdraw reports JSTI_EVENT_CLOUD_SHARING_WITHDRAW with the
   provider identifier as the text. The host sends a new snapshot after every change, and an
   open window refreshes. Returns -1 for invalid input. */
int32_t jsti_window_set_cloud_sharing(
    const char *title, const char *footer, const char *empty_text, const JSTICloudSharingRow *rows, size_t count);
#ifdef __cplusplus
}
#endif
#endif
