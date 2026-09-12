# iOS recording loss reporting

Issue #950 reports actual capture-copy rejection and recording-writer loss. It does not change pool limits, provider transport, finalisation policy, retries, History recovery or CloudKit.

Each capture run owns a fresh `RecordingLossReport`. All four live taps (Apple analyser, legacy Apple, OpenAI and shared clients) count rejected buffers and sum `frameLength / sampleRate` before returning. The pool no longer logs every rejected checkout. The audio thread does no per-drop notification or UI work.

All four writer owners, including batch, attach the existing persistence callback. `RecordingLossReporting` polls at 100 ms on the main actor and emits at most one initial nonfatal warning. Accepted overflow alone remains healthy. Stop reads the final diagnostics after the owner's existing processing queue and writer drain; it does not rely on delivery of the first callback. Retired reports reject late notifications. Explicit Cancel still discards its partial file and warning.

Foreground and hardware-trigger owners carry the final summary into the existing local History `errorMessage` when a nonempty transcript normally creates an entry. Immediate automatic polish preserves that error surface on success and includes it alongside a polish failure. No diagnostic schema or recording sidecar is added; later recording-library listings still do not establish completeness. Batch warns that loss in its input recording may also affect its transcript. A writer-only warning never enters an error callback or stops a healthy live provider.

## Automated verification

`RecordingLossReportTests` exercises actual PCM-duration accounting, concurrent capture rejection, healthy overflow, and final totals independent of delayed callbacks. `RecordingLossReportingTests` uses real capture pools, writer admission and AAC files, including controlled writer stalls and write errors, factory warning forwarding across all supported adapter kinds, and History save/reload. `RecordingLossOwnerLifecycleTests` calls the real adapters' start/stop/cancel methods with injected microphone/provider setup. These tests do not exercise a physical microphone or real remote recogniser.

Run repository tests with Apple Swift and four jobs, strict repository SwiftLint, and `xcodebuild build-for-testing` for the `SpeakiOS` scheme. The iOS-guarded tests require hosted simulator execution: the local simulator is unavailable due to existing external-volume permissions, and this change does not alter that configuration.

## Physical iPhone acceptance

Use disposable recordings and controlled stalls separately in capture processing and persistence. Verify the intended limit/failure was actually reached, one initial warning, retained audio/text, the final local History summary after relaunch, and a clean next recording. Cover both Apple paths where supported, OpenAI, one shared backend and batch. Verify writer-only pressure leaves live transcription running. Record device, iOS/build, input sample rate/frame lengths and injected stall/failure details. Do not log secrets or audio/transcript content. This gate remains separate from simulator fault injection and compilation.
