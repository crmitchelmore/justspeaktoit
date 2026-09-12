# Issue value review — 12 September 2026

This is review evidence, not a replacement for the canonical issue tracker. The initial inventory contained 98 open issues and four open PRs. This checkpoint contains 14 completed independent issue reviews; the remaining issues are not yet assessed. Implementation and validation are separate from these recommendations.

## Method and product goals

Each issue receives its own value-review agent. Accepted scope goes to a different planning agent, then gpt-5.6-sol at medium reasoning for implementation. Reviews use source baseline `51286c58`, current issue bodies/comments, open PRs and recorded project decisions.

Priorities: reliable and fast dictation; preserve first and final words; privacy and on-device options; transparent BYOK costs; native accessible controls; shared catalogues with deliberate platform differences. Refactor incrementally rather than rewrite. Existing PRs, device acceptance, provider access and explicit owner decisions remain separate gates.

Native Apple builds and physical device checks cannot run on this Linux host. No native/device verification is implied by a decision.

## Implementation evidence

[Draft PR #1130](https://github.com/crmitchelmore/justspeaktoit/pull/1130) implements #1104. Its published tree matches the locally reviewed tree; Apple CI and real provider/device acceptance are pending.

## Decisions

| Issue | Decision | Value |
|---|---|---|
| [#1104](https://github.com/crmitchelmore/justspeaktoit/issues/1104) — refactor(core): close the feature gaps between the mac-only live transcribers and the SpeakCore live clients | IMPLEMENT |  |
| [#1105](https://github.com/crmitchelmore/justspeaktoit/issues/1105) — refactor(mac): fold the AssemblyAI live controller onto SharedClientLiveController | IMPLEMENT | Worth doing as the template consolidation: one tested AssemblyAI transport reduces platform drift and duplicate audio lifecycle fixes. Reliability and preservation of first/final words take precedence over deleting lines. No visual change required. |
| [#1106](https://github.com/crmitchelmore/justspeaktoit/issues/1106) — refactor(mac): fold the Cartesia live controller onto SharedClientLiveController | IMPLEMENT | A bounded consolidation removes duplicated audio capture and transport maintenance while letting macOS receive shared Cartesia fixes already used by iOS. Worth doing only with startup, PCM framing and final-word retention parity; lower line count alone is insufficient. |
| [#1107](https://github.com/crmitchelmore/justspeaktoit/issues/1107) — refactor(mac): fold the Gladia live controller onto SharedClientLiveController | IMPLEMENT | A worthwhile incremental consolidation: one Gladia transport shared by macOS and iOS means reliability fixes land once. Proceed after prerequisite contracts are ready, preserving first audio, stop-time final words, utterance callbacks and confidence/segments. Deletion alone is not sufficient. |
| [#1108](https://github.com/crmitchelmore/justspeaktoit/issues/1108) — refactor(mac): fold the ElevenLabs live controller onto SharedClientLiveController | IMPLEMENT | Proceed after transport and options prerequisites. One correct realtime transport shared by macOS and iOS reduces protocol drift and duplicated audio handling. Value depends on preserving first words, stop-time final text and transcript metadata; file deletion alone is not an improvement. |
| [#1109](https://github.com/crmitchelmore/justspeaktoit/issues/1109) — refactor(mac): fold the Soniox live controller onto SharedClientLiveController | IMPLEMENT | Worth doing after shared finalisation and controller prerequisites: a single cross-platform Soniox transport reduces drift in first-word buffering, language hints and final-word delivery. This is bounded consolidation of an existing provider, consistent with fast reliable native dictation, rather than a new feature or visual redesign. |
| [#1110](https://github.com/crmitchelmore/justspeaktoit/issues/1110) — refactor(mac): fold the Modulate live controller onto SharedClientLiveController | NARROW | Proceed with a parity-gated single-provider consolidation. One maintained transport reduces divergent fixes across platforms, but retaining final words, per-utterance insertion, feature flags, timed segments and transparent cost is worth more than deleting duplicated code. |
| [#1111](https://github.com/crmitchelmore/justspeaktoit/issues/1111) — feat(core): one OpenAIRealtimeLiveClient in SpeakCore; macOS and iOS both consume it | NARROW | Proceed with a shared OpenAI transport and transcript/finalisation contract to prevent provider drift and lost dictation across platforms. Do not make deletion of every platform adapter or a line-count target a prerequisite; the existing owners contain capture, stop-generation, and recovery guarantees that must survive. Stage adapter migration after contract parity evidence. |
| [#1112](https://github.com/crmitchelmore/justspeaktoit/issues/1112) — refactor(mac): retire DeepgramLiveController; route deepgram/ through SharedClientLiveController | NARROW | Proceed conditionally as a behaviour-preserving fold after the shared template is ready. One audio and lifecycle implementation reduces the chance that first-word/final-word reliability fixes miss Deepgram, and adopting the existing bounded finalisation API can improve stop reliability. File-count reduction alone does not justify losing transcript metadata or cost transparency. |
| [#1113](https://github.com/crmitchelmore/justspeaktoit/issues/1113) — refactor: one provider routing source (delete the mac prefix table and the iOS backend switch) | NARROW | Proceed as staged consolidation. Shared ownership decisions and catalogue coverage prevent a user selecting a model that cannot transcribe on their platform. This directly supports reliable dictation and the repository rule that growing catalogues live in SpeakCore. Do not implement the proposed universal cloud route before prerequisite transports preserve current behaviour. |
| [#1114](https://github.com/crmitchelmore/justspeaktoit/issues/1114) — refactor: one OpenAI-compatible multipart batch client in SpeakCore; table-drive the thin mac wrappers | NARROW | Proceed with shared multipart transport and staged file lifecycle to reduce recording-sized memory duplication and keep upload correctness fixes consistent across platforms. Do not bundle deletion of six provider wrappers: code already delegates heavy work, and adapters retain meaningful provider capability and validation behaviour. The issue API incorrectly assumes all providers use bearer authentication. |
| [#1115](https://github.com/crmitchelmore/justspeaktoit/issues/1115) — refactor(ios): move AppSettings out of SettingsView.swift and replace raw defaults keys with a DefaultsKey enum | IMPLEMENT | A bounded mechanical separation makes reliability fixes to persisted transcription choices and settings safer to review. This supports reliable dictation and native settings without changing product behaviour; it also prepares the independently assessed B2/B3 work. |
| [#1116](https://github.com/crmitchelmore/justspeaktoit/issues/1116) — refactor(core): one settings schema and one provider API-key identifier catalogue shared by mac and iOS; delete the dead SettingsSync class | NARROW | Proceed with the proven credential/settings seam consolidation to prevent missing BYOK credentials and inconsistent preferences across devices. The broad issue assumes identical semantics and dead code that current sources do not support; avoid combining persistence migration, observable-state redesign and transfer expansion in one mechanical refactor. |
| [#1117](https://github.com/crmitchelmore/justspeaktoit/issues/1117) — iOS composition root and recording collaborator injection | NARROW | Proceed with completing the recording-service injection seam. Reliable tests for selected settings, delivery, recovery claims and foreground/background behaviour directly protect dictation and final transcript retention. Replacing all singletons and sweeping every view offers no demonstrated immediate user benefit and adds launch and observation risks. |

## #1104: refactor(core): close the feature gaps between the mac-only live transcribers and the SpeakCore live clients

Reviewer: `/root/issue_review_queue/review_1104`.

**Smallest worthwhile scope:** Add compatible AssemblyAI keyterms and Modulate option/factory plumbing; establish and correct ElevenLabs shared transport parity; add bounded Soniox finalisation/full-transcript contract. No controller or iOS call-site migration in this issue. Reuse AssemblyAIModels URL builder. Do not append an incompatible manual-commit message to the existing ElevenLabs protocol.


**Dependencies**

- Prerequisite for #1105 and later provider folds in #1103, specifically #1108 ElevenLabs and Soniox fold. No existing coverage resolves these concrete gaps. Keep each dependent migration gated on its own parity checks.

**Risks and limits**

- Issue underestimates ElevenLabs scope; shared-client corrections affect iOS even without iOS source edits. Never infer final-word safety from successfully sending finalize alone. No native build/device or paid provider validation performed. Beads CLI absent per brief; no tracker mutation.

## #1105: refactor(mac): fold the AssemblyAI live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1105`.

**Smallest worthwhile scope:** First make the SpeakCore AssemblyAI client preserve framing, pending-send ordering, awaitable complete transcript, finalisation budget/grace and utterance semantics through provider-neutral contracts/options. Then route only AssemblyAI to the shared controller and delete its dedicated controller/transcriber while retaining the batch provider. Preserve existing tests; avoid unrelated provider folds.

- Sources/SpeakApp/SwitchingLiveTranscriber.swift: ControllerSet still owns AssemblyAILiveController and routes AssemblyAI separately.
- Sources/SpeakApp/AssemblyAILiveController.swift start reads assemblyAIKeyterms; stop drains resampler and framed PCM, waits pending sends, sends ForceEndpoint only after Begin, waits model finalisation budget plus user grace, then terminates.
- Sources/SpeakApp/SharedClientLiveController.swift start passes keywords only for Meta/Google; stop awaits FinalizingStreamingTranscriptionClient but immediately discards ordinary clients; SharedClientAudioProcessor forwards arbitrary converted chunk sizes.
- Sources/SpeakCore/AssemblyAILiveClient.swift conforms only to StreamingTranscriptionClient; sendAudio forwards data unframed, stop sends Terminate, handleTurn emits cumulative display text with isFinal=false. Existing EU-first/pre-Begin fallback is already present.
- Sources/SpeakApp/AssemblyAILiveController.swift handleTurn forwards utterance boundaries before formatted final turns; generic shared controller only forwards boundaries on isFinal, so this behaviour needs an explicit shared contract.
- Tests/SpeakAppTests/AssemblyAITranscriptionProviderTests.swift contains catalogue/batch model tests, which must remain; SpeakCore AssemblyAIModelsTests covers URL/keyterms filtering and basic turn assembly, not complete shutdown parity.

**Dependencies**

- #1104 options prerequisite must include or precede AssemblyAI transport/finalisation parity, not just keyterms. Coordinate ownership explicitly.
- #1106–#1110 and #1112 should consume the proven template; no owner-gated CloudKit/runtime work involved.

**Verification**

- Keyterms, model/language, preroll, preferred input cleanup, error handling and final transcript remain equivalent.
- Deterministic tests cover minimum-frame padding, pending-send drain before ForceEndpoint/Terminate, delayed final turns, no-Begin/timeout, stop/restart stale callbacks and multi-turn replacement without duplicate text.
- Preserve utterance-boundary behaviour or document and justify an explicit product decision; do not silently drop it.
- Native macOS lint/build/tests and real AssemblyAI streaming recording must confirm partials plus immediate-stop final words before shipment. Report unavailable device/provider verification honestly; coding need not wait on Linux.

**Risks and limits**

- Switching routing before parity would drop final words and potentially send invalid sub-50ms PCM frames.
- Changing cumulative-versus-delta final semantics can duplicate text or trigger polishing for the full history.
- Provider-backed live verification requires authorised credentials; do not purchase credits.
- Beads CLI absent; this scratch review is evidence, not a replacement tracker.

## #1106: refactor(mac): fold the Cartesia live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1106`.

**Smallest worthwhile scope:** After prerequisite integration, preserve Cartesia PCM framing, send-drain, stop grace, transcript/interim and error behaviour through shared options/contracts; move cartesia/ routing; remove only the redundant controller/audio processor/Mac transport and its obsolete factory. Retain batch/key-validation provider behaviour, resolve API-version constant ownership, port uncovered transport tests.

- `Sources/SpeakApp/CartesiaLiveController.swift`: Dedicated stop drains converter tail, pads residual PCM to minimum frame size, awaits pending WebSocket sends, honours liveStopGracePeriod, and retains interim text and final segments.
- `Sources/SpeakCore/CartesiaLiveClient.swift`: Shared transport exists and surfaces server error events, but currently conforms only to StreamingTranscriptionClient; stop immediately cancels the socket. pendingSendGroup exists without exposed bounded drain in reviewed code. Startup pendingAudio uses a bounded suffix buffer; planner must compare first-word retention and framing.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared stop calls finishAndWait only for FinalizingStreamingTranscriptionClient, otherwise immediately stops; current result emits empty segments. Transcript accumulator preserves standalone segment finals.
- `Sources/SpeakApp/CartesiaTranscriptionProvider.swift`: Retained provider struct references CartesiaLiveTranscriber.apiVersion for key validation and exposes the factory; deletion must remove/repoint those references while keeping batch and credential validation.
- `Tests/SpeakAppTests/CartesiaTranscriptionProviderTests.swift`: Direct Mac transport tests require equivalent shared coverage, while provider registry/catalogue and key redaction checks remain relevant. No dedicated CartesiaLiveClientTests.swift existed at the probed path; broader shared test equivalence remains planner work.

**Dependencies**

- #1104 shared provider-agnostic options/framing/finalisation prerequisites
- #1105 first controller fold/template
- Part of #1103; no duplicate implementation established

**Verification**

- Document before/after behaviour matrix including transcript segments, first words, stop during startup, residual PCM, pending sends, grace and errors.
- Focused deterministic tests verify partial/final accumulation, repeats, trailing interim/final text, bounded shutdown, framing, stale callbacks and key-validation redaction; map every removed test to replacement or reason.
- Apple Swift macOS build/test and relevant shared/iOS CI gates pass; Linux static inspection is not native execution.
- Manual macOS Cartesia recording confirms immediate/partial text and retained final words; record evidence before issue closure.

**Risks and limits**

- Routing the current shared client without parity work can drop tail audio/final words.
- Shared result currently lacks dedicated transcript segment metadata; planner must trace consumers before allowing any loss.
- No microphone/provider/device verification performed.
- Beads CLI reported unavailable in supplied context; this JSON is interim review evidence only.

## #1107: refactor(mac): fold the Gladia live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1107`.

**Smallest worthwhile scope:** After #1104/#1105, supply Gladia-specific bounded finalisation and transport coverage in SpeakCore, use generic shared-controller contracts for settings and rich event/utterance metadata, then move the prefix and delete only dedicated live controller/transcriber/helper copies. Keep the batch provider and deliberate platform behaviours.

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: The gladia/ prefix still routes to controllers.gladia; migration is not already covered.
- `Sources/SpeakApp/GladiaLiveController.swift`: Dedicated stop drains converter and pending audio, awaits sends, applies liveStopGracePeriod, sends stop_recording, then waits within liveModelCapabilities.postStopFinalizeBudget. Final updates retain event.confidence and final segments; utterance callback receives only event.text.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared stop waits only for FinalizingStreamingTranscriptionClient; otherwise calls stop immediately. Shared callbacks currently send accumulated displayText as utterance boundary, confidence is nil, and result segments are empty. These are real parity gaps.
- `Sources/SpeakCore/GladiaLiveClient.swift`: Core client declares standaloneSegments but lacks FinalizingStreamingTranscriptionClient conformance; stop sends stop_recording then immediately cancels socket. Transcript callback exposes text/isFinal only, losing dedicated confidence metadata.
- `Tests/SpeakAppTests/GladiaTranscriptionProviderTests.swift`: Existing direct-transcriber wire/parse tests must move to the shared client, while provider/key/catalogue tests stay.

**Dependencies**

- #1104 shared options/contracts
- #1105 first fold/template
- #1103 consolidation epic

## #1108: refactor(mac): fold the ElevenLabs live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1108`.

**Smallest worthwhile scope:** 

- `Sources/SpeakApp/ElevenLabsLiveController.swift`: Dedicated path uses scribe_v2_realtime, protects callbacks with LiveTranscriptionRun.isCurrent, creates finalSegments and accumulates finals; stop drains converter, flushes pending PCM, awaits sends, applies liveStopGracePeriod, sends commit and waits up to 1.5 seconds for commit final.
- `Sources/SpeakApp/ElevenLabsLiveTranscriber.swift`: Uses /v1/speech-to-text/realtime and JSON input_audio_chunk with audio_base_64; commit is an empty input_audio_chunk carrying commit:true, and committed transcript events complete the waiter.
- `Sources/SpeakCore/ElevenLabsLiveClient.swift`: Current shared code uses /v1/speech-to-text/stream and binary audio, with comments saying it cannot flush buffered audio. Adding only a commit frame is not transport parity.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared stop accepts full-session finishAndWait text and returns segments: []; shared handleTranscript emits utterance boundaries on final events. Preserve dedicated segment metadata and intentionally verify the new boundary semantics.

**Dependencies**

- {"issue": 1104, "requirement": "Complete full ElevenLabs realtime protocol/framing and stop finalisation parity, including ordered pending sends and commit acknowledgement."}
- {"issue": 1105, "requirement": "Provider-agnostic options preserve stop grace and audio requirements."}
- {"issue": 1103, "requirement": "Parent consolidation epic; reuse first validated provider fold pattern without waiting unnecessarily for unrelated migrations."}

**Verification**

- Protocol fixture coverage must prove realtime URL/query, JSON audio and minimum chunk framing, buffered/pre-roll and trailing audio ordering, manual commit, delayed final, timeout and errors.
- Controller coverage must prove repeated identical finals survive, partials replace only the interim, finishAndWait full text does not duplicate, stale callbacks cannot cross recordings, and segment metadata/boundary ordering remain intentional.
- Map each removed mac test to shared replacement or a documented unaffected batch test; native macOS/iOS build and relevant XCTest are required.
- Manual ElevenLabs live recording on macOS must confirm streamed partials, first and last words, short recording stop and final delivery; record real result before claiming acceptance.

**Risks and limits**

- Do not move routing onto current shared endpoint: it is a materially different protocol.
- iOS consumes shared client and must be covered by protocol regression checks.
- Native/audio/provider results cannot be verified by Linux inspection.
- Beads CLI unavailable in supplied session context; this JSON is review evidence only.

## #1109: refactor(mac): fold the Soniox live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1109`.

**Smallest worthwhile scope:** ['After prerequisites, document the dedicated/shared behaviour delta and route soniox/ to sharedClient.', 'Remove dedicated controller, audio processor, ControllerSet wiring, mac-only SonioxLiveTranscriber and its finalisation delegate; keep batch provider struct.', 'Port unique language and preroll assertions to shared client/controller; preserve settings via provider-neutral options and current-run callback safety.']

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: soniox/ still selects controllers.soniox while seven other provider routes use sharedClient; migration is not already covered.
- `Sources/SpeakApp/SonioxLiveController.swift`: Dedicated path creates SonioxLiveTranscriber, installs its own audio tap, uses finalizationDelegate and guards callbacks with LiveTranscriptionRun.isCurrent; parity must preserve these lifecycle guarantees.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared path drains converter tail and awaits FinalizingStreamingTranscriptionClient.finishAndWait, replacing the aggregate final transcript; plain clients only receive stop before controller emits final output.
- `Sources/SpeakCore/SonioxLiveClient.swift`: Shared Soniox currently conforms only to StreamingTranscriptionClient. stop sends finalize and empty data, then closes after pending sends, not server completion. Routing it now risks trailing-word loss.

**Dependencies**

- {"issue": 1104, "requirement": "Blocking: implement and verify shared Soniox finalisation awaiting final server transcript, timeout/error/cancellation and new-session ownership."}
- {"issue": 1105, "requirement": "Blocking shared-controller/template behaviour and options, including liveStopGracePeriod parity; reuse the first fold pattern."}
- {"issue": 1103, "requirement": "Parent consolidation epic; retain incremental provider scope."}

**Verification**

- Require deterministic tests proving late final tokens survive stop and final delivery occurs once, with timeout/error and immediate next-recording cases.
- Preserve language-hint payload and startup preroll ordering/first-word coverage; map each deleted test to retained or replacement coverage.
- Apple Swift build/lint/tests and manual macOS Soniox recording with partial/final output remain required; Linux inspection is not microphone/provider validation.

**Risks and limits**

- A finalize frame being transmitted is insufficient: server completion must be awaited before shared stop publishes final output.
- Shared transport changes also affect iOS; preserve existing transport contract and verify shared tests.
- Do not silently drop liveStopGracePeriod, stale-session guards or batch functionality.

## #1110: refactor(mac): fold the Modulate live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1110`.

**Smallest worthwhile scope:** After prerequisites, introduce only missing provider-neutral hooks needed to preserve Modulate options, per-utterance boundary payload/timing and rich result metadata, then move modulate/ routing and remove proven redundant Mac streaming code. Keep batch provider and relevant tests. Do not drop features with a prose justification alone.

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: modulate/ still routes to controllers.modulate; dedicated ModulateLiveController is constructed and retained. This migration is not already covered.
- `Sources/SpeakCore/ModulateLiveClient.swift`: All four feature query parameters are hard-coded false. Each utterance emits cumulative text with isFinal=false; only done emits true. stop immediately cancels after sending end-of-stream, and class does not conform to FinalizingStreamingTranscriptionClient.
- `Sources/SpeakApp/ModulateLiveController.swift`: Dedicated controller emits an utterance boundary with each utterance.text, formats enabled metadata, preserves timed segments, provider duration, raw utterance capture and estimated cost; reads all four settings.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared factory call has no Modulate options yet. Boundary callback exists for isFinal=true only and uses cumulative displayText. stop produces empty segments and nil cost/rawPayload. It cannot preserve existing Modulate behaviour merely by routing this client.

**Dependencies**

- #1104 options/settings parity prerequisite, accepted but pending
- #1105 lifecycle/finalisation parity prerequisite, accepted but pending
- #1103 consolidation epic; preserve its incremental scope
- May follow first AssemblyAI fold for established routing/removal pattern, but that is not evidence of Modulate parity

**Verification**

- Prove four toggles reach URL configuration and preserve formatted transcript, timed segments and raw metadata in final results.
- Exercise two utterances and a repeated identical utterance: partial transcript remains cumulative, boundary arrives once per utterance with correct utterance text, done does not duplicate boundary or final delivery.
- Exercise stop before delayed final utterance/done, converter tail, late callbacks after restart, error and timeout recovery; preserve final words and release input resources.
- Preserve provider duration and estimated cost; compare final result against dedicated path fixtures.
- Inventory current ModulateIntegrationTests before deletion: existing suite contains settings, formatting, batch and registry tests that must remain; do not treat entire file as transport-only.
- Apple Swift/Xcode CI build, lint and meaningful tests; actual Mac live recording needed to verify first/final words, streaming cadence and completion. Linux review does not satisfy this device gate.

**Risks and limits**

- Issue understates current rich-result differences and per-utterance callback mismatch. isFinal callback presence alone does not establish equivalence.
- Shared client changes affect iOS, so preserve deliberate platform formatting and result behavior.
- No source edits or tests performed during read-only triage. Beads CLI absent per parent context; review JSON is analysis evidence only.

## #1111: feat(core): one OpenAIRealtimeLiveClient in SpeakCore; macOS and iOS both consume it

Reviewer: `/root/issue_review_queue/review_1111`.

**Smallest worthwhile scope:** ['Extract shared injectable WebSocket transport with existing GA payload/model-specific prompt and language rules.', 'Implement explicit item-aware accumulation, full-session finalisation and bounded readiness/send/commit waits, preserving accepted pre-ready prefix and one overflow owner.', 'Wire factory and adapt platforms incrementally, preserving capture/session ownership, stop-generation protection, resampler tail, safety history and Mac prompt/segments; retain thin wrappers where parity is not yet proven.', 'Remove obsolete implementations only after both platform paths pass the migrated lifecycle contracts; do not require removal of public iOS adapter symbols for cosmetic acceptance.']

- `Sources/SpeakCore/LiveTranscriptionClientFactory.swift`: OpenAI still returns nil alongside Apple; no shared factory implementation currently covers this issue.
- `Sources/SpeakiOS/Services/OpenAIRealtimeWebSocketClient.swift`: Pre-ready prefix retention, terminal overflow admission, serial audio submission and readiness flush handling exist. Pending-send wait uses DispatchGroup notification without its own timeout; blindly copying this is not bounded finalisation.
- `Sources/SpeakiOS/Services/OpenAIRealtimeLiveTranscriber.swift`: Resampler tail must be queued after captured PCM and before commit; readiness, audio sends, commit sends, new completion wait and close are distinct stop phases.
- `Sources/SpeakApp/OpenAIRealtimeLiveController.swift`: Item-ID deltas and finals replace by item, keep order, and reject pre-stop completion IDs for stop continuation. Mac also constructs segments and retains keyterm prompt behaviour.
- `Sources/SpeakCore/StreamingTranscriptionClient.swift`: finishAndWait must return whole-session text, with trailing final not also sent through callbacks. Raw delta/completed forwarding alone does not preserve the existing item identity contract.

**Dependencies**

- {"issue": 1103, "relationship": "Consolidation parent; incremental parity beats bulk deletion."}
- {"issue": 1104, "relationship": "Coordinate factory options/prompt plumbing; current factory has no LiveClientOptions. Avoid competing signature changes."}

**Verification**

- Fake-socket tests for item delta/final replacement, repeated identical utterances, stale completion after stop, completion racing commit and whole-session return/no duplicate trailing callback.
- Pre-ready overflow, flush ordering, stuck send/readiness deadlines, stop/restart generation isolation, startup cancellation, interrupted recording and prefix/tail retention tests.
- Factory prompt/model payload tests; Apple Swift native CI for both targets and required live API probe before shipping. Mac/iPhone actual dictation check must cover immediate speech and immediate stop.

**Risks and limits**

- Current adapters own platform-specific audio and result semantics; moving transport alone does not prove shared capture parity.
- Linux cannot establish microphone, Bluetooth, device lifecycle or actual API correctness; do useful code/unit contract work now and retain Apple/live validation gates.
- Beads CLI absent per parent context; this JSON is analysis evidence only.
- No repository changes or external posts performed.

## #1112: refactor(mac): retire DeepgramLiveController; route deepgram/ through SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1112`.

**Smallest worthwhile scope:** First ensure common controller preserves required final-result metadata, cost reporting, session lifecycle and boundary semantics. Add Deepgram-focused regression coverage for Nova and Flux transcript event sequences and finalisation, putting any provider protocol changes in SpeakCore.DeepgramLiveClient. Then route deepgram/ to the shared controller and remove the dedicated controller and its construction. Retain explicit device acceptance gates.

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: deepgram/ still selects the dedicated controller and ControllerSet still constructs it; the requested fold is not already covered.
- `Sources/SpeakApp/DeepgramLiveController.swift`: Dedicated stop drains converted audio, honours liveStopGracePeriod, stops the transport and returns final segments plus any remaining interim text. Results include timestamped segments and estimated cost.
- `Sources/SpeakApp/SharedClientLiveController.swift`: Shared stop uses finishAndWait and replaces the complete transcript, but returns segments: [] and cost: nil. Each final emits an utterance-boundary callback. A direct routing change therefore cannot be assumed behaviour-preserving.
- `Sources/SpeakCore/DeepgramLiveClient.swift`: Client already accumulates segment finals and returns a complete transcript through bounded shutdown. Shutdown resolves on the first final or metadata frame; current fullTranscript storage is final-only. Planner must verify outstanding interim and multiple trailing final behaviour for both Nova and Flux before adopting this path.

**Dependencies**

- #1105 shared-controller template fold and its lifecycle/metadata/boundary parity work
- #1103 consolidation epic
- Coordinate common result/cost handling with earlier accepted controller folds rather than introducing Deepgram-specific branches in the shared controller.

## #1113: refactor: one provider routing source (delete the mac prefix table and the iOS backend switch)

Reviewer: `/root/issue_review_queue/review_1113`.

**Smallest worthwhile scope:** ['Start with a SpeakCore batch routing contract that preserves existing local, direct-provider and OpenRouter distinctions, unknown-ID behaviour and API model names; platform adapters retain actual transport availability.', 'Introduce catalogue invariants using a documented explicit exception for OpenAI until its shared transport exists, and Apple/local handling as deliberate capability rules.', 'After prerequisite folds land, remove redundant cloud switches/controllers only for verified shared providers; preserve local branches and credential/configuration forwarding.', 'Describe one shared ownership policy accurately. Do not claim batch provider additions never require platform-specific registration until #1114 and actual transport parity justify it.']

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: macOS still routes AssemblyAI, Deepgram, Modulate, ElevenLabs, Soniox, Cartesia and Gladia to bespoke controllers, with a separate OpenAI realtime branch. Other clouds already use sharedClient. Local/SpeechAnalyzer/unsupported-local routing remains distinct.
- `Sources/SpeakCore/LiveTranscriptionClientFactory.swift`: Shared factory supplies most clouds but explicitly returns nil for .openai and .apple. Sending every non-Apple route here today breaks OpenAI.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: iOS currently preserves OpenAIRealtimeLiveTranscriber as an explicit backend and gates other shared providers on isSupportedOnIOS.
- `Sources/SpeakApp/TranscriptionProviderRegistry.swift`: macOS extracts provider prefix then verifies supported model IDs, except providers with an empty batch catalogue. This is ownership policy separate from the iOS policy.
- `Sources/SpeakiOS/Services/iOSBatchTranscriber.swift`: iOS has exact direct-provider matches, a local SpeechAnalyzer branch and an OpenRouter fallback; Google identifiers deliberately split direct requests from OpenRouter. A prefix-only common router would change transport and credential ownership.

**Verification**

- Tests for Google direct versus OpenRouter ownership, exact-model checks, whitespace, unknown IDs, Apple local and downloaded-local handling.
- Catalogue coverage tests must assert expected provider/API-model/transport decisions as well as non-nil results; merely routing unknown models to OpenRouter proves little.
- Apple Swift native macOS/iOS build and lifecycle regression tests after each fold; preserve start/stop, final transcript, API keys, endpoints, language, vocabulary and error recovery.

## #1114: refactor: one OpenAI-compatible multipart batch client in SpeakCore; table-drive the thin mac wrappers

Reviewer: `/root/issue_review_queue/review_1114`.

**Smallest worthwhile scope:** 

- `Sources/SpeakApp/OpenAITranscriptionProvider.swift`: Reads the entire audio file into Data and copies it into an in-memory multipart body; boundary, status checking and upload transport are reusable, while diarisation, language field choice and response decoding must remain provider-owned.
- `Sources/SpeakApp/ElevenLabsTranscriptionProvider.swift`: Duplicates in-memory multipart assembly but uses xi-api-key, model_id and language_code. A bearer-only OpenAI-compatible client as proposed would break ElevenLabs authentication.
- `Sources/SpeakApp/MultipartUploadStaging.swift`: Existing restrictive directory/file modes, in-flight claims and stale-file cleanup provide a useful shared privacy-sensitive lifecycle; it is not itself a multipart writer, so moving it alone does not provide bounded-memory assembly.
- `Sources/SpeakApp/XAITranscriptionProvider.swift`: Adapter rejects streaming models for file transcription, retains tailored validation diagnostics and exposes both live and batch model lists so registry credential routing stays correct. Wholesale table conversion has behavioural risk and little immediate user value.
- `Sources/SpeakiOS/Services/IOSBatchTranscriptionClient.swift`: Private multipart helpers remain duplicated; shared helper adoption is a bounded consistency improvement.

**Dependencies**

- Part of consolidation epic #1103 / A11; no dependency on live-client folds.
- Preserve existing #706 upload-staging safeguards and tests.
- Coordinate any provider/key-validation consolidation touching these same adapters; do not include unrelated wrapper deletion.

**Verification**

- Request-contract tests for OpenAI and ElevenLabs must assert exact endpoint, auth header, model/language/diarisation fields, MIME type and preserved response/error mapping.
- Transport tests should verify valid boundaries and bytes, non-HTTP/non-2xx behaviour, staged-file cleanup on success/failure/cancellation and preservation of active upload claims.
- Run existing staging/provider/iOS batch routing tests, make lint and native Apple Swift/Xcode builds in supported CI; Linux inspection does not prove compilation.
- One real macOS batch transcription with OpenAI or Groq is the practical smoke gate; do not claim device success from mocked requests.

**Risks and limits**

- Raw audio staging extends privacy-sensitive disk handling to more providers; preserve restrictive permissions and cleanup.
- URLProtocol tests that assume request.httpBody may need to inspect upload streams/files without weakening payload assertions.
- No immediate latency or memory benchmark was run; reduced in-memory copying follows from current implementation, but measure rather than promise a numeric gain.
- Beads CLI is absent per supplied context; this JSON is review evidence only, not a replacement tracker.

## #1115: refactor(ios): move AppSettings out of SettingsView.swift and replace raw defaults keys with a DefaultsKey enum

Reviewer: `/root/issue_review_queue/review_1115`.

**Smallest worthwhile scope:** Move AppSettings and split settings views by responsibility with minimum necessary visibility/import adjustments. Replace local persisted literals with exact existing raw-value enum cases; retain shared catalogue/default keys in their canonical owners. Preserve current view bodies, migrations, defaults and published side effects.


**Dependencies**

- Part of #1103 B1; sequence before #1116 and #1117 to avoid overlapping edits.
- No live comments override scope. No extracted Settings directory exists in inspected main.

**Verification**

- SettingsView under 800 lines and contains no AppSettings class; no raw forKey literals remain inside extracted class.
- Verify full legacy-key raw-value set is unchanged, including hasLaunchedBefore and rememberedRemoteTranscriptionMode. Prefer compatibility assertions over brittle count-only acceptance; current total is 17.
- Run existing iOS persistence and settings tests unchanged, lint with appropriate path baseline updates, Tuist generation and Apple Swift/Xcode iOS build/test gates.
- Inspect moved private helpers and platform guards to prevent cross-file access regressions.

**Risks and limits**

- No runtime performance improvement claimed; primary benefit is maintainability and review quality.
- File-scoped private visibility, platform imports (including Security use), and lint baseline locations need care during movement.
- Linux cannot validate Apple framework compilation or device behaviour.
- Beads CLI is absent per supplied context; this JSON is analysis evidence only, not substitute tracking.

## #1116: refactor(core): one settings schema and one provider API-key identifier catalogue shared by mac and iOS; delete the dead SettingsSync class

Reviewer: `/root/issue_review_queue/review_1116`.

**Smallest worthwhile scope:** 

- `Sources/SpeakSync/CloudKitKeySync.swift:544`: Twelve separately listed credential identifiers remain; centralising the existing policy removes drift without changing sync consent or coverage.
- `Sources/SpeakiOS/Views/SettingsView.swift:86-271`: Provider-specific published properties persist through persistSecret; Azure already uses AzureSpeechConfiguration.credentialIdentifier. Preserve actual identifiers and special credential configuration. Parent verified actual property count is 17, not issue text 16.
- `Sources/SpeakApp/AppSettings.swift:265-315`: Mac uses liveTranscriptionModel, silenceDetectionEnabled and silenceDuration. Similar user-facing settings must have their semantics and types checked before mapping to iOS keys.
- `Sources/SpeakCore/SettingsSync.swift:150-165,329-376`: Payload settings are [String:String]; gatherSettings explicitly maps model and keyword strings. A wider allowlist does not implement typed gathering/import for booleans or doubles.
- `Sources/SpeakCore/SettingsSync.swift:905,955`: Both call SettingsSync.shared; SyncStatus also reads lastSyncDate. The dead-class premise is false for current code and direct removal breaks these APIs.

**Dependencies**

- Depends on #1115 mechanical AppSettings/APIKeysView extraction; use new file paths once integrated.
- #1103 B2 consolidation epic; follow shared-catalogue requirement in AGENTS.md.
- Do not alter #1119 CloudKit container/provisioning decisions.

**Verification**

- Catalogue parity covers every current credential, exact identifier bytes, deduplication and existing syncable subset; retain platform capability filters.
- Migration tests: old only, new only, both present (new wins), and idempotent repeated launch.
- Credential update/remove/load/error paths preserve Keychain and UI state; native Apple Swift builds both platforms after B1.
- If transfer scope expands, test typed round trip, allowed value validation, cross-platform unsupported selections, old importer compatibility and encrypted payload size; whitelist expansion alone is not acceptance.
- If removing SettingsSync, repository-wide caller/build check including SyncAvailability.current and SyncStatus.current; no claim that static checks prove device sync.

**Risks and limits**

- Linux cannot verify Apple frameworks, Keychain or physical cross-device sync. Native CI and device checks remain.
- Do not impose grep-zero literals as a goal on fixtures or unrelated identifiers.
- Beads CLI absent per supplied context; review JSON is analysis evidence, not a replacement tracker.
- No repository mutations or external posts performed.

## #1117: iOS composition root and recording collaborator injection

Reviewer: `/root/issue_review_queue/review_1117`.

**Smallest worthwhile scope:** ['Inject the recording service dependencies actually read during start, stop, completion and recovery through explicit values or narrow closures; use the injected history manager consistently.', 'Keep production defaults in one safe construction path, retaining working singleton access for existing callers and background/intent entry points. Do not replace initialized static lets with bootstrapped implicitly unwrapped variables.', 'Use a lightweight recording dependency bundle only if needed for readable construction; do not require an app-wide IOSAppEnvironment, WatchCaptureReceiver module move, extension bootstrap, global current environment or view conversion in this increment.', 'Document broader environment/view migration as deferred follow-up requiring a concrete consumer or ownership problem, not zero .shared grep results.']

- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: The existing designated initializer supports isolated History, clipboard, polish, session and ownership tests, but settings, onboarding, keyboard availability, safety claims and activity updates still use global instances. Receipt construction even reads iOSHistoryManager.shared despite an injected historyManager.
- `SpeakiOSApp/SpeakiOSApp.swift`: Delegate launch resets recording state and activates Watch reception before foreground UI; background history pushes also use services. Moving initialization behind a SwiftUI-only bootstrap or mutable implicitly unwrapped globals could break these entry paths.
- `Sources/SpeakiOS/Views/ContentView.swift`: Foreground coordinator already shares injected state/history/ownership seams alongside a global activity manager. One process-wide recording ownership identity must survive any future composition work.
- `Tests/SpeakiOSTests/TranscriptionCompletionTests.swift`: Existing lifecycle tests already instantiate the designated service initializer; extend these seams instead of introducing a new broad architecture solely to achieve singleton-count targets.

**Dependencies**

- Part of #1103; coordinate recording factory seam with accepted #1115 and settings compatibility work #1116. These are integration dependencies, not reasons to require every proposed consolidation first.
- No issue comments contain newer owner decisions.

**Verification**

- Targeted XCTest coverage proves supplied settings and history are used rather than global state, fake delivery/safety collaborators receive completion outcomes, and application-state decisions can be exercised without mutating UIApplication.
- Preserve existing tests for stop-time transcript priority, delayed polish, interruption finalisation, foreground/headless exclusivity and completion receipts.
- Apple Swift/Xcode iOS build and SpeakiOSTests required before merge; run native launch, foreground recording, hardware/intent recording and delivery smoke when available.
- No latency improvement claimed without measurement; no device, Watch or microphone behaviour inferred from static checks.

**Risks and limits**

- Eager initialization can trigger key loading, ActivityKit or Watch work earlier than before.
- Duplicated ownership/service instances can permit competing recordings.
- An outer ObservableObject does not automatically forward nested objects changes; wholesale environment conversion can leave settings and history stale.
- Linux cannot validate Apple frameworks; native CI and device checks remain gates.
- Beads CLI is absent according to supplied session context; this JSON is review evidence only, not a substitute tracker.
