#ifndef JSTI_WINDOWS_WINDOW_EVENTS_H
#define JSTI_WINDOWS_WINDOW_EVENTS_H
/* Window events, the event callback and the corrections editor. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Corrections/pronunciation editor; events 70 (action), 71 (load), index 0/1;
 * event 72 reads a selected recording's correction snapshot (kind 2).
 * Kind 4 edits the separate legacy word-to-pronunciation preference map.
 * Escaped UTF-8 field contract lives in DesktopVocabularyWire. */
int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh);

/* UTF-8 strings throughout. Zero is success; -1 is failure with a caller-owned
 * error buffer. No API logs credential or transcript contents. Windows only. */
enum JSTIWindowEvent {
    JSTI_EVENT_TOGGLE_RECORDING = 1,
    JSTI_EVENT_IMPORT_AUDIO = 2,
    JSTI_EVENT_COPY_TRANSCRIPT = 3,
    JSTI_EVENT_SAVE_CREDENTIAL = 4,
    JSTI_EVENT_MODEL_CHANGED = 5,
    JSTI_EVENT_CLOSING = 6,
    JSTI_EVENT_READY = 7,
    JSTI_EVENT_ERROR = 8,
    JSTI_EVENT_HISTORY_SELECTED = 9,
    JSTI_EVENT_HISTORY_RETRY = 10,
    JSTI_EVENT_HISTORY_EXPORT = 11,
    JSTI_EVENT_HISTORY_OPEN_AUDIO = 12,
    JSTI_EVENT_MICROPHONE_CHANGED = 13,
    JSTI_EVENT_CANCEL_TRANSCRIPTION = 14,
    JSTI_EVENT_HISTORY_SEARCH = 15,
    JSTI_EVENT_TRANSCRIPT_VARIANT = 16,
    /* Native History playback controls; both carry the selected record ID. */
    JSTI_EVENT_HISTORY_PLAY_PAUSE = 18,
    JSTI_EVENT_HISTORY_STOP = 19,
    JSTI_EVENT_REFRESH_MODELS = 20,
    /* Gesture activation styles only (see jsti_window_set_hotkey). DOWN carries
     * the selected microphone ID like TOGGLE_RECORDING; UP and DEADLINE carry
     * no text. A press-to-toggle style keeps sending TOGGLE_RECORDING. */
    JSTI_EVENT_HOTKEY_DOWN = 21,
    JSTI_EVENT_HOTKEY_UP = 22,
    JSTI_EVENT_HOTKEY_DEADLINE = 23,
    /* Carries the selected record ID; read the displayed transcript with
     * jsti_window_transcript_snapshot synchronously in the callback, as for Copy. */
    JSTI_EVENT_HISTORY_READ_ALOUD = 24,
    /* General's automation switch: text is "1" to allow automation and "0" to
     * stop it. Report the state reached with jsti_window_set_automation. */
    JSTI_EVENT_AUTOMATION_TOGGLED = 25,
    /* General > Theme changed. text: "0" follow Windows, "1" light, "2" dark. */
    JSTI_EVENT_APPEARANCE = 26,
    /* General's Launch at login switch: text "1" on, "0" off. The switch stays
     * disabled until jsti_window_set_login_item reports the state reached. */
    JSTI_EVENT_LOGIN_ITEM = 27,
    JSTI_EVENT_HISTORY_FILTERS = 90, /* text: DesktopHistoryFilter JSON */
    JSTI_EVENT_HISTORY_DELETE = 91, /* text: frozen newline-separated UUIDs; index: 1 removes owned audio */
    JSTI_EVENT_RECORDINGS_FOLDER = 93,
    JSTI_EVENT_AUDIO_CLEANUP = 94,
    JSTI_EVENT_AUDIO_CLEANUP_RESPONSE = 95, /* text: confirmation UUID; index: 1 confirms, 0 cancels */
    JSTI_EVENT_MIGRATION_EXPORT = 96, /* text: ZIP destination; index bits: 1 saved audio, 2 app profiles */
    JSTI_EVENT_MIGRATION_INSPECT = 97, /* text: selected ZIP source; no application changes */
    JSTI_EVENT_MIGRATION_RESTORE = 98, /* text: selected ZIP source; prepares a preview only */
    JSTI_EVENT_MIGRATION_RESTORE_RESPONSE = 99, /* text: preview token; index: 0 cancel, 1 merge, 2 replace */
    JSTI_EVENT_QUICK_VOICE = 110, /* text: favorite slot "1"-"3" from an action shortcut */
    /* Paste Last History Item shortcut; capture the insertion target in the callback. */
    JSTI_EVENT_PASTE_LAST_HISTORY = 111,
    JSTI_EVENT_SPEAK_SELECTED_TEXT = 112,
    JSTI_EVENT_SPEAK_CLIPBOARD = 113,
    JSTI_EVENT_VOICE_EDIT = 114,
    JSTI_EVENT_SPEECH_PAUSE = 116, /* exact active speech only; never starts History audio */
    JSTI_EVENT_USER_ABSENT = 131, /* Outside comparison events 100-109 and 120-129. */
    JSTI_EVENT_HISTORY_ISSUE_REPORT = 150, /* Exact selected History ID. */
    JSTI_EVENT_ISSUE_REPORT_INCLUDE = 151, /* ticket; index 0/1. */
    JSTI_EVENT_ISSUE_REPORT_COPY = 152, /* ticket. */
    JSTI_EVENT_ISSUE_REPORT_SAVE = 153,
    JSTI_EVENT_ISSUE_REPORT_OPEN = 154,
    JSTI_EVENT_ISSUE_REPORT_CLOSE = 155,
    /* The History list's last row scrolled into view; no text. */
    JSTI_EVENT_HISTORY_LOAD_MORE = 156,
    /* Settings search box (160-161 were unused): SETTINGS_SEARCH carries the whole
     * query on every edit and when the empty box gains focus (answer with recent
     * destinations); reply with jsti_window_set_settings_search_results.
     * SETTINGS_SEARCH_OPEN: model_index is the chosen row of the last results and
     * text its identifier; the box has already been cleared and closed. */
    JSTI_EVENT_SETTINGS_SEARCH = 160,
    JSTI_EVENT_SETTINGS_SEARCH_OPEN = 161
};

/* Runs on the UI thread. text is borrowed until callback returns. model_index
 * is the selected caller-supplied model. READY is sent after controls exist.
 * COPY_TRANSCRIPT carries the selected history ID, or empty if none is selected.
 * MICROPHONE_CHANGED and TOGGLE_RECORDING carry the selected microphone ID;
 * empty selects the default communications microphone. HISTORY_SEARCH carries
 * the current search text (empty when cleared); the host filters the rows it
 * supplies through jsti_window_set_history. TRANSCRIPT_VARIANT carries the
 * selected record ID after the user chose a transcript version; pair it with
 * jsti_window_transcript_variant() synchronously inside the callback. */
typedef void (*JSTIWindowCallback)(int event, const char *text, int model_index, void *context);

#ifdef __cplusplus
}
#endif
#endif
