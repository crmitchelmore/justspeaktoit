# Issue 1121: telemetry qualification, 12 September 2026

Read-only schema inspection in the verified Just Speak To It organization (01a02667-88df-0000-4772-ee67677b0954), Just Speak to It – Production project 254700, UTC.

Project: https://eu.posthog.com/project/254700/

The connected schema lists four observed custom events: app_active_daily, analytics_opt_in, first_transcription_succeeded, onboarding_completed. It does not list transcription_completed. System event templates marked not seen in the last30days are not collected evidence.

first_transcription_succeeded properties include engine_type and provider_type. They do not include model_family, selected model, or runtime identifiers. The returned engine_type values contain cloud only.

These observations do not establish ninety-day sherpa usage, user counts, or zero usage. No speculative query for unavailable fields was run. First-transcription events are activation evidence rather than repeat-use evidence. Consent, offline operation and schema history prevent extrapolation to the installed user population.

Code inspection in reviews/1121.json additionally establishes that the local/streaming prefix includes FluidAudio and WhisperKit, while Parakeet family combines FluidAudio and sherpa. Existing broad grouping therefore cannot safely identify the removal impact even if additional family events become available.

Conclusion: the requested runtime usage evidence is unavailable from the discovered production schema. Obtain a qualified existing source or separate explicit decision about further evidence collection before selecting native-link or removal. Do not add telemetry or change runtime under this qualification scope. Python is also used independently for local post-processing, so sherpa-only removal cannot promise no Python in SpeakApp.
