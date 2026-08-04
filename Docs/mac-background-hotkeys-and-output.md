# macOS background hotkeys and text output

This runbook records the supported design and release checks for capturing a
shortcut and delivering transcription while Speak is not the frontmost app.

## Supported design

- Custom shortcuts use Carbon `RegisterEventHotKey`. They do not depend on the
  Speak window or status item being active.
- The Fn key uses an event tap/global monitor and requires Input Monitoring.
  The tap is re-enabled when macOS disables it, and the app reconnects after
  activation, wake, and session unlock.
- The status item is a diagnostic and recovery surface. It displays the selected
  binding and backend state and provides **Reconnect Hotkey**; creating a status
  item does not itself make a shortcut global.
- A transcription session captures the frontmost process and focused
  accessibility element before the HUD appears. Direct builds deliver to that
  captured target, even if focus changes during transcription or post-processing.
- Mac App Store builds remain clipboard-only. App Sandbox does not allow the
  accessibility and cross-process event-injection behavior used by the direct
  build, so the app must not claim automatic insertion for that channel.

## Release validation

Treat these as separate gates:

1. Run focused tests in both direct and `APP_STORE` compiler modes.
2. Build the direct app and the sandboxed Mac App Store app with their actual
   entitlements.
3. In the direct signed app, grant Input Monitoring and Accessibility. Start a
   recording from TextEdit with the Speak window unfocused, change focus during
   transcription, and verify output returns to the original field.
4. Sleep/wake and lock/unlock the Mac. Confirm the status menu returns to
   `Hotkey: <binding> · Active`; use **Reconnect Hotkey** if macOS disabled the
   backend.
5. In the App Store build, verify global recording still starts, the transcript
   reaches the clipboard, and no automatic paste is attempted.
6. Repeat with the physical Fn key. UI automation that targets a specific app
   does not prove a system-global shortcut path.

## Primary references

- [NSEvent monitoring](https://developer.apple.com/documentation/appkit/nsevent)
- [CGEvent tap disable events](https://developer.apple.com/documentation/coregraphics/cgeventtype)
- [Input Monitoring preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess%28%29)
- [NSWorkspace wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification)
- [App Sandbox limits](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
