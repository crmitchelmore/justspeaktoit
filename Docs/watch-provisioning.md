# Apple Watch provisioning checklist

The watch app and its watch-face complication are feature-flagged
(`TUIST_WATCH_APP=1 tuist generate`). Alpha TestFlight builds turn the flag on
for owner review and Stable builds keep it off. An Alpha build leaves the watch
app out, with the reason in its step summary, until both watch profiles carry
the watch App Group (see
[Alpha preview targets](ios-testflight-release.md#alpha-preview-targets)).
Default generates and CI builds are unaffected.

## Bundle identifiers

| Target | Bundle id | Product |
| --- | --- | --- |
| `JustSpeakWatchApp` | `com.justspeaktoit.ios.watchkitapp` | watchOS app (companion of `com.justspeaktoit.ios`) |
| `JustSpeakWatchWidgetExtension` | `com.justspeaktoit.ios.watchkitapp.widget` | WidgetKit extension embedded in the watch app |

Alpha maps every id under the Alpha app: `com.justspeaktoit.ios.alpha.watchkitapp`
and `com.justspeaktoit.ios.alpha.watchkitapp.widget`, with the App Group
`group.com.justspeaktoit.watch.alpha` (`watchAppGroup` in `ReleaseTrains.json`).

The complication's suffix is `watchkitapp.widget` on every train. Apple refused
to register `com.justspeaktoit.ios.alpha.watchkitapp.complication` for the team
("not available"), and Stable had never shipped the watch app, so the old
`watchkitapp.complication` suffix was retired rather than kept per train.
Linking the watch App Group to the new identifier is still a manual portal step
(see [Portal steps](#portal-steps)).

Extension ids must stay prefixed by the containing app's id, and the watch
app's id must stay prefixed by the iPhone app's id — renaming any of the three
means re-registering all of them.

## App Group

The complication runs in its own process, so it cannot see the watch app's
container. Both watch targets therefore declare:

```text
group.com.justspeaktoit.watch
```

This is deliberately **not** the iOS group (`group.com.justspeaktoit.ios`):
App Group containers are per-device, so the watch pair needs its own
registration. The container holds `captures.json` (the capture queue),
`watch-complication.json` (what the face renders) and
`watch-recording-request.pending-*.json` (face taps waiting for the app to perform them) —
see `Sources/SpeakWatchCore/WatchSharedContainer.swift`.

Without the entitlement the app still records and transfers normally: the
shared container resolver falls back to Application Support and the
complication simply shows the idle state. An existing install's `captures.json`
is migrated out of Application Support the first time the App Group is
available.

## Portal steps

Alpha TestFlight (`release-ios.yml` and `apple-profiles.yml` do the rest):

1. The workflows register `com.justspeaktoit.ios.alpha.watchkitapp` and
   `com.justspeaktoit.ios.alpha.watchkitapp.widget` when missing and
   enable **App Groups** on both through the App Store Connect API.
2. **Owner, in the Apple Developer portal:** register the App Group
   `group.com.justspeaktoit.watch.alpha` if it does not exist, then open each of
   the two Alpha watch identifiers, configure **App Groups** and tick that
   group. The API cannot make this association. After the first run registers
   `com.justspeaktoit.ios.alpha.watchkitapp.widget`, it needs this link too.
3. Run **Apple App IDs and profiles** (`apple-profiles.yml`). Its Alpha summary
   reports `Watch app: ready for Alpha` once both profiles carry the group.
   The next Alpha release then embeds the watch app; `TUIST_WATCH_PROFILE_NAME`
   and `TUIST_WATCH_WIDGET_PROFILE_NAME` feed `configureManualSigning` in
   `Project.swift`.

The Share extension (`com.justspeaktoit.ios.alpha.share`) follows the same
path with the existing group `group.com.justspeaktoit.ios.alpha`.

Stable (only when the watch app is approved for Stable):

1. Register `com.justspeaktoit.ios.watchkitapp` and
   `com.justspeaktoit.ios.watchkitapp.widget`, register the App Group
   `group.com.justspeaktoit.watch`, enable **App Groups** on both identifiers
   and associate that group with each.
2. Turn the flag on for Stable in the **Select Alpha preview targets** step.

Local device testing: `TUIST_WATCH_APP=1 tuist generate`, then let Xcode's
automatic signing create development profiles for both ids. (Automatic signing
fails on the watch targets until the App Group is associated, because both ship
an entitlements file.)

The watch `AppIcon` asset catalog is generated alongside the Mac/iOS artwork
   by `scripts/assets/generate-icon.swift` and bundled by the watch target. Validate the
   icon and provisioning in the archived Watch app before App Store submission.

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
- [ ] Tap the complication on the watch face with the app not running: watch
      faces do not run intent buttons in place, so the app opens through the
      complication's `widgetURL` and starts recording at once
- [ ] On watchOS 11+, tap the Smart Stack widget with the app not running:
      recording starts through `AudioRecordingIntent` without foreground UI and
      watchOS shows its system recording indicator for the active audio session
- [ ] On watchOS 10, tap the complication: the app opens and performs the
      pending request on activation
- [ ] Tap again: recording stops and the capture enters the transfer queue
- [ ] Complication glyph tracks state: mic (idle) → stop (recording) → arrow
      (sending) → check (in history), and warning on failure
- [ ] Corner complication's curved label shows the short state text
- [ ] Smart Stack rectangular widget shows the latest capture status and rises
      in the stack while a capture is recording or in flight
- [ ] Complication state survives the watch app being terminated (it is read
      from the App Group container, not from the running app)
- [ ] Stop the watch app during a recording. The face goes back to idle in
      five minutes, because the recording heartbeat stops
- [ ] With the App Group entitlement missing, recording still works and the
      complication shows idle rather than failing
