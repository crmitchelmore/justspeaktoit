#ifndef JSTI_ONBOARDING_H
#define JSTI_ONBOARDING_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* First-run guide and Permissions windows. Both are modeless and owned by the
 * main window, so the recording shortcut keeps working while they are open.
 * The host supplies their content; the steps and wording are SpeakCore's
 * DesktopOnboardingStep and DesktopPermissionItem. UTF-8 strings throughout,
 * borrowed for the call and copied before it returns. */

/* What a guide button does. Native actions run in the adapter and are then
 * reported as JSTI_GUIDE_COMMAND_ACTION so the host can refresh the status;
 * HOST actions are only reported, for the host to perform. */
enum JSTIGuideAction {
    JSTI_GUIDE_ACTION_NONE = 0,
    JSTI_GUIDE_ACTION_MICROPHONE_PRIVACY = 1, /* ms-settings:privacy-microphone */
    JSTI_GUIDE_ACTION_MICROPHONE_PICKER = 2,  /* General page, where the microphone is chosen */
    JSTI_GUIDE_ACTION_TEXT_OUTPUT = 3,
    JSTI_GUIDE_ACTION_HOST_API_KEYS = 4,
    JSTI_GUIDE_ACTION_LOCAL_MODELS = 5,
    JSTI_GUIDE_ACTION_SHORTCUT = 6,
    JSTI_GUIDE_ACTION_TEST_DICTATION = 7,     /* starts or stops a recording, as the tray does */
    JSTI_GUIDE_ACTION_POST_PROCESSING = 8,
    JSTI_GUIDE_ACTION_PERMISSIONS = 9
};

enum JSTIGuideCommand {
    JSTI_GUIDE_COMMAND_OPENED = 0, /* the window opened; the host sends its page */
    JSTI_GUIDE_COMMAND_ACTION = 1, /* value: the JSTIGuideAction */
    JSTI_GUIDE_COMMAND_BACK = 2,
    JSTI_GUIDE_COMMAND_NEXT = 3,
    JSTI_GUIDE_COMMAND_SKIP = 4,   /* Skip setup: completes the guide */
    JSTI_GUIDE_COMMAND_FINISH = 5
};

typedef struct JSTIGuidePage {
    int32_t step;          /* echoed in callbacks; stale clicks name an old step */
    const char *title;
    const char *progress;  /* "Step 2 of 7" */
    const char *detail;
    const char *status;    /* live state, for example the selected model; may be empty */
    const char *first_title, *second_title, *third_title; /* empty hides the button */
    int32_t first_action, second_action, third_action;     /* JSTIGuideAction */
    int32_t has_previous;
    int32_t is_last;
    int32_t is_optional;
} JSTIGuidePage;

/* UI thread. step is the displayed page's step; value as the command says. */
typedef void (*JSTIGuideCallback)(int32_t command, int32_t step, int32_t value, void *context);

int32_t jsti_guide_configure(JSTIGuideCallback callback, void *context);
/* Forgets the callback before its context is released. */
void jsti_guide_clear(void);
/* Thread safe. Replaces the displayed page. */
int32_t jsti_guide_set_page(const JSTIGuidePage *page);
/* Thread safe. Updates the status line only while step is still displayed. */
int32_t jsti_guide_set_status(int32_t step, const char *status);
/* Thread safe. Opens the guide, or brings it forward. */
void jsti_window_request_guide(void);

/* Permissions page. remediation names the system page the row's button opens. */
enum JSTISettingsPage {
    JSTI_SETTINGS_NONE = 0,
    JSTI_SETTINGS_MICROPHONE = 1,    /* ms-settings:privacy-microphone */
    JSTI_SETTINGS_NOTIFICATIONS = 2, /* ms-settings:notifications */
    JSTI_SETTINGS_STARTUP_APPS = 3,  /* ms-settings:startupapps */
    JSTI_SETTINGS_TEXT_OUTPUT = 4,   /* the app's own Text output dialog */
    JSTI_SETTINGS_GENERAL = 5        /* the app's General page */
};

typedef struct JSTIPermissionRow {
    const char *title;
    const char *status;      /* "Allowed", "Blocked", ... */
    const char *detail;      /* what was observed */
    const char *guidance;    /* plain-language help */
    const char *remediation; /* button title; empty when nothing can be opened */
    int32_t settings_page;   /* JSTISettingsPage */
    int32_t blocking;
} JSTIPermissionRow;

enum JSTIPermissionsCommand {
    JSTI_PERMISSIONS_COMMAND_CHECK = 1 /* opened, Check again, or back from a settings page */
};
typedef void (*JSTIPermissionsCallback)(int32_t command, void *context);

int32_t jsti_permissions_configure(JSTIPermissionsCallback callback, void *context);
void jsti_permissions_clear(void);
/* Thread safe. summary is the recheck result shown under the list. */
int32_t jsti_permissions_set_rows(const JSTIPermissionRow *rows, size_t count, const char *summary);
/* Thread safe. Opens the Permissions window, or brings it forward. */
void jsti_window_request_permissions(void);

enum JSTITroubleshootingCommand {
    JSTI_TROUBLESHOOTING_CHECK = 1,
    JSTI_TROUBLESHOOTING_GENERAL = 2,
    JSTI_TROUBLESHOOTING_API_KEYS = 3,
    JSTI_TROUBLESHOOTING_SHORTCUTS = 4,
    JSTI_TROUBLESHOOTING_PERMISSIONS = 5,
    JSTI_TROUBLESHOOTING_KEEP_CLIPBOARD = 6,
    JSTI_TROUBLESHOOTING_DISABLE_PROCESSING = 7
};
typedef struct JSTITroubleshootingRow {
    const char *title;
    const char *status;
    const char *detail;
    const char *navigation_title;
    const char *fix_title;
    int32_t navigation_command;
    int32_t fix_command; /* zero means no explicit Fix now action */
    int32_t blocking;
} JSTITroubleshootingRow;
int32_t jsti_troubleshooting_configure(JSTIPermissionsCallback callback, void *context);
void jsti_troubleshooting_clear(void);
uint64_t jsti_troubleshooting_revision(void);
/* Returns 1 for a superseded/closed check, 0 on publication, -1 on invalid input. */
int32_t jsti_troubleshooting_set_rows(
    const JSTITroubleshootingRow *rows, size_t count, const char *summary, uint64_t revision);

/* Live system state; each field is 1 allowed/on, 0 denied/off, -1 unknown. */
typedef struct JSTISystemPermissions {
    int32_t microphone_device; /* "Microphone access" for this device (administrator) */
    int32_t microphone_user;   /* "Microphone access" for this account */
    int32_t microphone_app;    /* desktop apps, or this package when packaged */
    int32_t microphone_policy; /* 0 when policy forces deny, 1 forces allow, -1 no policy */
    int32_t packaged;
    int32_t elevated;
    int32_t notifications;     /* Windows notifications for this account */
} JSTISystemPermissions;

/* Registry and token reads only; never prompts. Zero on success. */
int32_t jsti_system_permissions(JSTISystemPermissions *permissions);
/* Opens a JSTI_SETTINGS_* system page (1-3). Zero when the shell accepted it. */
int32_t jsti_open_system_settings(int32_t page);

#ifdef __cplusplus
}
#endif
#endif
