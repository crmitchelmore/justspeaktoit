# Apple Watch provisioning checklist

The watch app and its watch-face complication are feature-flagged
(`TUIST_WATCH_APP=1 tuist generate`) and excluded from release signing until
the portal work below is done. Default generates, CI release builds and
TestFlight are unaffected while the flag is off.

## Bundle identifiers

| Target | Bundle id | Product |
| --- | --- | --- |
| `JustSpeakWatchApp` | `com.justspeaktoit.ios.watchkitapp` | watchOS app (companion of `com.justspeaktoit.ios`) |
| `JustSpeakWatchWidgetExtension` | `com.justspeaktoit.ios.watchkitapp.complication` | WidgetKit extension embedded in the watch app |

Extension ids must stay prefixed by the containing app's id, and the watch
app's id must stay prefixed by the iPhone app's id — renaming any of the three
means re-registering all of them.

## App Group

The complication runs in its own process, so it cannot see the watch app's
container. Both watch targets therefore declare:

```
group.com.justspeaktoit.watch
```

This is deliberately **not** the iOS group (`group.com.justspeaktoit.ios`):
App Group containers are per-device, so the watch pair needs its own
registration. The container holds `captures.json` (the capture queue),
`watch-complication.json` (what the face renders) and
`watch-recording-request.json` (a face tap waiting for the app to perform it) —
see `Sources/SpeakCore/WatchSharedContainer.swift`.

Without the entitlement the app still records and transfers normally: the
shared container resolver falls back to Application Support and the
complication simply shows the idle state. An existing install's `captures.json`
is migrated out of Application Support the first time the App Group is
available.

## Portal steps (required before shipping)

1. Register the bundle id `com.justspeaktoit.ios.watchkitapp`.
2. Register the bundle id `com.justspeaktoit.ios.watchkitapp.complication`.
3. Register the App Group `group.com.justspeaktoit.watch`, then enable **App
   Groups** on *both* watch identifiers and associate that group with each.
   (Automatic signing fails on the watch targets until this is done, because
   both now ship an entitlements file.)
4. Local device testing: `TUIST_WATCH_APP=1 tuist generate`, then let Xcode's
   automatic signing create the development profiles for both ids.
5. App Store / TestFlight: create App Store provisioning profiles for both
   watch ids, add them as repo secrets, and extend `release-ios.yml` the way
   the widget/keyboard profiles are handled. The manifest hooks already exist:
   `WATCH_PROFILE_NAME` and `WATCH_WIDGET_PROFILE_NAME` feed
   `configureManualSigning` in `Project.swift`. Add `TUIST_WATCH_APP=1` to the
   release generate step at that point.
6. A watch `AppIcon` asset catalog is still needed for App Store submission
   (development builds run without one).

## Device checklist

Watch capture (from the watch app):

- [ ] `TUIST_WATCH_APP=1 tuist generate`, install both apps on a paired iPhone + Watch
- [ ] Record on watch (mic permission prompt appears once); elapsed time ticks; stop
- [ ] Capture progresses in the watch list: Sending → On iPhone → In history
- [ ] Transcript appears in iPhone history and syncs to Mac history
- [ ] Airplane-mode phone: capture stays queued on watch and arrives after reconnect
- [ ] Kill the iPhone app, record on watch: the transfer background-launches it
- [ ] Wrong/no API key: watch shows the failed state and reason
- [ ] Double Tap gesture toggles recording on watchOS 11+ hardware

Complication and Smart Stack (this feature):

- [ ] Both watch targets install; the complication appears in the face editor
      under **Just Speak to It** for circular and corner slots
- [ ] Tap the complication with the app not running: the app comes forward and
      recording starts (the pending request is performed on activation)
- [ ] Tap again: recording stops and the capture enters the transfer queue
- [ ] Complication glyph tracks state: mic (idle) → stop (recording) → arrow
      (sending) → check (in history), and warning on failure
- [ ] Corner complication's curved label shows the short state text
- [ ] Smart Stack rectangular widget shows the latest capture status and rises
      in the stack while a capture is recording or in flight
- [ ] Complication state survives the watch app being terminated (it is read
      from the App Group container, not from the running app)
- [ ] With the App Group entitlement missing, recording still works and the
      complication shows idle rather than failing
