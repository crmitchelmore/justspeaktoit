/* @Context # Smart Text Insertion Implementation Blueprint

This guide explains how to integrate an "Insert" action that prefers Accessibility value injection and automatically falls back to a Command+V paste. Follow the steps in order; each section points to the relevant code inside this project so a junior engineer can reproduce the behaviour in another app.

## 1. Extend the Text Injector Facade

### 1.1 Define a Result Payload
- File: `Sources/PasteDelayApp/TextInjector.swift:12`
- Add `TextInjector.Result` with two stored properties:
  - `method: Method` tracks which delivery path succeeded.
  - `fallbackReason: InjectionError?` captures (optional) context when the pasteboard fallback runs.
- Implement a `successMessage` computed property that renders user-facing status text depending on the path used. Keep pasteboard-fallback messaging explicit: `Sent text using Command+V fallback (<reason>).`

### 1.2 Enrich InjectionError
- File: `Sources/PasteDelayApp/TextInjector.swift:29`
- Ensure `InjectionError` covers `emptyPayload`, `accessibilityDenied`, `noFocusedElement`, and `valueNotSettable`.
- Provide two helpers:
  - `errorDescription` returning precise guidance (e.g. "Focused control does not allow direct Accessibility edits. Command+V fallback is required.").
  - `fallbackSummary` describing why the Command+V path was needed (e.g. "focused control rejected direct Accessibility edits").

### 1.3 Introduce the Smart Insert Method
- File: `Sources/PasteDelayApp/TextInjector.swift:73`
- Add `@MainActor func insert(_ text: String) throws -> Result`.
- Behaviour sequence:
  1. Attempt `injectViaAccessibilityValue(text:)`.
  2. If it succeeds, return `.accessibilityValue` with no fallback reason.
  3. If it throws `valueNotSettable` or `noFocusedElement`, immediately attempt `injectViaPasteboard(text:)`.
  4. If the fallback paste succeeds, return `.pasteboard` populated with the triggering error.
  5. For any other error (permissions, empty payload), rethrow to the caller unchanged.
- Keep the existing `inject(_:using:)` method public for callers that need to force a specific path.

## 2. UI State Machine Consolidation

### 2.1 Replace Dual Buttons
- File: `Sources/PasteDelayApp/ContentView.swift:25`
- Collapse the previous "Pasteboard"/"Accessibility" buttons into a single `Button` labelled by `status.buttonLabel`.
- Disable the button when input is empty; keep it enabled during countdown so the user can cancel.
- Update the helper text above the field to explain the automatic hierarchy.

### 2.2 Simplify Countdown View
- File: `Sources/PasteDelayApp/ContentView.swift:35`
- Show a single progress bar and caption `Insert in <n>s` whenever `status` is `.countingDown`.

### 2.3 Rewrite InjectionStatus
- File: `Sources/PasteDelayApp/ContentView.swift:141`
- Refactor the enum to remove mode-specific associated values:
  - Cases: `.idle`, `.countingDown(remaining: Int)`, `.sending`, `.success(result: TextInjector.Result)`, `.failure(reason: String)`.
  - Computed properties:
    - `buttonLabel` returns "Insert", "Cancel", or "Working…".
    - `message` maps to idle guidance, countdown instructions, generic sending text, `result.successMessage`, or the error reason.
    - `messageColor` returns `.green` on success, `.red` on failure, `.secondary` otherwise.
    - `isInputLocked` disables the text field during countdown and send.

### 2.4 Coordinate Task Lifecycle
- File: `Sources/PasteDelayApp/ContentView.swift:67`
- `handleButtonTap()` toggles between starting and cancelling the countdown.
- `startCountdown()` captures the payload snapshot and queues a `Task` that sleeps for three seconds, updating status every second.
- `countdownAndInject(text:)` performs the countdown, transitions to `.sending`, calls `injector.insert(text)`, and sets `status` to `.success(result:)` or `.failure(reason:)`.
- `scheduleReset()` keeps the success banner visible for two seconds before returning to `.idle`.
- Always cancel and nil out `countdownTask` in `cancelCountdown()` and at the end of `countdownAndInject(text:)`.

## 3. Accessibility Messaging Touch-Up

- File: `Sources/PasteDelayApp/TextInjector.swift:35`
- Update the `valueNotSettable` error message to steer users toward the automatic fallback: "Command+V fallback is required." This keeps runtime feedback aligned with the new single-button behaviour.

## 4. Validation Checklist

1. Run `swift build` (or `make build`) to ensure the code compiles.
2. Manually grant Accessibility permissions to the host app if prompted.
3. Test three scenarios:
   - Standard text field (AX settable): confirm the success banner reports "Set text via Accessibility value attribute." and the clipboard contents are preserved.
   - Non-settable control (e.g., secure field): confirm we fall back to pasteboard and report the fallback reason.
   - No focused element: confirm the countdown ends in an error banner from the injector.
4. From `.success`, wait for the automatic reset to `.idle` before triggering another insert.

## 5. Integration Tips for Other Apps

- Keep Accessibility interactions behind a façade type (`TextInjector` or similar) so UI code never reaches through to raw AX APIs.
- Maintain public API stability: expose a single `insert(text:)` entry point and keep method-selection logic internal.
- When porting, ensure the host app has a main-thread entry point (AX APIs are main-thread only) and that any SwiftUI view state mirrors the `InjectionStatus` shape above.
- Restore the clipboard after pasteboard-based injection to avoid surprising users.
- Document fallback behaviour prominently in user-facing copy so expectations stay aligned.

Following this sequence allows another project to drop in the same smart Insert capability with minimal guesswork.
 */

protocol TextOutputting {
  func output(text: String) -> Error?
}

// @Implement: This implementation should check for accessibility permissions and use the accessibility API to paste text into the focused app. It should respect any relevant settings from app settings
struct AccessibilityTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String) -> Error? {
    return nil
  }
}

// @Implement: This implementation should use the clipboard to paste text into the focused app. It should restore the previous pasteboard value (if the app setting output to clipboard is false) It should respect any relevant settings from app settings
struct PasteTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String) -> Error? {
    return nil
  }
}
