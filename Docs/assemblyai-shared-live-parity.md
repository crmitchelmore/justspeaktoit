# AssemblyAI shared Mac live route

The macOS `assemblyai/` live route now selects `SharedClientLiveController` and
`AssemblyAILiveClient`. The batch `AssemblyAITranscriptionProvider`, its model
mapping and both batch/catalogue tests remain unchanged. No other dedicated
provider or iOS capture adapter is removed by this fold.

| Contract | Shared path |
|---|---|
| Selection and credentials | The configured catalogue model resolves through `LiveTranscriptionRouting`; the same `assemblyai.apiKey` owner is loaded before capture. The legacy dedicated factory ignored its model/language arguments; the shared factory uses the canonical API model and retains provider-native language detection. |
| Settings | `AppSettings.liveClientOptions` passes explicit recognition keyterms, model finalization budget and stop grace. No formatting prompt or `format_turns` is added. Timing is frozen when the client is constructed rather than reread during stop. |
| Capture ownership | Both paths claim a prepared `LiveInputEngines` engine and a preferred-input session, validate the input format and release the session on failed start or stop. Native microphone permission remains required. |
| Converter and framing | The existing shared converter queue drains queued tap work and converter tail before client finish. Core repacks PCM16 mono at 16 kHz into 100 ms frames and pads only a nonempty final residual below 50 ms. The shared tap is 4096 frames rather than the former 1024; identical real capture latency is **not** claimed. |
| First words and fallback | Core retains the newest five seconds before Begin, sends only after Begin, and permits one EU-to-global pre-Begin fallback guarded by run/socket identity. |
| Stop | Capture stops and converter tail drains before bounded admitted-send completion, ForceEndpoint, formatted-final/model budget, user grace and Terminate. No new budget or second grace is added. |
| Text and boundaries | Cumulative display replaces interim text; formatted turns replace by turn order. Explicit utterance callbacks precede display. The terminal full snapshot preserves segments and outstanding interim without a second whole-history polish boundary. |
| Result metadata | Confirmed segments retain zero timing; confidence, cost and raw payload remain absent when the provider snapshot supplies none. Duration is actual controller capture duration; no metadata is fabricated. |
| Cancellation and replacement | The existing shared controller captures run/client identity, aborts cancelled finish and refuses stale queued callbacks. The switcher retains serialized cached-controller teardown and its existing local/OpenAI exceptions. |
| Diagnostics | The obsolete Mac delegate's private close-reason OSLog is intentionally removed. Core retains per-connection structured close-code errors. Neither request URLs, keys nor transcript content are added to logging. |
| Compare Models | The lane's existing `LiveTranscriptionClientFactory.makeClient(for:apiKey:language:keywords:azureEndpoint:)` call shape remains unchanged; the obsolete Mac-only `AssemblyAITranscriptionProvider.createLiveTranscriber` is removed. A lane consumes cumulative callbacks and replaces them with `finishAndWait`'s full-session return, with its existing outer deadline and owned stop. |

## Coverage and evidence boundary

No existing test is deleted. The two `AssemblyAITranscriptionProviderTests` methods
still exercise the retained batch provider. Existing Core framing, turn assembly,
options/legacy factory, receive-failure and streaming contract suites remain;
`SharedClientAssemblyAIParityTests` supplies five actual shared-client/controller
synthetic cases. Those five cases passed at candidate EA in Debug and Release
before this route change; that receipt does not qualify this new source.

New `AssemblyAISharedRouteTests` checks the production switcher's selected shared
instance, prepared-input capability and retained OpenAI/local owners.
`ComparisonAssemblyAILaneTests` feeds the actual Core client through an inert
transport and the actual lane: complete-session replacement, final tail once,
cancelled finish and unrelated-lane survival. The internal lane factory seam has
no production effect when unset; the original initializer and open method remain.
All new methods require native execution; syntax/lint alone is not a test pass.

Before merge/closure, run normal Apple native tests, iOS shared-client build/tests
and public API checks. Record actual Mac provider acceptance with existing
authorized credentials: immediate first word, release after final word, multiple
utterances/Live Polish, unusual keyterm, silent/short capture, cancel/restart and
preferred microphone release; check History/output contain first/final words once.
The reviewed plan also retains real iOS provider smoke for framing/finish.
Synthetic sockets do not establish microphone latency, installed behavior or
provider/device acceptance. This source change is not a release receipt.
