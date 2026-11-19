#ifndef JSTI_WINDOWS_GENERAL_SETTINGS_H
#define JSTI_WINDOWS_GENERAL_SETTINGS_H
/* General settings: local model preferences, CLI and MCP setup, capture prewarm, app visibility, API keys and action shortcuts. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The saved on-device live row (mode 3) restored when the user picks Local and
 * Live. Call after jsti_window_set_model_modes, which clears it, and before
 * window_run. -1 chooses the first local live row. Returns -1 when the index is
 * not a configured mode-3 row or the window is running. */
int jsti_window_set_preferred_local_live_model(int index);
/* Thread-safe inactive Local preferences; -1 leaves a slot unchanged.
 * Does not change the active model, populate a picker or emit a callback. */
int jsti_window_set_local_model_preferences(int batch, int live);

/* General > CLI and MCP setup dialog: the automation pipe name, the installed
 * speak.exe path (empty when it is not beside the app) and the copyable
 * `speak` usage, MCP client configuration and Claude Code command built by the
 * host. Text only: no credential passes through. Thread safe; -1 for a NULL,
 * oversized (over 16 KiB) or invalid UTF-8 field. The dialog's on/off button
 * emits JSTI_EVENT_AUTOMATION_TOGGLED exactly as General's switch does. */
int jsti_window_set_automation_details(const char *pipe_name, const char *cli_path, const char *usage,
                                       const char *mcp_configuration, const char *claude_command);
/* The installed `speak` command as UTF-8: speak.exe beside the app for the
 * portable bundle, or the package's CLI execution alias for the MSIX. 1 when
 * found, 0 (empty buffer) when absent, -1 for a NULL/zero or too-small buffer. */
int jsti_automation_cli_path(char *buffer, size_t capacity);

/* Idle capture preparation (WindowsCapturePrewarm.cpp). A worker resolves and
 * validates the endpoint and keeps the device enumerator resident for at most
 * lifetime_milliseconds. It never activates an audio client: no stream opens,
 * no audio is read and the microphone indicator stays off. Create never
 * blocks on the device; destroy signals and joins the worker. State: 0
 * preparing, 1 ready, 2 lifetime ended, -1 unavailable. */
typedef struct JSTICapturePrewarm JSTICapturePrewarm;
JSTICapturePrewarm *jsti_capture_prewarm_create(const char *device_id, uint32_t lifetime_milliseconds,
                                                char *error, size_t error_capacity);
int jsti_capture_prewarm_state(JSTICapturePrewarm *prewarm);
void jsti_capture_prewarm_destroy(JSTICapturePrewarm *prewarm);

/* General > App visibility: visibility is the shared DesktopAppVisibility
 * order, 0 taskbar and notification area, 1 notification area only, 2 taskbar
 * only. With 1 the window has no taskbar button and closing or minimising it
 * hides it to the notification-area icon; Quit still exits. A notification
 * area that cannot be reached keeps the taskbar button, so the window is never
 * unreachable. compact 1 shows state by the icon only: a plain tooltip and no
 * totals line in its menu. Safe before or while the window runs; -1 for an
 * invalid value. */
int jsti_window_set_shell(int visibility, int compact);

/* API keys dialog. Rows never carry a secret: `status` is host-written text
 * such as "Saved" plus a masked suffix, `url` is empty or an https provider key page.
 * The callback runs on the UI thread with a borrowed identifier and, for
 * save/validate, the typed key or NULL (validate the stored key); the dialog
 * wipes its copies after the call returns, so the host must copy what it
 * keeps. The dialog stays busy until the next jsti_window_set_api_keys. */
enum JSTIAPIKeyAction {
    JSTI_API_KEY_SAVE = 1,
    JSTI_API_KEY_REMOVE = 2,
    JSTI_API_KEY_VALIDATE = 3,
    /* Sent with an empty identifier as the dialog opens: keys saved from the
     * Transcription or Voice editors since the last refresh show at once. */
    JSTI_API_KEY_REFRESH = 4,
    /* Check balance on the selected row: sent without a key and without
     * making the dialog busy, so key entry never waits on a billing check. */
    JSTI_API_KEY_BALANCE = 5
};
typedef struct JSTIAPIKeyRow {
    const char *identifier;
    const char *label;
    const char *uses;
    const char *status;
    const char *url;
    const char *hint;
    int saved;
    /* Bit i set when the row passes SpeakCore APIKeyStatusFilter case i
     * (All, Errors, Set, Unset). */
    uint32_t filters;
} JSTIAPIKeyRow;
typedef void (*JSTIAPIKeyCallback)(int action, const char *identifier, const char *key, void *context);
/* Copies the rows; `context` is borrowed until cleared or replaced. */
int jsti_window_set_api_keys(const JSTIAPIKeyRow *rows, size_t count, const char *status,
                             JSTIAPIKeyCallback callback, void *context);
void jsti_window_clear_api_keys(void);
/* Balance text beside one row's key, kept apart from the rows so a slow
 * billing check never holds key entry. Thread safe; the text is host-written
 * and never carries key material. `refreshable` enables Check balance and
 * `result` announces the text when that row is selected. */
int jsti_window_set_api_key_balance(const char *identifier, const char *text, int refreshable, int result);
/* Opens the dialog over the main window when idle (onboarding entry hook). */
void jsti_window_request_api_keys(void);

/* ---- Action shortcuts ----------------------------------------------------
 * The Mac's individual action shortcuts (SpeakCore DesktopShortcutAction), one
 * row per catalogue action in catalogue order. `run` says how Windows performs
 * the action; -1 keeps the row stored for the Mac without running it here.
 * Rows run inside this window, or system-wide through RegisterHotKey when
 * `global` and `can_be_global` are set and the combination includes Ctrl or
 * Alt (or is F13-F24 alone). Modifiers are JSTI hotkey modifiers:
 * Alt 1, Ctrl 2, Shift 4. A zero virtual key has no Windows equivalent. */
enum {
    JSTI_ACTION_RUN_NONE = -1,
    JSTI_ACTION_RUN_RECORD = 1,      /* as the Record button */
    JSTI_ACTION_RUN_PAGE = 2,        /* shows `page`, a sidebar page name */
    JSTI_ACTION_RUN_PLAY_PAUSE = 3,  /* pause/resume the active speech, independent of History selection */
    JSTI_ACTION_RUN_STOP_SPEECH = 4, /* as Stop on History or Voice Output */
    JSTI_ACTION_RUN_API_KEYS = 5,    /* as Transcription's All API keys button */
    JSTI_ACTION_RUN_PERMISSIONS = 6, /* as About's Permissions button */
    JSTI_ACTION_RUN_COMPARE = 7,     /* as Transcription's Compare models button */
    JSTI_ACTION_RUN_QUICK_VOICE_1 = 8, /* JSTI_EVENT_QUICK_VOICE for favorite slot 1 */
    JSTI_ACTION_RUN_QUICK_VOICE_2 = 9,
    JSTI_ACTION_RUN_QUICK_VOICE_3 = 10,
    JSTI_ACTION_RUN_PASTE_LAST_HISTORY = 11, /* JSTI_EVENT_PASTE_LAST_HISTORY */
    JSTI_ACTION_RUN_SPEAK_SELECTED_TEXT = 12,
    JSTI_ACTION_RUN_SPEAK_CLIPBOARD = 13,
    JSTI_ACTION_RUN_TROUBLESHOOTING = 14,
    JSTI_ACTION_RUN_VOICE_EDIT = 15
};
typedef struct {
    const char *identifier;
    const char *title;
    const char *note;  /* why Windows does not run it, or NULL */
    const char *page;  /* JSTI_ACTION_RUN_PAGE only */
    int run;
    unsigned modifiers;
    unsigned virtual_key;
    int enabled;
    int global;
    int can_be_global;
} JSTIActionShortcut;
/* Validates the dialog's rows on the UI thread and, when commit is 1, saves
 * them; never wait for a Swift actor here. Returns 0 to accept (message may
 * carry warnings, one per line) or -1 to refuse with message. */
typedef int (*JSTIActionShortcutsCallback)(const JSTIActionShortcut *rows, size_t count, int commit,
                                           char *message, size_t capacity, void *context);
/* Runs on the UI thread when an imported configuration may have changed the
 * bindings; the host reads its settings and configures again. */
typedef void (*JSTIActionShortcutsRefresh)(void *context);
/* Thread safe; strings are copied. preset_rows holds preset_count blocks of
 * `count` rows in the same order; only their keys and flags are read. Running
 * windows re-register at once; failures are reported on the status line and
 * in the dialog. The context is borrowed like jsti_window_set_text_output's. */
int jsti_window_set_action_shortcuts(const JSTIActionShortcut *rows, size_t count,
                                     const char *const *preset_names, const JSTIActionShortcut *preset_rows,
                                     size_t preset_count, JSTIActionShortcutsCallback callback,
                                     JSTIActionShortcutsRefresh refresh, void *context);
/* Unregisters every action shortcut and drops the callbacks and context. */
void jsti_window_clear_action_shortcuts(void);
/* Runs one action as its shortcut would (JSTI_ACTION_RUN_*; `page` names the
 * sidebar page for JSTI_ACTION_RUN_PAGE and may be NULL otherwise), on the UI
 * thread after pending messages, for the command palette. Disabled controls
 * stay disabled. Thread safe; -1 for an unknown run or no window. */
int jsti_window_run_action(int run, const char *page);

#ifdef __cplusplus
}
#endif
#endif
