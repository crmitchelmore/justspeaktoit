# #1121 sherpa-onnx runtime evidence and decision brief

## Decision status

The requested trailing-90-day sherpa usage and user counts are **unavailable from the qualified production schema**. They are not zero. No runtime removal, native-link implementation, telemetry change, model migration or App Store guard change is authorised by this evidence task. Retain the current path while Chris chooses a direction after a qualified source is available, or explicitly accepts the remaining uncertainty.

## Verified analytics evidence

- Organization: Just Speak To It, `01a02667-88df-0000-4772-ee67677b0954`.
- Project: Just Speak to It – Production, `254700`, UTC: [production project](https://eu.posthog.com/project/254700/).
- Inspection date: 12 September 2026.
- Work performed: authenticated read-only schema discovery/inspection only. No HogQL, trend, distinct-user or installation aggregate was executed, so there is no executed 90-day start/end window or count to report.
- Observed custom events returned by the schema: `app_active_daily`, `analytics_opt_in`, `first_transcription_succeeded`, and `onboarding_completed`.
- `transcription_completed` was absent from the returned schema. System event templates marked “not seen in the last 30 days” are templates, not collected-event evidence and not a 90-day observation window.
- Observed `first_transcription_succeeded` properties include `engine_type` and `provider_type`, but not `model_family`, selected model, or a runtime identifier. Returned `engine_type` values contained only `cloud`.

These facts cannot establish sherpa usage or non-usage. `first_transcription_succeeded` measures activation rather than repeated runtime use, and analytics collection is consent-gated. Offline and opted-out installs, plus unknown historical schema coverage, prevent extrapolation to the installed population. Therefore:

- qualified 90-day sherpa observations: **unavailable, not 0**;
- qualified 90-day distinct users/installations: **unavailable, not 0**;
- estimated removal impact: **not measurable from this schema**.

## Runtime attribution limits

- `AnalyticsModelFamily` and `AnalyticsTranscriptionDimensions.properties` in `Sources/SpeakCore/ProductAnalyticsDimensions.swift` define typed `model_family`, `engine_type`, and `provider_type` dimensions. The `parakeet` family intentionally includes both sherpa-onnx and FluidAudio builds; `nemotron` and `zipformer` are annotated as sherpa-backed.
- `ProductAnalytics.capture(_:)` in `Sources/SpeakCore/ProductAnalytics.swift` exits unless consent permits collection. Its first-success payload contains provider and engine only, whereas transcription lifecycle dimensions can contain model family—but those events were not present in the discovered production schema.
- `SwitchingLiveTranscriber.controller(for:)` in `Sources/SpeakApp/SwitchingLiveTranscriber.swift` routes `FluidAudioParakeetModel` and `WhisperKitStreamingModel` before the broad `local/streaming/` sherpa branch. A prefix count would therefore conflate native and sherpa runtimes; even a `parakeet` family count remains ambiguous.
- `SherpaOnnxRuntimeManager.installRuntime()` in `Sources/SpeakApp/SherpaOnnxRuntimeManager.swift` creates a virtual environment and installs `sherpa-onnx==1.13.2` with pip. This is the path under decision.
- `LocalPostProcessingModelManager` separately creates a Python environment, installs `llama-cpp-python==0.3.23`, and invokes it through `LocalProcessRunner`. A sherpa-only change can promise “no Python in the sherpa path,” not “no Python anywhere in SpeakApp”; shared process helpers cannot be removed on this evidence.

## Evidence required before a usage claim

Any additional source must first be qualified for:

1. the production organization/project identity above;
2. complete event coverage across an explicitly bounded 90-day UTC interval;
3. stable event definitions and known historical property availability;
4. a runtime-discriminating field that separates sherpa from FluidAudio and WhisperKit; and
5. a valid distinct opted-in user or installation identity.

Only then should a read-only aggregate report total qualified observations and distinct opted-in users separately. Ambiguous Parakeet rows and missing/unknown runtime fields must remain separate rather than being assigned to sherpa. Consent and offline undercoverage must remain explicit, and aggregate evidence is sufficient—no personal identifiers or transcripts should be exported.

## Chris’s two implementation choices

1. **Native-link sherpa while preserving models.** This could remove the sherpa venv/pip first-use failure surface while retaining privacy-focused local Nemotron, Zipformer and sherpa-backed Parakeet choices. It requires a separately approved plan covering official runtime release/API, checksum and Apple-platform qualification; fixture decoding; packaging/App Store implications; public model compatibility; and real Mac tests. Available analytics cannot quantify how many users benefit.
2. **Remove the sherpa path with precise migration.** This could reduce bootstrap and maintenance cost, but may remove valued local/private choices. It requires exact model ownership, saved-selection migration/fallback behaviour, public API compatibility checks, and qualified impact evidence—or Chris’s explicit acceptance that impact is unknown. Native FluidAudio and WhisperKit routes must remain intact.

Until Chris selects one of these branches, the reviewed outcome is evidence-only: keep the current runtime, add no telemetry, and do not interpret missing data as near-zero use.
