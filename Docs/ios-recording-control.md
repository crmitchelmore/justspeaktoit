# Recording control state and verification

The installed control keeps the kind
`com.justspeaktoit.ios.JustSpeakToItWidgetExtension`, shared through
`CaptureSurfaceKind.transcriptionControl`. Its provider reads
`SharedTranscriptionState.isRecording` from the App Group.

Every real flag transition publishes the new value before requesting a targeted
Control Center reload on iOS 18 or later. Both the in-app coordinator and headless
recording service use this setter, including their existing stop, cancel and
startup-unwind paths. Error cleanup uses the same boundary when its owner ends
the recording. Transcript updates and repeated flag values do not request reloads.
This does not change when a recording owner decides to stop or how it cleans up
audio resources.

`ToggleTranscriptionControlIntent` remains a `SetValueIntent`: `true` requests
start and `false` requests stop. It never inverts the live state to compensate for
a cached system display. A repeated start leaves starting/recording alone; a stop
during startup invokes the existing cancellation path. Repeated stops during
finalisation are no-ops. A start during finalisation reports that recording is
still stopping. If the service is idle but the shared flag identifies an in-app
recording, either requested value reports the existing in-app stop guidance.
It cannot stop that separate owner or start a second recorder.

Apple documents [app-requested control reloads and provider refresh after intent
completion](https://developer.apple.com/documentation/widgetkit/updating-controls-locally-and-remotely).
A reload is a request to the system, not proof of immediate rendering or a
guarantee that a previously cached display cannot issue a stale requested value.

## Automated checks

`SharedTranscriptionStateTests` uses isolated defaults and an injected reload
callback to check the value visible to another reader at reload time, cleanup of
the start time, both owner write patterns, unavailable storage and absence of
reload churn. `RecordingControlRequestTests` checks desired-value decisions and
their interaction with the existing lifecycle coordinator, including cancelled
startup and repeated requests. These tests run on macOS as well as iOS; the native
WidgetKit call is iOS-only. `RecordingLifecycleCoordinatorTests` covers existing
startup failure, cancellation settlement and stop guards.

Build the SpeakiOS scheme for iOS to compile the app and its embedded control
extension. Hosted iOS tests and a physical-device exercise remain separate gates.

## Physical iPhone gate

Use an installed development/TestFlight build with ordinary system intent policy;
record the build, iOS version, device and selected result destination. Test the
Control Center control and a supported Action Button control binding with normal
authentication policy, including locked-device invocation:

1. Start and stop externally using the existing recording intents; inspect the
   control's displayed state after each transition.
2. Stop a headless recording from its Live Activity. Check control state,
   microphone shutdown and the selected clipboard/history destination.
3. Start in-app, invoke the control and confirm explicit in-app stop guidance.
   Stop in-app and check that the control refreshes without a second recorder.
4. Cancel during startup and exercise a startup failure. Verify the microphone
   stays off after cleanup and the control returns to idle.
5. Exercise a mid-session provider error through the owner's existing cleanup.
   Check the displayed state after cleanup, microphone shutdown and preserved
   result routing. Capture any owner lifecycle failure separately.
6. Repeat requested start/stop values while starting, recording, stopping and
   idle. Confirm that repeated requests never reverse an achieved state, and that
   finalisation is not interrupted by a new start.

Capture observed refresh timing and any stale display separately from whether the
requested action was honoured. Unit tests and an unsigned iOS build do not prove
locked-device execution, physical microphone behaviour or system refresh timing.
