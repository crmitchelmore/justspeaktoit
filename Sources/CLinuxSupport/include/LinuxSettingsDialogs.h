#ifndef JSTI_LINUX_SETTINGS_DIALOGS_H
#define JSTI_LINUX_SETTINGS_DIALOGS_H
/* About, Troubleshooting, API keys and Permissions. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTIAboutLink {
    const char *title;
    const char *url;
} JSTIAboutLink;
/* Copies metadata and up to eight HTTPS links onto the GTK queue. No update
 * check, download or installation is implied. */
int32_t jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count);
enum {
    JSTI_LINUX_TROUBLESHOOTING_API_KEYS = -1,
    JSTI_LINUX_TROUBLESHOOTING_PERMISSIONS = -2,
    JSTI_LINUX_TROUBLESHOOTING_CHECK = 1,
    JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD = 2,
    JSTI_LINUX_TROUBLESHOOTING_DISABLE_PROCESSING = 3
};
typedef void (*jsti_troubleshooting_fn)(int32_t command, uint64_t revision, void *context);
typedef struct JSTILinuxTroubleshootingRow {
    const char *title;
    const char *detail;
    const char *status;
    const char *navigation_title;
    const char *fix_title;
    int32_t navigation_page;
    int32_t fix_command;
} JSTILinuxTroubleshootingRow;
int32_t jsti_troubleshooting_configure(jsti_troubleshooting_fn callback, void *context);
void jsti_troubleshooting_clear(void);
uint64_t jsti_troubleshooting_revision(void);
/* Copies up to 32 rows onto the GTK queue. Old/closed revisions are ignored.
 * 0 means queued, -1 means invalid input or an unavailable window queue. */
int32_t jsti_troubleshooting_set_rows(const JSTILinuxTroubleshootingRow *rows, size_t count,
                                      const char *summary, uint64_t revision);
enum {
    JSTI_LINUX_API_KEY_REFRESH = 0, JSTI_LINUX_API_KEY_SAVE = 1, JSTI_LINUX_API_KEY_REMOVE = 2,
    JSTI_LINUX_API_KEY_VALIDATE = 3, JSTI_LINUX_API_KEY_CANCEL = 4,
    /* Check balance: carries the dialog's identity instead of a request
     * ticket and no key, and never makes the dialog pending. */
    JSTI_LINUX_API_KEY_BALANCE = 5
};
typedef struct {
    const char *identifier, *label, *uses, *status, *url, *hint;
    int32_t saved;
    /* Bit i set when the row passes SpeakCore APIKeyStatusFilter case i
     * (All, Errors, Set, Unset). */
    uint32_t filters;
} JSTILinuxAPIKeyRow;
/* Keys exist only during this callback and are erased from the native form.
 * Rows returned to GTK contain masked metadata only. */
typedef void (*jsti_api_keys_fn)(int32_t action, const char *request, const char *identifier,
                                const char *key, void *context);
int32_t jsti_api_keys_configure(jsti_api_keys_fn callback, void *context);
void jsti_api_keys_clear(void);
int32_t jsti_api_keys_is_open(void);
int32_t jsti_api_keys_request_is_current(const char *request);
int32_t jsti_window_request_api_keys(void);
int32_t jsti_api_keys_finish(const JSTILinuxAPIKeyRow *rows, size_t count,
                           const char *request, const char *status);
/* Balance text beside one row's key, on its own channel so a slow billing
 * check never holds key entry. Copied onto the GTK queue; host-written text
 * only, never key material. `refreshable` enables Check balance and `result`
 * announces the text when that row is selected. 0 means queued. */
int32_t jsti_api_keys_set_balance(const char *identifier, const char *text, int32_t refreshable, int32_t result);
typedef struct {
    const char *title, *status, *detail, *action;
    int32_t page;
} JSTILinuxPermissionRow;
typedef void (*jsti_permissions_fn)(uint64_t revision, void *context);
int32_t jsti_permissions_configure(jsti_permissions_fn callback, void *context);
void jsti_permissions_clear(void);
uint64_t jsti_permissions_revision(void);
int32_t jsti_window_request_permissions(void);
/* Passive report; no capture, key injection or portal approval is requested. */
int32_t jsti_permissions_set_rows(const JSTILinuxPermissionRow *rows, size_t count,
                                  const char *summary, uint64_t revision);
/* Updates only the saved enabled state, preserving unsaved prompt/model drafts. */
int32_t jsti_window_set_post_processing_enabled(int32_t enabled);

#ifdef __cplusplus
}
#endif
#endif
