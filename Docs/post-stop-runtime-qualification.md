# Post-stop intent runtime qualification

The selected shipping SDK blocks this experiment. No production adoption is proposed.
The raw-once clipboard contract already removes the old polishing placeholder;
longer runtime must demonstrate a separate benefit before changing recording ownership.

This is the qualification dossier for [#1018](https://github.com/crmitchelmore/justspeaktoit/issues/1018),
following the [approved narrow plan](https://github.com/crmitchelmore/justspeaktoit/blob/decbdc1e9420ea666f8c70169f892fd583c40235/Docs/issue-plans-2026-09-12/1018.md).
It does not authorize a toolchain upgrade, new scheduler, clipboard behavior or release.

## SDK evidence, 26 October 2026

The selected developer directory was `/Applications/Xcode.app/Contents/Developer`.
Read-only inspection of Xcode's `Info.plist`, the device SDK's `SDKSettings.json`
and its public AppIntents `.swiftinterface` produced:

| Item | Observed result |
| --- | --- |
| Installed/selected Xcode | 26.2, build 17C51 |
| Selected device SDK | iPhoneOS 26.2 |
| `LongRunningIntent` | Absent |
| `allowedExecutionTargets` / `IntentExecutionTargets` | Absent |
| `CancellableIntent` | Absent |
| `ProgressReportingIntent` | Present |
| `performBackgroundTask` | Absent |

Apple's official DocC declarations retrieved on the same date publish:

| API | Published iOS availability and shape |
| --- | --- |
| [LongRunningIntent](https://developer.apple.com/documentation/appintents/longrunningintent) | 27.0; inherits `ProgressReportingIntent` |
| [allowedExecutionTargets](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets) | 27.0; static `IntentExecutionTargets` property |
| [CancellableIntent](https://developer.apple.com/documentation/appintents/cancellableintent) | 26.4; inherits `AppIntent` |
| [performBackgroundTask](https://developer.apple.com/documentation/appintents/longrunningintent/performbackgroundtask(options:operation:oncancel:)) | 27.0; async throwing generic operation with a Sendable cancellation-reason callback, constrained to `Self: CancellableIntent` |

Published documentation does not add symbols to an older SDK. A runtime
`#available` check cannot make an unknown declaration compile. The local scan is
not a compiler probe or runtime result. Neither compilation of the proposed
adapter nor a physical iOS 27 comparison was executed; no compiler diagnostic or
OS behavior is claimed. Stop adoption at this SDK gate rather than add dead
conformances to shipping targets.

To repeat the read-only interface scan with the selected Xcode:

```sh
developer=$(xcode-select -p)
sdk="$developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
plutil -extract CFBundleShortVersionString raw "$developer/../Info.plist"
plutil -extract DTXcodeBuild raw "$developer/../Info.plist"
plutil -extract Version raw "$sdk/SDKSettings.json"
rg -n 'LongRunningIntent|allowedExecutionTargets|IntentExecutionTargets|CancellableIntent|ProgressReportingIntent|performBackgroundTask' \
  "$sdk"/System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/*.swiftinterface
```

On an authorized Apple runner with a supported shipping SDK, create an isolated
qualification file outside the app and type-check these names first:

```swift
import AppIntents

@available(iOS 27.0, *)
func executionTargets<I: AppIntent>(for _: I.Type) -> IntentExecutionTargets {
    I.allowedExecutionTargets
}

@available(iOS 27.0, *)
func requireLongRunning<I: LongRunningIntent & CancellableIntent>(_: I.Type) {}
```

For a file at `$qualification_file`, the presence probe command is:

```sh
xcrun swiftc -typecheck -sdk "$sdk" -target arm64-apple-ios17.0 "$qualification_file"
```

This command is documented, **not executed**. Preserve the project deployment
floor and record exact SDK/compiler output. Symbol presence alone is not the
controlled runtime comparison or approval to change the release toolchain.

## Current baseline to preserve

- `TranscriptionRecordingService.startPostProcessing` owns an
  `AutomaticPolishOperation` under `BackgroundTaskAssertion`. The OS may refuse
  or expire that assertion; there is no promised fixed runtime allocation.
- Stop copies raw text once when the destination requests a copy. Successful
  polish updates its History row and guarded completed result, with no later
  automatic clipboard write. Empty and History Only output remain untouched.
- `StopTranscriptionRecordingIntent` is an audio/Live Activity intent and respects
  separately owned foreground capture. Authenticated `StopDictationIntent` has
  an optional Wait For Polish path with a whole-operation budget and raw fallback.
- Cancellation/expiration must settle the operation and processing indicator once,
  preserve raw History and leave a replacement recording alone. A wrapper around
  a method that starts detached work and returns cannot extend that work's lifetime.

Alpha39 source `53fcfae1c225980dfe4341fa79aee192fdcb7dda` passed 567 iOS simulator
cases with zero failures/skips in
[CI 40303615752](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40303615752),
including ten `AutomaticPolishOperationTests` and fifteen
`TranscriptionRecordingServiceTextTests`. These support the existing baseline;
they do not exercise the new runtime or prove physical/background clipboard delivery.

## Controlled comparison after the SDK gate

Use a test-only local HTTP fixture and synthetic finalized raw text, matching
History identity and network delay between baseline and candidate. No provider
credits or recording-phase microphone work are needed. Compare immediate success,
slow success, no progress, timeout, cancellation, failure and disconnect.
Only wrap work actually awaited inside `performBackgroundTask`. Progress must
represent completed stages or actual bytes; never animate a guessed percentage.

Record non-content run/process identity, entry point, app/lock state, raw-ready
and completion times, assertion expiration, cancellation callback, History result
and visible activities. Keep transcript, credentials and response bodies out of
artifacts. Any larger lifecycle restructuring requires a separate review.

| Physical supported-iPhone scenario | Required observation | Current evidence |
| --- | --- | --- |
| Foreground, background and locked slow response | Actual baseline/candidate completion and visible progress; raw result remains available | Not run |
| No progress, user cancellation, reproducible OS expiration | Truthful failure/cancellation, exactly-once cleanup and retained raw History | Not run |
| Repeated Stop and rapid restart | No repeated output or effect on a replacement run | Not run |
| Existing audio Live Activity plus system task activity | No duplicate or misleading result surfaces | Not run |
| Suspension, termination and relaunch | Observed recoverability; no guaranteed termination callback claim | Not run |
| Authenticated versus ordinary Stop | Private text remains authenticated; ordinary Stop adds no clipboard-overwriting dialog | Not run |
| Unsupported OS and permission refusal | Existing fallback/ownership behavior; no new microphone acquisition after Stop | Not run |

The disposition is SDK-blocked and runtime benefit unknown. Retain current code.
Production adoption requires a separately reviewed bounded change after an actual
supported-device improvement, meaningful progress and safe cancellation are proved.
This dossier is neither a device receipt nor an issue-completion or shipment claim.
