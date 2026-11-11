# System resources status

Issue #1471. Speak lists every system resource it holds (microphone, audio
output, provider connections, on-device models, the hotkey listener, Live
Activities) with the reason and the start time. Each item can be released
individually, or all at once with **Release Everything**.

## Shared model

`Sources/SpeakCore/SystemResources/` holds the shared model.

- `SystemResourceRegistry.shared.acquire(kind:title:reason:owner:detail:releaseTitle:release:)`
  records a hold and returns a token. When the resource is let go, the owner
  calls `token.end()`. A token that is deallocated also ends its hold.
- `release` only asks the owner to stop. The hold stays listed until the
  owner ends its token, so a release that fails stays visible.
- A hold with no `release` closure has no button. It ends with the hold that
  owns it; for example, a provider socket ends with its dictation.
- `MicrophoneUseAuditor` compares the registry with what the OS reports.
  After a 3-second grace period, an open microphone that no hold claims is
  reported as `unattributed` and logged once, together with the holds at that
  moment.

## Adding a holder

Register the hold where the resource is acquired, and end it on every path
that releases the resource. If an owner already publishes its state, you can
add a small adapter to the platform monitor instead
(`SystemResourceMonitor` on macOS, `IOSSystemResourceMonitor` on iOS).

## Where it appears

- **macOS**: Settings › Permissions › *System resources in use*. The menu-bar
  menu also has a quick view, with per-item release and Release Everything.
  Core Audio (`kAudioProcessPropertyIsRunningInput`, macOS 14.2+) supplies the
  OS view of the microphone. Release Everything does not stop the hotkey
  listener; that has its own *Pause hotkey* button.
- **iOS**: Settings › *System resources in use*. Instant Dictation readiness
  keeps the microphone open for up to four hours for the keyboard, and
  restarts each time the app opens. This is the usual reason for an
  unexplained microphone indicator on iOS. Status names it and can turn it off.
- **Linux** (#1473): Settings › General › *System resources in use*. The
  shared desktop host (`DesktopHostSystemResources.swift`) registers its
  holds from the controller state that owns them, so a hold ends when that
  state changes: dictation, the provider socket, hotkey warm-up, hands-free
  listening, Compare Models, microphone preparation, cleanup-connection
  warm-up and speech playback. `LinuxShortcuts` registers the hotkey
  listener, which has no release button. PulseAudio/PipeWire supplies the OS
  view: a non-corked source output from this process, excluding monitor
  sources. `DesktopSystemResourcesMonitor` (SpeakDesktop) polls it every 2
  seconds and logs an unclaimed microphone once per episode to stderr.
- **Windows**: the shared host registers the same holds, but there is no
  Status card, OS microphone probe or hotkey-hook hold yet. Those need
  Windows testing. Once `NativeCallbackContext<T>` (#1472) lands, a native
  context's retire point is where a platform-owned hold should end.

On desktop, Release Everything stops recordings, playback, listening and
warm-ups. The hotkey keeps working.
