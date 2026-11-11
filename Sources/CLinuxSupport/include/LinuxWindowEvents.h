#ifndef JSTI_LINUX_WINDOW_EVENTS_H
#define JSTI_LINUX_WINDOW_EVENTS_H
/* Events the window reports, recording states and the event callback. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Events the window reports on the GTK main thread. Values match Windows. */
enum {
    JSTI_EVENT_TOGGLE_RECORDING = 1, /* text: microphone id, index: model slot */
    JSTI_EVENT_IMPORT = 2,           /* text: path, index: model slot */
    JSTI_EVENT_COPY = 3,
    JSTI_EVENT_SAVE_KEY = 4,         /* text: key, index: model slot */
    JSTI_EVENT_SELECT_MODEL = 5,     /* index: model slot */
    JSTI_EVENT_CLOSING = 6,
    JSTI_EVENT_READY = 7,
    JSTI_EVENT_SELECT_HISTORY = 9,   /* text: record id */
    JSTI_EVENT_RETRY_HISTORY = 10,   /* text: record id */
    JSTI_EVENT_EXPORT_HISTORY = 11,  /* text: destination path */
    JSTI_EVENT_OPEN_AUDIO = 12,      /* text: record id */
    JSTI_EVENT_SELECT_MICROPHONE = 13,
    JSTI_EVENT_CANCEL = 14,
    JSTI_EVENT_SEARCH_HISTORY = 15,  /* text: query */
    JSTI_EVENT_TRANSCRIPT_VERSION = 16, /* text: record id */
    JSTI_EVENT_PLAYBACK_TOGGLE = 18, /* text: record id */
    JSTI_EVENT_PLAYBACK_STOP = 19,
    JSTI_EVENT_REFRESH_MODELS = 20,
    JSTI_EVENT_SHORTCUT_PRESSED = 21,  /* text: microphone id, index: model slot */
    JSTI_EVENT_SHORTCUT_RELEASED = 22,
    JSTI_EVENT_TEXT_OUTPUT = 30,       /* index: method, text: "restore" or "" */
    JSTI_EVENT_COMMAND_TOGGLE = 31,    /* --toggle from another process or action */
    JSTI_EVENT_SHORTCUT_STYLE = 32,    /* index: 0 press, 1 hold, 2 double-tap, 3 hold and double-tap */
    /* Apply in Post-processing. index: full-catalog model index, or -1 - index when
     * disabled; text: percent-encoded prompt<TAB>percent-encoded new key<TAB>
     * directives 0/1<TAB>context tags 0/1. Local sends no key. */
    JSTI_EVENT_POST_PROCESSING = 33,
    /* Apply in Azure Speech resource. text: the endpoint as typed ("" clears). */
    JSTI_EVENT_AZURE_RESOURCE = 34,
    JSTI_EVENT_HISTORY_FILTERS = 90, /* text: DesktopHistoryFilter JSON */
    JSTI_EVENT_HISTORY_DELETE = 91, /* text: frozen newline-separated UUIDs; index: 1 removes owned audio */
    JSTI_EVENT_RECORDINGS_FOLDER = 93,
    JSTI_EVENT_AUDIO_CLEANUP = 94,
    JSTI_EVENT_AUDIO_CLEANUP_RESPONSE = 95, /* text: confirmation UUID; index: 1 confirms, 0 cancels */
    JSTI_EVENT_MIGRATION_EXPORT = 96, /* text: ZIP destination; index bits: 1 saved audio, 2 app profiles */
    JSTI_EVENT_MIGRATION_INSPECT = 97, /* text: selected ZIP source; no application changes */
    JSTI_EVENT_MIGRATION_RESTORE = 98, /* text: selected ZIP source; prepares a preview only */
    JSTI_EVENT_MIGRATION_RESTORE_RESPONSE = 99, /* text: preview token; 0 cancel, 1 merge, 2 replace profiles */
    JSTI_EVENT_QUICK_VOICE = 110, /* index: canonical favorite slot 1...3 */
    JSTI_EVENT_PASTE_LAST_HISTORY = 111, /* capture the invocation target before queueing */
    JSTI_EVENT_SPEAK_CLIPBOARD = 113, /* captures through the owned Host speech task, not History */
    JSTI_EVENT_ACTION_SHORTCUT_EDIT = 115, /* revision/request header, then percent-escaped draft rows */
    JSTI_EVENT_SPEECH_PAUSE = 116, /* exact active speech only; never starts History audio */
    JSTI_EVENT_API_KEYS = 117,
    JSTI_EVENT_PERMISSIONS = 118,
    JSTI_EVENT_SPEAK_SELECTED_TEXT = 130, /* captures a selection-only invocation receipt before queueing */
    /* Profiles: percent-escaped TAB fields, starting with revision/action/UUID;
     * "refresh" opens a new immutable catalogue/editor revision. */
    JSTI_EVENT_HISTORY_ISSUE_REPORT = 150, /* text: exact clicked visible History UUID */
    JSTI_EVENT_ISSUE_REPORT_INCLUDE = 151, /* text: preview UUID; index: included */
    JSTI_EVENT_ISSUE_REPORT_COPY = 152,
    JSTI_EVENT_ISSUE_REPORT_SAVE = 153,
    JSTI_EVENT_ISSUE_REPORT_OPEN = 154,
    JSTI_EVENT_ISSUE_REPORT_CLOSE = 155,
    JSTI_EVENT_HISTORY_LOAD_MORE = 156, /* the History page scrolled to its end; no text */
    JSTI_EVENT_PROFILES = 140
};

/* Read aloud, Appearance, Launch at login, automation and the recordings
 * location. Linux-only numbers 40-48. */
enum {
    /* text: the selected record id; the displayed transcript is captured
     * with jsti_window_transcript_snapshot while this event runs. */
    JSTI_EVENT_READ_ALOUD = 40,
    JSTI_EVENT_VOICE_OUTPUT = 41, /* index: position in the voice list */
    /* General › Appearance. index: 0 system, 1 light, 2 dark. */
    JSTI_EVENT_APPEARANCE = 45,
    /* General › Launch at login. index: 1 on, 0 off. The switch stays
     * insensitive until jsti_window_set_login_item reports the state reached. */
    JSTI_EVENT_LOGIN_ITEM = 46,
    JSTI_EVENT_AUTOMATION = 47,
    /* Housekeeping › New recordings folder. text: chosen absolute local folder,
     * or "" to save new recordings in History again. Nothing is moved.
     * Must stay distinct from every shared event (98 is Migration restore). */
    JSTI_EVENT_RECORDINGS_LOCATION = 48,
    JSTI_EVENT_USER_ABSENT = 131, /* Outside comparison events 100-109 and 120-129. */
    /* Settings search in the sidebar. text: the query as typed, reported as it
     * changes (debounced by GtkSearchEntry) and as "" when the empty entry is
     * focused, which asks for recent destinations. */
    JSTI_EVENT_SETTINGS_SEARCH = 160,
    /* index: the chosen row of the last jsti_window_set_settings_search_results. */
    JSTI_EVENT_SETTINGS_SEARCH_OPEN = 161
};

/* Recording state for jsti_window_update: -1 keeps the current state. */
enum { JSTI_STATE_IDLE = 0, JSTI_STATE_RECORDING = 1, JSTI_STATE_WORKING = 2 };

typedef void (*jsti_window_event_fn)(int32_t event, const char *text, int32_t index, void *context);

#ifdef __cplusplus
}
#endif
#endif
