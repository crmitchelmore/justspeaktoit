# macOS permission setup guides

User-triggered permission actions in onboarding, Settings and the dashboard share
`PermissionsManager.requestWithGuidance` and `openSettings(for:)`. Background
recording and shortcut checks retain `request` / `ensureGranted` and never start
a guide automatically.

[PermissionFlow 2.11.2](https://github.com/jaywcjlove/PermissionFlow/tree/v2.11.2)
provides the animated floating app card for Accessibility and Input Monitoring.
It opens the specific System Settings pane and lets the user drag the **running
app bundle** into the list. Its configuration disables extra Accessibility
prompts for window tracking. The dependency is pinned in both SwiftPM and Tuist.
No new entitlements or privacy usage descriptions are needed.

| Permission | First request / recovery |
| --- | --- |
| Accessibility (direct distribution) | Open the floating drag guide; avoid an additional trust alert covering Settings. |
| Input Monitoring | Keep the native request; show the drag guide if access remains missing. |
| Microphone | Keep the native first request; denied access opens a floating switch guide. |
| Speech Recognition | Keep the native first request and timeout; denial or timeout opens a floating switch guide. |
| Restricted permissions | Explain Screen Time / administrator restrictions instead of suggesting another prompt. |

Microphone and Speech Recognition cannot be added to their lists by dragging.
Their guide labels its animated switch as an example and directs the user to the
real switch. The guide explains missing entries and any macOS-requested restart.
Accessibility remains unavailable in the App Store build, which uses clipboard
output. Input Monitoring stays available there.

Reduce Motion uses the static native helper for all four permissions (with a
Show App fallback for permissions supporting manual addition). The guide uses
read-only status checks every half second and dismisses on a verified grant or
when Settings quits, with a five-minute upper bound. Dismissal does not grant
access, and no permission is reset by this feature.

## Verification

`script/build_and_run.sh --verify` builds a separate development bundle and checks
that it launches. The Codex Run action uses the same script. For isolated UI
inspection, set `SPEAK_CORE_JOURNEY_PROFILE` to a fresh UUID; the existing Debug
fixture isolates data and reports denied permission states. Use a normal test
identity when checking real grants.


- `make test`: permission recovery policy and existing permission tests; package
  manifest parity includes PermissionFlow.
- `make lint`: baseline SwiftLint.
- Build `SpeakApp` directly and with `-Xswiftc -DAPP_STORE`.
- Launch a bundled development app. From each permission surface, open Settings
  and verify that the guide appears above Settings, stays readable, and can be
  dismissed. Accessibility/Input Monitoring should show the current bundle.
- Move Settings, switch between permission guides and close/reopen the helper.
  Grant a missing permission manually and verify the app status updates and the
  helper closes. Only reset permissions on a disposable test identity.
- Check Reduce Motion, VoiceOver labels and the denied/restricted recovery copy.

A guide being visible proves its UI; a real TCC grant and working recording or
hotkey/text insertion remain separate checks.
