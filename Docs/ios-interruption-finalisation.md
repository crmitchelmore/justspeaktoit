# Controlled live interruption finalisation

An audio interruption ends an owned live capture through the same finalisation path as Stop. The recording owner retains available text and the provider's persisted audio, settles shared recording state, and applies the initiating flow's output policy. A successful interruption displays “Recording stopped because audio was interrupted.” It does not populate the deferred session error alert. Provider or finalisation failures remain errors and available partial text is retained.

Apple live, OpenAI Realtime and shared-client capture each subscribe while capturing. Only interruption-began notifications are terminal. Retiring either the interruption or engine-disruption path removes both subscriptions and invalidates queued callbacks. The backend stops audio input immediately; its owner alone drains and saves the result. Explicit Cancel suppresses pending History/output delivery. End notifications, including `shouldResume`, do not rearm or resume the recording.

Headless recordings reuse the destination captured at start. Keyboard-owned recordings reuse their original completion callback and nonce/retention policy. Foreground recordings retain their own History policy. Hands-free finishes an active utterance normally before disarming, or disarms an idle detector without cancelling somebody else's capture.

This change depends on #935 / PR #1032 and #934 / PR #1031. Same-session resume, grace timers, Resume intents, reconnects, batch interruption policy and Siri's recently-completed-result acknowledgement (#946) are separate work.

## Verification boundaries

Deterministic notification and injected owner/provider tests cover duplicate/ended events, original destinations, empty input, polishing, keyboard ownership, a delayed provider tail, foreground state, real drain failures, concurrent Stop/Cancel, and retired callbacks. Building these tests for iOS does not establish that they ran.

Physical iPhone validation remains required before claiming device acceptance: record recognisable text, then exercise incoming calls (answer and decline), an alarm and Siri. Record the events actually delivered, device/iOS/provider details, saved text/audio, UI/shared/Live Activity state and fresh explicit start after audio returns. Cover foreground, background and locked headless recording with Apple live, OpenAI Realtime and a shared backend; History Only and Copy & Polish; hands-free armed/active utterance; and keyboard capture. Check no stale error alert appears after a successful interruption. Capture Siri Stop ordering separately for #946. Simulator notification injection cannot establish microphone, Siri or background execution behaviour.
