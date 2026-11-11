#ifndef JSTI_WINDOWS_TEXT_OUTPUT_H
#define JSTI_WINDOWS_TEXT_OUTPUT_H
/* Text output: clipboard, insertion targets and UI Automation. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Legacy direct path, retained for source/ABI compatibility. Capture at the
 * recording hotkey before showing UI. Insertion is explicitly addressed to the
 * original native Edit/RichEdit control only; other applications fail closed
 * and should offer Copy. This entrypoint never sends keystrokes or touches the
 * clipboard. New callers use the opaque jsti_insertion_* API below. */
typedef struct JSTITextTarget {
    uintptr_t window;
    uintptr_t focused_control;
    uint32_t process_id;
    uint32_t thread_id;
} JSTITextTarget;
int jsti_target_capture(JSTITextTarget *target, char *error, size_t error_capacity);
int jsti_target_insert_text(const JSTITextTarget *target, const char *text,
                            char *error, size_t error_capacity);
/* Deliberate user copy: plain CF_UNICODETEXT, eligible for clipboard history. */
int jsti_clipboard_write(const char *text, char *error, size_t error_capacity);
/* Read-only CF_UNICODETEXT snapshot, <=1 MiB UTF-8. Call off the UI thread.
 * Returns 1 for non-text. Free a successful snapshot with the matching function. */
int jsti_voice_command_clipboard_read(char **text, char *error, size_t error_capacity);
void jsti_voice_command_clipboard_free(char *text);

/* Opaque insertion target with explicit lifetime. Capture synchronously at the
 * recording hotkey: it records the foreground window, its thread and the
 * focused control immediately and never blocks on the target application. A
 * dedicated worker resolves the snapshotted focus event to its exact UI
 * Automation element so later insertion can prove field identity; startup
 * never waits for that provider. Every insertion re-verifies the original
 * process, thread, window and focused control, refuses password/read-only
 * fields and never steals focus or types into another application.
 *
 * Methods, in order of preference for the captured control:
 *  1. Native Unicode Edit/RichEdit: EM_REPLACESEL to the captured control
 *     (inserts at the caret or replaces the selection).
 *  2. UI Automation Value pattern SetValue, used only when it is exactly
 *     equivalent to insertion: the field is empty or the whole text is
 *     selected (or the replace-field flag is set). UI Automation's Text
 *     pattern is read-only and cannot insert; the field is never replaced
 *     wholesale to emulate a caret insertion.
 *  3. Guarded clipboard paste: the current clipboard is snapshotted, the text
 *     is placed as CF_UNICODETEXT excluded from clipboard history/cloud sync,
 *     Ctrl+V is sent while the captured control still owns focus, the field is
 *     read back through UI Automation where possible, and the previous
 *     clipboard content is restored unless it changed meanwhile.
 * Insertion into a process of higher integrity (for example an elevated app)
 * fails closed because Windows UIPI blocks both messages and input.
 *
 * Insert blocks the caller for a bounded time (about six seconds worst case)
 * and may be called at most once at a time per target. Destroy is nonblocking:
 * a worker still blocked inside a provider call is detached and
 * releases its own resources when that call returns. Destroy after insert
 * returns, never from another thread concurrently with insert. */
typedef struct JSTIInsertionTarget JSTIInsertionTarget;
enum JSTIInsertionFlags {
    /* Replace the whole field instead of inserting at the caret. Native
     * controls select all first; UI Automation requires a writable Value
     * pattern; the clipboard fallback is never used for replacement. */
    JSTI_INSERTION_REPLACE_FIELD = 1u << 0,
    /* Leave the transcript on the clipboard after a paste instead of
     * restoring the previous content (macOS "restore clipboard" off). */
    JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD = 1u << 1,
    /* Never paste through the clipboard. An explicit app-switch policy may
     * still request a recovery copy without sending keys. */
    JSTI_INSERTION_NO_PASTE_FALLBACK = 1u << 2,
    JSTI_INSERTION_ORIGINAL_APP = 1u << 3,
    JSTI_INSERTION_CURRENT_APP = 1u << 4,
    JSTI_INSERTION_ONLY_ORIGINAL_FRONT = 1u << 5
};
enum JSTIInsertionMethod {
    JSTI_INSERTION_METHOD_NONE = 0,
    JSTI_INSERTION_METHOD_NATIVE_EDIT = 1,
    JSTI_INSERTION_METHOD_UIA_VALUE = 2,
    JSTI_INSERTION_METHOD_PASTE = 3,
    JSTI_INSERTION_METHOD_CLIPBOARD = 4
};
enum JSTIInsertionIdentity {
    /* Process, thread, foreground window and focused control matched. */
    JSTI_INSERTION_IDENTITY_WINDOW = 1,
    /* Additionally the same UI Automation element that had focus at capture. */
    JSTI_INSERTION_IDENTITY_FIELD = 2
};
enum JSTIInsertionClipboard {
    JSTI_INSERTION_CLIPBOARD_UNTOUCHED = 0,
    JSTI_INSERTION_CLIPBOARD_RESTORED = 1,
    /* Restored what fit; oversized or non-memory formats were not preserved. */
    JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY = 2,
    /* The transcript was intentionally left on the clipboard. */
    JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT = 3,
    JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED = 4,
    /* Another application changed the clipboard meanwhile; it was left alone. */
    JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE = 5
};
typedef struct JSTIInsertionResult {
    int method;    /* JSTIInsertionMethod */
    int verified;  /* 1 when the field was read back and contains the text */
    int identity;  /* JSTIInsertionIdentity */
    int clipboard; /* JSTIInsertionClipboard */
} JSTIInsertionResult;
/* Start the bounded focus-event observer during normal application startup. */
void jsti_insertion_prepare(void);
/* Null with an error when no external application field is focused. */
JSTIInsertionTarget *jsti_insertion_capture(char *error, size_t error_capacity);
/* Begin a bounded read-only snapshot on the worker, also permitting the app's
 * own focused control. This target cannot insert text or replace the clipboard. */
JSTIInsertionTarget *jsti_selection_capture(char *error, size_t error_capacity);
/* Captures one editable selection. A successful selection_read anchors its
 * exact range and document; insertion rechecks both immediately before writing.
 * Unlike read-only selection capture, this cannot target the app itself. */
JSTIInsertionTarget *jsti_voice_edit_capture(char *error, size_t error_capacity);
/* One bounded worker read of selected UIA TextPattern ranges, never the whole
 * field. Password, focus/process changes and unavailable selection are errors.
 * The UTF-8 output is bounded to 200,000 UTF-16 units. Off the UI/host actor only. */
int jsti_selection_read(JSTIInsertionTarget *target, char *text, size_t text_capacity,
                         char *error, size_t error_capacity);
/* Zero: input was submitted by result->method; verified reports read-back.
 * -1: no text mutation was submitted. 1: mutation may have occurred or shortcut
 * submission was partial; do not retry automatically. Clipboard state is
 * reported in result->clipboard. Text must be non-empty UTF-8. */
int jsti_insertion_insert(JSTIInsertionTarget *target, const char *text, unsigned flags,
                          JSTIInsertionResult *result, char *error, size_t error_capacity);
/* Thread-safe nonblocking abandonment. Prevents pending mutations; an operation
 * already dispatched may complete, and insert then reports its actual/uncertain
 * outcome. The target remains owned until insert returns and destroy is called. */
void jsti_insertion_cancel(JSTIInsertionTarget *target);
/* Blocking, bounded worker request; never call on the UI/audio/host actor.
 * original nonnull captures only the exact acknowledged insertion's UIA range.
 * original null samples that range once. Identity/context changes refuse learning. */
int jsti_insertion_learning(JSTIInsertionTarget *target, const char *original,
                            char *edited, size_t edited_capacity, char *error, size_t error_capacity);
/* Explicit clipboard-only output, guarded by the captured request's cancellation
 * state immediately before replacement. Does not follow or mutate field focus. */
int jsti_insertion_copy_text(JSTIInsertionTarget *target, const char *text, JSTIInsertionResult *result,
                              char *error, size_t error_capacity);
/* Original captured process handle, never a fresh focus/PID lookup. required_bytes
 * includes the NUL; 0 success, 2 insufficient buffer, -1 unavailable. */
int jsti_insertion_executable_path(const JSTIInsertionTarget *target, char *path, size_t path_capacity,
                                   size_t *required_bytes, char *error, size_t error_capacity);
/* One foreground-process snapshot, without field lookup, input or an insertion
 * worker. Empty path means no external app; -1 is an explicit lookup failure.
 * Supply 131073 bytes for the maximum UTF-8 process path. */
int jsti_foreground_executable_path(char *path, size_t path_capacity, char *error, size_t error_capacity);
void jsti_insertion_destroy(JSTIInsertionTarget *target);

/* Automatic clipboard output for one completed recording whose method is copy
 * to clipboard, including recordings started with Record in this window, which
 * have no captured field. It never queries or follows focus, never inserts and
 * never sends input. The transcript is left as plain Unicode text, exactly like
 * jsti_insertion_copy_text and jsti_clipboard_write: an ordinary copy without
 * the guarded paste's history and cloud exclusion formats. A job copies at
 * most once. */
typedef struct JSTIClipboardOutput JSTIClipboardOutput;
/* Allocates a job without touching the clipboard. */
JSTIClipboardOutput *jsti_clipboard_output_create(char *error, size_t error_capacity);
/* Blocks for a bounded time; call off the UI thread and outside actors. A
 * cancelled job, or one used by an earlier attempt, is refused before the text
 * is read or the clipboard opened; any other attempt uses the job up.
 * Otherwise the clipboard is opened (10 attempts, 20 ms apart) and its content
 * snapshotted; then, while it is still owned, cancellation is checked under the
 * job's lock immediately before replacement. A cancel that returned before
 * that check guarantees no clipboard change; a later cancel cannot stop the
 * committed write, which is reported. 0 copied; -1 nothing copied, and
 * clipboard_state (JSTIInsertionClipboard, optional) reports whether a failed
 * write restored the previous content. Text must be non-empty UTF-8. */
int jsti_clipboard_output_copy(JSTIClipboardOutput *job, const char *text, int *clipboard_state,
                               char *error, size_t error_capacity);
/* Thread safe and nonblocking, including while copy runs on another thread. */
void jsti_clipboard_output_cancel(JSTIClipboardOutput *job);
/* Call once, after copy has returned or when it was never called. */
void jsti_clipboard_output_destroy(JSTIClipboardOutput *job);
/* Synthetic in-memory clipboard only: copy, cancellation before and inside the
 * owned section, single use, failed-write restore and bounded busy failure.
 * Never touches the system clipboard. */
int jsti_clipboard_output_self_test(char *error, size_t error_capacity);

/* Deterministic native checks on app-owned synthetic hidden controls with
 * injected foreground, clipboard and keystroke seams: caret/selection
 * insertion, surrogate pairs, stale identity, password/read-only refusal,
 * UI Automation value/paste paths, timeouts and worker cleanup. Never sends
 * real input, touches the system clipboard or inserts into another app. */
int jsti_text_output_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
