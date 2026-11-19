#ifndef JSTI_WINDOWS_SETTINGS_DIALOGS_H
#define JSTI_WINDOWS_SETTINGS_DIALOGS_H
/* Settings dialogs: post-processing, text output, shortcut, voice output, Azure, local models and profiles. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Atomic Apply callback from the native settings dialog, on the UI thread.
 * prompt/new_key are borrowed until return. Empty new_key means keep the saved
 * credential; no saved credential is read back into the password field. */
typedef void (*JSTIPostProcessingCallback)(int enabled, int model_index, int include_directives, int include_tags,
                                          const char *prompt,
                                          const char *new_key, void *context);
/* Thread safe; deep-copies labels/settings. local_index identifies the sole
 * built-in rules entry in the shared projection; -1 selected means unavailable.
 * Callback indexes refer to this full projection, not a filtered picker row.
 * remembered_remote_index is dormant picker recall; -1 requires explicit choice. */
int jsti_window_set_postprocessing(const char *const *model_names, size_t model_count,
                                   int selected_index, int enabled, int local_index, int remembered_remote_index,
                                   const char *local_notice, int include_directives, int include_tags, const char *prompt,
                                   JSTIPostProcessingCallback callback, void *context);

/* Stable text output choices across the native boundary. restore_clipboard is
 * 0/1 and only affects a Smart paste at the cursor; the dialog keeps every
 * stored choice even while it is irrelevant to the selected method. */
enum JSTITextOutputMethod {
    JSTI_TEXT_OUTPUT_SMART = 0,
    JSTI_TEXT_OUTPUT_DIRECT_ONLY = 1,
    JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY = 2
};
enum JSTITextOutputInsertion {
    JSTI_TEXT_OUTPUT_AT_CURSOR = 0,
    JSTI_TEXT_OUTPUT_REPLACE_FIELD = 1
};
/* Atomic Apply from the native Text output dialog, on the UI thread: exactly
 * one complete snapshot per Apply. Cancel, Escape and closing emit nothing.
 * Return promptly; never wait for a Swift actor here. */
typedef void (*JSTITextOutputSettingsCallback)(int method, int insertion, int restore_clipboard, void *context);
/* Thread safe; valid before window_run and from any thread afterwards. Invalid
 * values or a null callback return -1 and keep the previous configuration.
 * The context is borrowed: keep it alive until a later configuration or
 * jsti_window_clear_text_output has replaced it AND any dialog opened from it
 * has closed, because an open dialog keeps its own copy of the callback and
 * context and can still Apply. No dialog is open once window_run returns. The
 * dialog opens from the latest configuration; refresh it with the persisted
 * choices after every save attempt so a reopened dialog never shows unsaved
 * choices. */
int jsti_window_set_text_output(int method, int insertion, int restore_clipboard,
                                JSTITextOutputSettingsCallback callback, void *context);
/* Reads the configuration the dialog will open with. -1 when unconfigured or
 * an output pointer is null. */
int jsti_window_text_output(int *method, int *insertion, int *restore_clipboard);
int jsti_window_set_app_switch(const char *title, const char *labels, int selection, const char *help);
/* During the synchronous Apply callback, reads that dialog's immutable draft. */
int jsti_window_app_switch_selection(void);
/* Thread safe. Drops the configured callback and context so no later dialog
 * can use them; the dialog is unavailable until configured again. A dialog
 * already open is unaffected and keeps its copied callback and context until
 * it closes, so the caller must retain the context until then as well. Once
 * window_run has returned no dialog is open, and clearing ends the borrow. */
void jsti_window_clear_text_output(void);

/* Global recording shortcut. modifiers combine MOD_ALT (1), MOD_CONTROL (2) and
 * MOD_SHIFT (4) and must include Ctrl or Alt; virtual_key is a non-modifier
 * virtual-key code. The Shortcut dialog lists style_names with their
 * descriptions; press_style is the index whose presses toggle recording
 * natively (TOGGLE_RECORDING, or CANCEL_TRANSCRIPTION while transcribing).
 * Every other style reports HOTKEY_DOWN on the press and HOTKEY_UP when the key
 * is released, for the host's gesture recognition; presses while a modal
 * dialog is open or a transcription is running are ignored. The callback runs
 * on the UI thread once per Apply, after the new shortcut is registered;
 * persist it and never wait for a Swift actor there. Thread safe; the
 * combination is registered when window_run starts and afterwards changes only
 * through the dialog. The context is borrowed like jsti_window_set_text_output's. */
typedef void (*JSTIHotKeySettingsCallback)(unsigned modifiers, unsigned virtual_key, int style, void *context);
int jsti_window_set_hotkey(unsigned modifiers, unsigned virtual_key,
                           const char *const *style_names, const char *const *style_descriptions,
                           size_t style_count, int style, int press_style,
                           JSTIHotKeySettingsCallback callback, void *context);
/* Drops the callback and context; the dialog is unavailable until configured again. */
void jsti_window_clear_hotkey(void);
/* UI thread only, from a hotkey event: arms the one gesture deadline timer,
 * which later sends HOTKEY_DEADLINE. Negative milliseconds cancel it. */
int jsti_window_set_hotkey_deadline(int milliseconds);
/* Voice output dialog: the canonical voices the host can speak with, as
 * UTF-8 labels, and the selected index. The callback runs on the UI thread
 * once per Apply with the chosen index. Thread safe; the context is borrowed
 * like jsti_window_set_text_output's. */
typedef void (*JSTIVoiceOutputCallback)(int voice, void *context);
int jsti_window_set_voice_output(const char *const *voice_names, size_t voice_count, int selected,
                                 JSTIVoiceOutputCallback callback, void *context);
void jsti_window_clear_voice_output(void);
/* Azure Speech resource dialog: the HTTPS endpoint of the user's Azure Speech
 * or Foundry resource, shown and edited as UTF-8 text (empty when none is
 * saved). Azure live transcription connects only to that resource; recorded
 * audio uses it when set. The callback runs on the UI thread once per Apply
 * with the entered text. It validates synchronously, never waiting for a Swift
 * actor, and returns 0 to accept, which closes the dialog, or -1 after writing
 * a readable reason into error, which the dialog shows while it stays open.
 * Thread safe; the context is borrowed like the voice dialog's. */
typedef int (*JSTIAzureResourceCallback)(const char *endpoint, void *context, char *error, size_t error_capacity);
int jsti_window_set_azure_resource(const char *endpoint, JSTIAzureResourceCallback callback, void *context);
void jsti_window_clear_azure_resource(void);
/* Local models dialog: rows of the on-device models the host offers, in the
 * host's order, with their install state. Thread safe; an open dialog refreshes
 * in place. The callback runs on the UI thread with one action and the row
 * index (-1 for the GPU choice); it must return promptly and never block on a
 * Swift actor. The runtime status is also shown under the model picker while
 * the Local source is selected. The context is borrowed like the voice
 * dialog's. */
enum JSTILocalModelState {
    JSTI_LOCAL_MODEL_NOT_INSTALLED = 0,
    JSTI_LOCAL_MODEL_PARTIAL = 1,
    JSTI_LOCAL_MODEL_DOWNLOADING = 2,
    JSTI_LOCAL_MODEL_INSTALLED = 3
};
enum JSTILocalModelAction {
    JSTI_LOCAL_MODEL_DOWNLOAD = 1,
    JSTI_LOCAL_MODEL_CANCEL = 2,
    JSTI_LOCAL_MODEL_REMOVE = 3,
    JSTI_LOCAL_MODEL_GPU_ON = 4,
    JSTI_LOCAL_MODEL_GPU_OFF = 5
};
typedef struct JSTILocalModelRow {
    const char *name;
    const char *detail;
    const char *about;
    int state;
} JSTILocalModelRow;
typedef void (*JSTILocalModelCallback)(int action, int model_index, void *context);
/* Borrowed strings, copied by the callback before returning. cancel != 0
 * cancels only metadata discovery, not an installed model or download. */
typedef void (*JSTILocalModelImportCallback)(const char *repository, const char *filename, int cancel, void *context);
void jsti_window_set_local_model_import_callback(JSTILocalModelImportCallback callback);
int jsti_window_set_local_models(const JSTILocalModelRow *rows, size_t count, const char *runtime_status,
                                 int use_gpu, JSTILocalModelCallback callback, void *context);
void jsti_window_clear_local_models(void);
/* Thread safe: checks or clears the Settings menu's automation item. */
int jsti_window_set_automation(int enabled);
/* Thread safe: General's Launch at login switch shows the shared
 * DesktopLoginItemState (0 off, 1 on, 2 off by the system, 3 on by policy,
 * 4 unavailable); only 0 and 1 can be changed there. `detail` is the note. */
int jsti_window_set_login_item(int state, const char *detail);

/* Launch at login (WindowsLoginItem.cpp). The portable app registers
 * `"<exe>" --background` under HKCU\...\Run and honours Task Manager's
 * StartupApproved switch; the MSIX app uses its declared windows.startupTask.
 * Both may block for a few seconds: never call them on the UI thread. state
 * and `reached` are the shared DesktopLoginItemState. */
int jsti_login_item_state(void);
int jsti_login_item_set(int enabled, int *reached, char *error, size_t error_capacity);
/* 1 when this process was started with the login argument (--background). */
int jsti_login_item_launched(void);
/* Portable: registers, disables as Task Manager does, re-enables and removes a
 * Run value of its own, never the user's. Packaged: reads the startup task,
 * and turns it on and off again only when it is plainly off. */
int jsti_login_item_self_test(char *error, size_t error_capacity);
/* The localised key name, for example "Ctrl+Alt+Space". */
int jsti_hotkey_name(unsigned modifiers, unsigned virtual_key, char *name, size_t capacity);

/* Borrowed UTF-8 draft values. Choice -1 inherits the app setting, -2 preserves
 * an existing unavailable value, otherwise indexes the supplied catalogue.
 * polish_mode: 0 inherit, 1 disabled, 2 enabled. Paths are newline-separated. */
typedef struct JSTIProfileDraft {
    const char *id, *name, *paths, *prompt, *output_language, *notes;
    int transcription, polish_mode, polish_model, language;
} JSTIProfileDraft;
/* UI-thread callback: action 1 validates/copies all drafts for an atomic save;
 * return -1 with a readable error to keep the editor open. Action 0 cancels.
 * All pointers expire on return. Never block waiting for a Swift actor. */
typedef int (*JSTIProfilesCallback)(int action, const JSTIProfileDraft *drafts, size_t count,
                                  void *context, char *error, size_t error_capacity);
int jsti_window_set_profiles(const JSTIProfileDraft *drafts, size_t count,
                            const char *const *transcription_names, size_t transcription_count,
                            const char *const *polish_names, size_t polish_count,
                            const char *const *language_names, size_t language_count,
                            const char *notice,
                            JSTIProfilesCallback callback, void *context);
/* Posts an open request to the native UI thread. Ignored during recording. */
void jsti_window_request_profiles(void);

#ifdef __cplusplus
}
#endif
#endif
