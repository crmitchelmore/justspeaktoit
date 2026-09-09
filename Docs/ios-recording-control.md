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


## Native Control setup and action hints

In Settings → Action Button & Shortcuts, the iOS 18+ setup section introduces the
existing **Transcribe Voice** Control for the Action Button, Control Center and a
Lock Screen bottom slot. On iOS 17, only the retained Shortcuts route is offered.
Shortcuts remain available for Back Tap and automations on newer versions too.
The Lock Screen bottom control is separate from an accessory widget below the
clock. First-use permissions and possible unlocking/app opening are stated in the
screen; these setup instructions do not establish cold locked capture support.

The toggle label's `controlWidgetActionHint` describes entering its represented
state: `true` receives **Start dictation**, `false` receives **Stop dictation**.
This follows [Apple's Control action-hint example](https://developer.apple.com/videos/play/wwdc2024/10157/).
It does not invert the requested intent value or change the Control identity.
Setup follows Apple's [Action Button guide](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios),
[Control Center guide](https://support.apple.com/guide/iphone/use-and-customize-control-center-iph59095ec58/ios)
and [Lock Screen guide](https://support.apple.com/guide/iphone/create-a-custom-lock-screen-iph4d0e6c351/ios).

### Setup verification on physical iPhones

With the state/request changes from #941 integrated, run the following on
supported iOS 18.x and 26.x builds. Record app build, device, OS, destination,
actual picker labels, prompts and observed outcomes:

1. Follow all three setup routes, using Action Button hardware where available.
   Confirm Transcribe Voice is discoverable and existing placements still work.
2. Press and hold to start and stop. Check the system hint uses Start dictation
   when starting and Stop dictation when stopping. Repeat after an in-app or
   Live Activity state change, using the ownership checks above.
3. Run the retained Toggle Recording Shortcut and Back Tap binding. Check results
   respect the selected destination without adding a Copy to Clipboard action.
4. Repeat first-use and cold locked invocation; record permissions, unlock/app
   continuation or failure without treating a prompt as proof of capture.
5. Read the complete settings screen at default and largest accessibility text
   sizes and with VoiceOver. Check wrapping, step-number scaling, reading order,
   destination selection and access to the Open Shortcuts App button. On iOS 17,
   confirm native Control setup is absent and Shortcut setup remains usable.

The existing `ActionButtonSettingsUITests.testActionButtonDestinationCanBeConfigured`
checks destination selection and access to the retained Shortcut guidance. Build
and unit-test results do not substitute for these layout, accessibility, picker,
physical hint and microphone checks.
