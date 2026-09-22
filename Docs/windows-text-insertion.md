# Windows text insertion

The Windows host delivers a finished transcript into the field that had
keyboard focus when the recording hotkey fired. The product semantics follow
the macOS `SmartTextOutput`, `TextOutputMethod` and `AccessibilityInsertionMode`
behaviour: prefer direct insertion at the caret, fall back to a guarded paste,
never deliver into a different application, and fail closed with a Copy
fallback whenever the target cannot be verified. The Windows mechanisms differ
because the platform APIs differ; this document records what is implemented,
what each method can and cannot do, and which acceptance gates remain open.

Source: `Sources/CWindowsSupport/WindowsTextOutput.cpp` (adapter),
`WindowsTextOutputSelfTest.cpp` (deterministic checks),
`WindowsClipboardOutput.cpp` (clipboard-only output without a captured field),
`WindowsTextOutputSettings.cpp` (the native Text output dialog),
`Sources/SpeakWindowsPlatform/WindowsTextOutput.swift` (ownership, settings
and status text), `Sources/SpeakWindows/WindowsInsertionController.swift`
(the actor-owned output task and cancellation) and
`Sources/SpeakWindows/WindowsTextOutputSettings.swift` (saving the dialog's
choices).

## Capture

`jsti_insertion_capture` runs synchronously inside the hotkey callback before
any actor hop. It records the foreground window, its thread, its process and
that thread's focused control (`GetGUIThreadInfo`), and refuses this
application's own windows. It never calls into the target application, so
recording startup does not wait on a slow or hung provider.

One bounded observer starts during normal app startup. It stores only the last
focus event's HWND, object/child IDs, thread and revision; it makes no provider
calls and stores no field content. Capture snapshots that identity. A worker
resolves that exact event through `AccessibleObjectFromEvent` and
`IUIAutomation::ElementFromIAccessible`, retaining the resulting field only
while focus has not changed. It never treats a later `GetFocusedElement`
lookup as evidence of what was focused at the hotkey.

If an appropriate focus event was not observed, its provider cannot resolve
the original object, or focus changed during resolution, virtual-field output
falls back to Copy. Native Edit/RichEdit uses its captured control HWND. Events
are asynchronous and application support must be verified during physical
acceptance. See Microsoft's [focus hook contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)
and [event support guidance](https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants).

`WindowsInsertionTarget` owns the native target. Capture retains the original
process handle; the executable-path getter uses that handle without a fresh
focus or PID lookup. Destruction requests cancellation and detaches promptly
if a provider is blocked. At most four native workers can exist, including
detached workers, and each owns its state until cleanup. Native controls remain
available when provider-worker capacity is exhausted. Provider round trips use
`IUIAutomation2` timeouts when available.

## Verification before every delivery

Insertion re-checks, in this order:

1. The captured window and control still exist, belong to the captured process
   and thread, the captured window is the foreground window, the thread's
   focused control is still the captured control and it is still inside the
   captured window.
2. The target process does not run at a higher integrity level than this
   application. Windows UIPI silently drops `SendInput` and rejects window
   messages sent to elevated processes, so this fails closed with an explicit
   message instead of a silent no-op.
3. The control's class and state. Native Unicode `Edit`, `RichEdit20W`,
   `RICHEDIT50W`, `RICHEDIT60W` and `RichEditD2DPT` controls are refused when
   they carry `ES_PASSWORD` or `ES_READONLY` or are disabled. Any other control
   goes through UI Automation, which must return a focused element of the same
   process under the same window and the same
   captured element (`CompareElements`). Password, disabled, read-only and
   unknown protection/editability states are refused. Read-only state comes
   from the Value pattern or the Text pattern's `IsReadOnly` attribute. These
   checks repeat after modifier waits and provider reads, before mutation.

## Methods

| Method | When | Insert-at-cursor semantics | Verification |
|---|---|---|---|
| Native `EM_REPLACESEL` | Native Unicode Edit/RichEdit control | Exact: inserts at the caret or replaces the selection, with undo | Packed `EM_GETSEL` caret moved past the former selection start by at most the inserted length |
| UI Automation Value pattern `SetValue` | Field is empty, the whole text is selected (Text pattern endpoints equal the document range), or replace-field was requested | Exact for those cases only; the field is never replaced wholesale to emulate a caret insertion | Value or document text read back contains the transcript |
| Guarded paste | Any other editable UI Automation field | Application-defined: the target's own paste handler inserts at its caret | Occurrence count of the transcript in the field's value or document text increases within a bounded polling window |

UI Automation's Text pattern is read-only. It exposes ranges, selection and
text, but has no insertion method, so it is used for verification and for the
whole-selection check only. This is a documented limitation of the platform,
not of this adapter.

### Guarded paste details

1. Read the field, then snapshot and replace the clipboard within one short
   ownership transaction. Snapshot every global-memory format in enumeration order up
   to 64 formats, 16 MiB per format and 32 MiB in total. Handle-based formats
   (bitmaps, metafiles, palettes, owner-display, private and GDI ranges) are
   not preserved and make the restore partial; text synthesized from
   `CF_UNICODETEXT` is not copied twice. Contents are never logged.
2. Place the transcript as `CF_UNICODETEXT` together with the documented
   `ExcludeClipboardContentFromMonitorProcessing`,
   `CanIncludeInClipboardHistory = 0` and `CanUploadToCloudClipboard = 0`
   formats, so the transient transcript does not enter clipboard history or
   cloud sync, when Windows accepts those marker formats. Failed text placement
   rolls back the content it replaced while ownership is still held.
3. Wait up to one second for modifiers to be released, then re-check the
   original field, protection state, focus-event revision, clipboard sequence
   and cancellation immediately before submitting Ctrl down, V down, V up,
   Ctrl up. A changed clipboard is left alone and no paste is submitted.
4. Poll readable fields for up to 1.5 seconds. Only confirmed insertion permits
   clipboard restoration. Unreadable or unconfirmed fields keep the transcript
   available for a delayed paste; there is no fixed-delay restoration.
5. Restoration checks the sequence after acquiring clipboard ownership, so a
   copy made during the acquisition wait is preserved. Partial shortcut
   submission releases owned modifier keydowns and reports an uncertain
   outcome; it never substitutes the old clipboard under a delayed paste.

The status line reports the method, whether the field was read back, and what
happened to the clipboard. The keystroke can only be addressed to the
foreground thread, so a focus change in the few milliseconds between the final
check and delivery is a residual risk shared with the macOS paste path.

### Settings

**Text output…** in the main window opens a native modal dialog built from
standard radio buttons, group boxes and a checkbox. It saves the optional
`textOutput` object in `%LOCALAPPDATA%\JustSpeakToIt\settings.json`; the format
is unchanged, so hand-edited files keep working, and missing or unknown values
fall back to the defaults.

```json
"textOutput": { "method": "smart", "insertion": "insertAtCursor", "restoreClipboard": true }
```

- `method`: `smart` (native, then Value pattern, then guarded paste),
  `directOnly` (never uses the clipboard or keyboard; macOS "Accessibility"),
  `clipboardOnly` (copies the transcript without inserting).
- `insertion`: `insertAtCursor` or `replaceField`. Replace-field selects all
  in native controls or uses a writable Value pattern; it never pastes.
- `restoreClipboard`: `false` leaves the transcript on the clipboard after a
  paste (macOS "restore clipboard after paste" off); that transcript keeps the
  paste's history and cloud exclusion.

The dialog disables choices the selected method cannot use but keeps their
stored values: insertion for clipboard-only output, and clipboard restoration
for everything except a Smart paste at the cursor. Apply sends one complete
choice through the app's ordered settings queue and then shows what was
actually saved, so a failed save leaves the previous choice; Cancel, Escape
and closing change nothing. The dialog is available only while idle, and its
owner window ignores the recording shortcut and Record while it is open.

Each Record event reads the saved choice in the same queue: an Apply made
before Record is used, and a later Apply affects only later recordings, even
while the earlier one is still being captured, transcribed or post-processed.
Imports and History retries never output automatically.

Clipboard-only output does not need a captured field, so it also copies
recordings started with Record in this window. It uses a separate cancellable
native job that never queries focus, inserts or sends input; after acquiring
and snapshotting the clipboard it checks cancellation immediately before
replacement. Smart and direct-only output still need the captured field and
leave in-app recordings in History for Copy. Clipboard-only output writes plain
`CF_UNICODETEXT` exactly like **Copy transcript**, so the copy can appear in
clipboard history and cloud sync; only the guarded paste's transient transcript
carries the exclusion formats described above.

## Timeouts and lifetime

| Bound | Default |
|---|---|
| Insert call, worst case | 6 s; pending work is abandoned, already-dispatched operations report an uncertain result |
| Provider connection/transaction timeout | 2 s each |
| Paste verification polling | 1.5 s at 50 ms |
| Native UI Automation workers | 4, including detached blocked workers |
| Destroy wait before detaching a blocked worker | 0 ms |
| Pending host output jobs | 1 |

The host executes blocking native output outside its controller actor, so
capture, cancellation and shutdown can proceed. New capture/import, cancellation
and close cancel the pending output: an insertion abandons its native target,
and a clipboard-only copy is refused unless it has already passed its final
check. One output job, an insertion or a clipboard-only copy, retains its slot
until completion; another transcript remains in History with Copy available
while a blocked old job finishes. Results from cancelled or superseded jobs
cannot replace the current UI. Clipboard-only output checks cancellation after
acquiring the clipboard and before replacement, and refuses a transcript
containing a NUL character instead of copying a shortened prefix.

A native return of `1` means mutation may have occurred, including partial
shortcut submission or timeout after dispatch. The UI asks the user to inspect
the original field before retrying. Cancellation cannot retract an OS/provider
operation that has already been dispatched.

## Deterministic native self-test

`jsti_text_output_self_test` (run by `SpeakWindows.exe --self-test` and the
`WindowsTextOutputTests` XCTest) creates hidden `Edit`, multi-line, password,
read-only and `RICHEDIT50W` controls on a helper UI thread inside the test
process and injects seams: the foreground window is the synthetic host, the
clipboard is an in-memory fake, `SendInput` is a stub that emulates the
application's paste handler by inserting the fake clipboard text at the
focused control's selection, and the focused element is resolved from the
captured control handle because CI sessions have no reliable foreground
window. It checks caret and selection insertion, a surrogate pair through
RichEdit, replace-field, password/read-only refusal through both the native
and UI Automation paths, stale focus, a changed foreground window, field
identity mismatch inside one window, the Value pattern for empty and fully
selected fields, the guarded paste with exact multi-format clipboard
restoration and history-exclusion markers, disabled fallback, keep-transcript,
multi-line text, keystroke failure, an ignored paste, a clipboard changed by
another application, a bounded caller timeout with no late paste, bounded
destroy of a blocked worker, native insertion during a blocked capture, and
worker cleanup. Additional cases cover clipboard acquisition/close races,
rollback after failed placement, focus/cancel during modifier preparation,
partial shortcut counts, exact captured-event identity, worker saturation,
original process paths, clipboard-only output as an ordinary copy without the
paste's exclusion formats, a kept paste that retains them, cancelled
clipboard-only output, and timeout after mutation starts. The legacy
`jsti_target_capture`/`jsti_target_insert_text` entrypoints are covered for
compatibility.

`jsti_clipboard_output_self_test` drives the field-independent clipboard-only
job against its own in-memory clipboard: an ordinary copy, cancellation before
opening, while the clipboard is owned and after the final check, single use,
failed-write restoration, a busy clipboard, and no focus or input calls. The
executable's `--self-test` also runs the controller's real recording, settings
queue and output workflow with synthetic capture, providers and output: batch
and live recordings keep the choice read at their Record event while a later
Apply is saved, Apply before Record is honoured, a failed save changes nothing,
imports and History retries never output, and closing cancels a pending copy.
`--ui-smoke-test` exercises the Text output dialog's controls, keyboard order,
minimum bounds and modal recording refusal. These are synthetic checks that
must pass on Windows CI; they are not physical acceptance.

The self-test never sends real input, never opens the system clipboard and
never inserts into another application. It exercises UI Automation in
process through the Win32 Edit proxies; it is not evidence of insertion into
a real browser, Electron, XAML or Office window.

## Remaining acceptance gates

- Physical journeys into Chromium/Firefox fields, Electron apps, Windows
  Terminal, WinUI/UWP/WPF controls and Word/Outlook/Excel on a real Windows
  machine, including cancellation, elevated targets and rapid focus changes.
- Windows CI evidence for the Text output dialog and field-independent
  clipboard-only output, and physical keyboard, screen reader, high-contrast
  and DPI acceptance of the dialog.
- Undo integration for the paste path, streaming insertion and voice edit.
- Clipboard restore for handle-based formats (bitmaps, metafiles).
- Provider-specific normalisation: applications that transform pasted text
  (auto-correct, smart quotes, newline stripping) report the paste as
  unconfirmed and keep the transcript on the clipboard.
- Virtual-field support requires a matching observed focus event and a provider
  that resolves it to the original object. Missing events or unknown protection
  state produce a Copy fallback; native-control support is independent.
