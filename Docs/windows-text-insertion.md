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
`Sources/SpeakWindowsPlatform/WindowsTextOutput.swift` (ownership, settings
and status text) and the `present`/`deliver` path in
`Sources/SpeakWindows/WindowsTranscriptionController.swift`.

## Capture

`jsti_insertion_capture` runs synchronously inside the hotkey callback before
any actor hop. It records the foreground window, its thread, its process and
that thread's focused control (`GetGUIThreadInfo`), and refuses this
application's own windows. It never calls into the target application, so
recording startup does not wait on a slow or hung provider.

A dedicated worker thread then asks UI Automation for the focused element in
the background (`IUIAutomation::GetFocusedElement`) and keeps it only when its
process and nearest native window match the captured control. That element
gives field identity for controls that share one native window, such as every
field in a browser tab. If the lookup fails or times out, later insertion still
requires window-level identity but reports `identity = window`.

The target is an opaque object owned by `WindowsInsertionTarget` on the Swift
side and destroyed exactly once on its last reference, whichever way the
recording ends. Destroy is bounded: a worker still blocked inside a provider
call is detached, keeps its own reference to the shared state and releases the
COM interfaces and thread when the call returns. Provider round trips are
capped with `IUIAutomation2` connection and transaction timeouts.

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
   process under the same window and, when a capture element exists, the same
   element (`CompareElements`). `IsPassword`, disabled elements and a read-only
   Value pattern are refused. Editable means control type Edit, Document or
   ComboBox, or a writable Value pattern together with a Text pattern.

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

1. Snapshot the clipboard: every global-memory format in enumeration order up
   to 64 formats, 16 MiB per format and 32 MiB in total. Handle-based formats
   (bitmaps, metafiles, palettes, owner-display, private and GDI ranges) are
   not preserved and make the restore partial; text synthesized from
   `CF_UNICODETEXT` is not copied twice. Contents are never logged.
2. Place the transcript as `CF_UNICODETEXT` together with the documented
   `ExcludeClipboardContentFromMonitorProcessing`,
   `CanIncludeInClipboardHistory = 0` and `CanUploadToCloudClipboard = 0`
   formats, so the transient transcript does not enter clipboard history or
   cloud sync.
3. Re-verify identity, confirm the caller is still waiting for this operation,
   wait up to one second for Shift, Alt and the Windows key to be released, and
   send Ctrl down, V down, V up, Ctrl up with `SendInput`. Nothing is sent when
   the foreground window or focused control changed in the meantime.
4. Poll the field through UI Automation for up to 1.5 seconds until the
   transcript appears one more time than before the paste. A field that cannot
   be read at all waits a fixed settle time instead.
5. Restore the previous clipboard content when the paste was confirmed or the
   field is unreadable, unless the clipboard sequence number shows another
   application wrote to it meanwhile (then it is left alone). When the field is
   readable but the transcript never appeared, the transcript stays on the
   clipboard and the outcome is reported as unconfirmed rather than restored,
   because a late paste of the old content would be worse.

The status line reports the method, whether the field was read back, and what
happened to the clipboard. The keystroke can only be addressed to the
foreground thread, so a focus change in the few milliseconds between the final
check and delivery is a residual risk shared with the macOS paste path.

### Settings

`%LOCALAPPDATA%\JustSpeakToIt\settings.json` accepts an optional `textOutput`
object; there is no settings UI yet. Unknown values fall back to the defaults.

```json
"textOutput": { "method": "smart", "insertion": "insertAtCursor", "restoreClipboard": true }
```

- `method`: `smart` (native, then Value pattern, then guarded paste),
  `directOnly` (never uses the clipboard or keyboard; macOS "Accessibility"),
  `clipboardOnly` (copies the transcript without inserting).
- `insertion`: `insertAtCursor` or `replaceField`. Replace-field selects all
  in native controls or uses a writable Value pattern; it never pastes.
- `restoreClipboard`: `false` leaves the transcript on the clipboard after a
  paste (macOS "restore clipboard after paste" off).

## Timeouts and lifetime

| Bound | Default |
|---|---|
| Insert call, worst case | 6 s (caller timeout; the abandoned job restores the clipboard and never pastes afterwards) |
| Provider connection/transaction timeout | 2 s each |
| Paste verification polling | 1.5 s at 50 ms |
| Unreadable-field settle before restore | 400 ms |
| Destroy wait before detaching a blocked worker | 2 s |

Native controls are addressed on the caller's thread and never wait for the
background UI Automation capture. One insertion at a time is accepted per
target; a second call while the worker is busy fails instead of queueing.

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
worker cleanup. The legacy `jsti_target_capture`/`jsti_target_insert_text`
entrypoints are covered for compatibility.

The self-test never sends real input, never opens the system clipboard and
never inserts into another application. It exercises UI Automation in
process through the Win32 Edit proxies; it is not evidence of insertion into
a real browser, Electron, XAML or Office window.

## Remaining acceptance gates

- Physical journeys into Chromium/Firefox fields, Electron apps, Windows
  Terminal, WinUI/UWP/WPF controls and Word/Outlook/Excel on a real Windows
  machine, including cancellation, elevated targets and rapid focus changes.
- A text output settings UI; the settings above are hand-edited only.
- Undo integration for the paste path, streaming insertion and voice edit.
- Clipboard restore for handle-based formats (bitmaps, metafiles).
- Provider-specific normalisation: applications that transform pasted text
  (auto-correct, smart quotes, newline stripping) report the paste as
  unconfirmed and keep the transcript on the clipboard.
- Read-only detection for UI Automation fields needs the Value pattern. A
  read-only Document without one (a protected Word view, for example) is not
  refused up front; its ignored paste is reported as unconfirmed instead.
