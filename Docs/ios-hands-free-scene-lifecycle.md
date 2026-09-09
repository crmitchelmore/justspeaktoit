# iOS hands-free scene lifecycle

Hands-free listening is foreground-only. Leaving the active scene stops the detector and finishes an owned utterance through the normal shared-result and History path. Returning to the active scene refreshes available results; listening requires an explicit arm action.

Scene inactivity uses the controlled termination path introduced for capture disruption (#935), with a normal stopped outcome instead of a microphone-change alert. Route handling remains owned by #935; interruption policy is owned by #936.

## Finalisation and ownership

- Off, arming and armed sessions stop without creating or cancelling a recording result. Pending detector startup is invalidated before asynchronous teardown.
- A recording or already-finalising utterance retains ownership through its single stop operation. Repeated inactive/background events, Stop and subsequent disruption cannot cancel that result or restart listening.
- Hands-free finalisation holds a UIKit background assertion for up to ten seconds. Provider completion, deadline expiry and system expiration settle one result. Expiry detaches provider callbacks, releases the owned capture and preserves available partial text in the normal shared-result/History path while reporting incomplete finalisation. Empty input remains empty.
- Rearming permission is evaluated when the result arrives, not captured when Stop begins. Scene termination also prevents a suspended detector reconfiguration from restarting the microphone.
- Explicit user Cancel/disarm during ordinary foreground recording retains its cancellation semantics. A lifecycle stop already preserving an utterance cannot be converted into Cancel by a second stop action.

## Verification

`HandsFreeSceneLifecycleTests` exercises scene transitions and controllable startup/finalisation races at the iOS coordinator boundaries. `HandsFreeCaptureFinalisationTests` exercises normal completion, deadline expiry and system expiration with a suspended provider. These tests do not establish physical microphone or background execution behaviour.

Build the iOS test bundle with:

```sh
TUIST_IOS_KEYBOARD=1 tuist generate --no-open
xcodebuild build-for-testing -workspace "Just Speak to It.xcworkspace" \
  -scheme SpeakiOS -destination "generic/platform=iOS Simulator" \
  -derivedDataPath /tmp/justspeak-942-derived -jobs 4 \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

Run the iOS tests on an available simulator in CI. Physical iPhone verification remains a separate gate: dictate identifiable text, then test phone lock, Control Centre, Notification Centre and an available Face ID/system prompt. Record actual scene/audio-event sequences; overlays need not produce identical events. Verify saved text and one History entry, microphone shutdown, a stopped Live Activity, truthful failure reporting and explicit re-arm after return. Test a call/Siri overlap together with #936. Repeat while already finalising, with empty input and with an interrupted/failed finalisation.
