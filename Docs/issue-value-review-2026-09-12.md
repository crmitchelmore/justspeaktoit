# Issue value review — 12 September 2026

This is review evidence, not a replacement for the canonical issue tracker. The initial inventory contained 98 open issues and four open PRs. This checkpoint contains 31 completed independent issue reviews; the remaining issues are not yet assessed. Implementation and validation are separate from these recommendations.

## Method and product goals

Each issue receives its own value-review agent. Accepted scope goes to a different planning agent, then gpt-5.6-sol at medium reasoning for implementation. Reviews use source baseline `51286c58`, current issue bodies/comments, open PRs and recorded project decisions. During review, main advanced to `2ff982d` when Compare Models PR #1102 merged; relevant later plans account for those consumers.

Priorities: reliable and fast dictation; preserve first and final words; privacy and on-device options; transparent BYOK costs; native accessible controls; shared catalogues with deliberate platform differences. Refactor incrementally rather than rewrite. Existing PRs, device acceptance, provider access and explicit owner decisions remain separate gates.

Native Apple builds and physical device checks cannot run on this Linux host. No native/device verification is implied by a decision.

## Implementation evidence

[Draft PR #1130](https://github.com/crmitchelmore/justspeaktoit/pull/1130) implements #1104. Its published tree matches the locally reviewed tree. Initial Apple CI found two initializer compiler errors and 15 lint findings; corrections are published at `2bb644d` for CI. Provider/device acceptance remains pending.

[Draft PR #1131](https://github.com/crmitchelmore/justspeaktoit/pull/1131) implements #1115 settings extraction. The exact 17 persisted keys have a compatibility test, moved bodies were mechanically checked, and Apple CI plus simulator navigation remain pending. Published commit: `952756a`.

[Draft PR #1132](https://github.com/crmitchelmore/justspeaktoit/pull/1132) implements #1120 benchmark isolation. All eleven moved source/test files preserve their bytes, the checksum and legacy decoding remain, and an independent native benchmark CI gate is added. Published commit: `066a619`; Apple resolution/lockfile/build/test/checksum validation is pending.

Detailed accepted-scope plans are in `issue-plans-2026-09-12/`. [Runtime analytics qualification](issue-plans-2026-09-12/1121-evidence.md) found insufficient runtime-identifying production telemetry; unavailable usage is not zero usage.

## Decisions

| Issue | Decision | Value |
|---|---|---|
| [#1104](https://github.com/crmitchelmore/justspeaktoit/issues/1104) — refactor(core): close the feature gaps between the mac-only live transcribers and the SpeakCore live clients | IMPLEMENT | Necessary prerequisite for incremental shared-provider consolidation: retains user vocabulary and Modulate preferences while preventing lost final words. This is proven behavioural parity work, not a speculative architectural rewrite. |
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
| [#1118](https://github.com/crmitchelmore/justspeaktoit/issues/1118) — refactor: one HistoryRecord model and one store in SpeakCore for macOS and iOS; sync carries the full record | NARROW | Proceed with the local compatibility and responsiveness work. A shared record contract reduces divergent history behaviour and removing synchronous iOS disk work from the main actor supports reliable, responsive dictation. The proposed simultaneous model replacement, WAL migration and unrestricted full-record CloudKit payload is too broad: some fields are explicitly local-only and existing recovery protects transcripts against subtle partial-failure cases. |
| [#1119](https://github.com/crmitchelmore/justspeaktoit/issues/1119) — feat(sync): one CloudKit container for macOS and iOS so history and keys actually sync across devices | DEFER | High product value: the current platform-specific private databases prevent the intended Mac/iPhone history continuity and BYOK setup continuity. However the surviving container is an explicit owner decision, and #1118 is narrowed to local compatibility with full-record cloud schema/privacy work still deferred. There is no justified independent production code change to make before that decision: unifying configuration already selects the destination, and a migration or token-reset framework would prebuild an unapproved migration. The useful preparation now is the evidence and decision packet in this review. |
| [#1120](https://github.com/crmitchelmore/justspeaktoit/issues/1120) — chore: move the transcribe.cpp binary target and the local-transcription benchmark out of the root Package.swift | IMPLEMENT | Separating an experimental benchmark dependency from the shipping app graph reduces build dependency exposure and avoids unnecessary CTranscribe artifact resolution for app work. This supports faster, more reliable delivery of native dictation without changing user behaviour or retiring useful local-engine qualification tooling. |
| [#1121](https://github.com/crmitchelmore/justspeaktoit/issues/1121) — decision: replace the pip-installed Python sherpa-onnx subprocess with a linked runtime, or remove the path | NARROW | Proceed only with a bounded usage-evidence qualification. Removing Python bootstrap can improve reliable first-use dictation and native deployment, but removal can harm privacy-focused users. Neither replacement nor removal is authorised until usage evidence is presented and Chris chooses. Current code also disproves two broad assumptions in the proposed scope. |
| [#1122](https://github.com/crmitchelmore/justspeaktoit/issues/1122) — chore: strict concurrency on every target now; Swift 6 language mode module by module | NARROW | Proceed with warnings-only concurrency coverage and a measured baseline first. Compiler visibility into unsafe crossings supports reliable recording and transcript persistence. The issue bundles that useful safety measure with a large language migration, annotation churn, a semaphore-count target and a test-framework policy change whose user value is not yet established. |
| [#1123](https://github.com/crmitchelmore/justspeaktoit/issues/1123) — chore: give the watch targets a real SpeakWatchCore package target instead of 12 file-path inclusions | IMPLEMENT | A small explicit shared module reduces watch-only build failures when shared dictation protocol and lifecycle types change. This supports reliable native capture without new UI, runtime dependencies or speculative abstractions. Value is build reliability and maintainability, not a proven runtime speed gain. |
| [#1124](https://github.com/crmitchelmore/justspeaktoit/issues/1124) — test: one StubURLProtocol in a shared test-support target; delete the 31 per-file copies | NARROW | Proceed with shared support for ordinary request/response fixtures and scoped state isolation. Reliable provider regression tests support fast, dependable dictation and safer provider updates. The inspected protocols are not 31 equivalent copies: cancellation, partial responses and delayed completion exercise distinct reliability contracts. A forced one-class rewrite has poor value unless those contracts are preserved explicitly. |
| [#1125](https://github.com/crmitchelmore/justspeaktoit/issues/1125) — chore: delete dead scripts, retired workflow stubs and the unratified patterns YAML; fix the README pointer | IMPLEMENT | Small, worthwhile maintenance change that prevents contributors following a broken versioning path and removes obsolete publication entry points. It supports reliable releases with low implementation risk; no app UX redesign is needed. |
| [#1126](https://github.com/crmitchelmore/justspeaktoit/issues/1126) — ci: one composite action for the Xcode + Tuist + keychain setup block; one runner-selection scheme | NARROW | Proceed with a small behaviour-preserving toolchain extraction and removal of the obsolete PR-specific route. Shared setup reduces release drift and helps reliable delivery of native dictation fixes. The proposed union of every setup/signing step and one unconditional runner variable would erase intentional differences and exact-revision admission controls; that breadth has poor value. |
| [#1127](https://github.com/crmitchelmore/justspeaktoit/issues/1127) — chore(tooling): consolidate release tooling from six languages to shell plus JavaScript | NARROW | Proceed with complete, discoverable tooling test coverage and a clear configuration boundary. These reduce release regressions and help users receive reliable dictation fixes. Do not make zero Python/Ruby files a success criterion: wholesale language ports add signing, provisioning and release risk without an evidenced user benefit. The issue's four-reader premise is stale: current Swift/Python catalogue generation reads ReleaseTrains.json, not ReleasePipeline.json, and projection freshness already runs in CI. |
| [#1128](https://github.com/crmitchelmore/justspeaktoit/issues/1128) — test: drop swift-snapshot-testing (three PNGs) and fold the Tooling/ SwiftLint graph back into the root package | REJECT | The proposed deletion trades real UI regression protection and deliberate linter isolation for an unmeasured dependency reduction. The single assertSnapshot call is a shared helper used by three distinct rendering tests. Native visual quality, clear completion feedback, latency information and audio feedback are project goals; checking fixed output size or a few pixel colours would materially weaken that protection. A small test count is not evidence that a dependency is harmful. |
| [#1129](https://github.com/crmitchelmore/justspeaktoit/issues/1129) — docs: rewrite Docs/Architecture.md to cover every module, both platforms, the extensions and the release train | NARROW | Proceed with a concise current-state architecture reference. The existing macOS-only map omits real app surfaces and module boundaries, increasing the risk that contributors duplicate shared catalogues or break capture, privacy and release isolation. This is useful documentation work now, but it must not present conditional consolidation proposals as completed architecture. |
| [#934](https://github.com/crmitchelmore/justspeaktoit/issues/934) — iOS: the clipboard holds a placeholder after stop, and a late polish overwrites what the user copied since | NARROW | The raw-once contract directly protects instant usable dictation and prevents destruction of later user copies. Current main already implements the approved fix; repeating implementation adds no user value. Narrow the remaining issue to its explicit physical-iPhone delivery qualification gate. |
| [#935](https://github.com/crmitchelmore/justspeaktoit/issues/935) — iOS: a Bluetooth route or engine configuration change silently kills capture | NARROW | Reliable capture and preservation of the last words are core product requirements. The controlled-stop implementation already landed in main via #1032 and integration commit f8af0b1. Reimplementing it has no demonstrated value; the remaining valuable scope is physical-device qualification of the implemented behaviour, with fixes only for reproduced failures. |
| [#946](https://github.com/crmitchelmore/justspeaktoit/issues/946) — iOS: the Siri stop phrase arrives as an interruption, ignoring the destination and raising a stale error | DEFER | Reliable delivery and truthful Stop feedback matter to core hands-free dictation. Destination preservation and stale-alert suppression are now implemented under #936. The remaining Siri acknowledgement race warrants physical-device qualification before adding code; no observed ordering evidence or residual reproduction accompanies this issue. |
| [#947](https://github.com/crmitchelmore/justspeaktoit/issues/947) — iOS: verify suspected Modulate opening-audio loss before adding preroll | NARROW | Protecting opening words directly supports instant, reliable dictation, but current evidence does not prove startup loss. Proceed only with bounded synthetic transport qualification; keep all production buffering changes deferred until actual startup loss is reproduced. This avoids adding latency, memory and lifecycle complexity on the basis of a misleading no-start test. |
| [#954](https://github.com/crmitchelmore/justspeaktoit/issues/954) — iOS: explain native Control setup and add accurate Action Button hints | NARROW | Native trigger discovery directly reduces setup effort for fast dictation and matches native system controls. The requested implementation is now present on main; repeating it has no value. Retain only the explicit device and accessibility acceptance gate before declaring the issue complete. |

## #1104: refactor(core): close the feature gaps between the mac-only live transcribers and the SpeakCore live clients

Reviewer: `/root/issue_review_queue/review_1104`.

**Smallest worthwhile scope:** Add compatible AssemblyAI keyterms and Modulate option/factory plumbing; establish and correct ElevenLabs shared transport parity; add bounded Soniox finalisation/full-transcript contract. No controller or iOS call-site migration in this issue. Reuse AssemblyAIModels URL builder. Do not append an incompatible manual-commit message to the existing ElevenLabs protocol.

- Sources/SpeakCore/AssemblyAILiveClient.swift init/connect do not accept/pass keyterms, although Sources/SpeakCore/AssemblyAIModels.swift streamingURL already supports bounded keyterms_prompt and the mac AssemblyAILiveTranscriber uses it.
- Sources/SpeakCore/ModulateLiveClient.swift start hard-codes all four options false, including pii_phi_tagging (issue incorrectly implies the fourth query item is absent). Sources/SpeakApp/ModulateLiveController.swift passes all four appSettings preferences to its dedicated implementation.
- Sources/SpeakCore/LiveTranscriptionClientFactory.swift has two legacy keywords overloads and no options bundle; AssemblyAI/Modulate configuration is omitted.
- Sources/SpeakCore/ElevenLabsLiveClient.swift uses /v1/speech-to-text/stream, raw binary audio, transcript/speech_event_type parsing, and a bounded finishAndWait with finishFlushesBufferedAudio=false. Sources/SpeakApp/ElevenLabsLiveTranscriber.swift uses /realtime, JSON input_audio_chunk, session_started readiness, committed_transcript events and manual commit. The difference is a transport protocol, not just a missing final frame.
- Sources/SpeakCore/SonioxLiveClient.swift only conforms to StreamingTranscriptionClient. stop sends finalize and empty audio then closes after pending sends; it does not await the server final acknowledgement. SharedClientLiveController.stop immediately publishes latestTranscript for non-finalizing clients.

**Dependencies**

- Prerequisite for #1105 and later provider folds in #1103, specifically #1108 ElevenLabs and Soniox fold. No existing coverage resolves these concrete gaps. Keep each dependent migration gated on its own parity checks.

**Verification**

- Request fixtures must prove keyterms bounds/encoding, four option values/default preservation and legacy factory calls. Transport fixtures must exercise ElevenLabs handshake/audio/event schema and commit ordering, Soniox acknowledgement/timeout, full transcript return, late final delivery, no duplicate finals and stop/start races. Verify current provider documentation during planning; Apple Swift CI builds/tests plus eventual real provider stop-immediately-after-speech evidence are needed. Existing StreamingClientContractTests assert accumulation but do not establish transport parity.

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

**Verification**

- Explicit behaviour parity matrix names confidence and segment preservation, per-utterance callbacks, settings, preroll/framing, send ordering, final-word drain and stale-run isolation.
- Deterministic tests demonstrate two final utterances produce distinct boundaries with no repeated cumulative insertion; repeated identical utterances remain distinct and final full transcript is not duplicated.
- Tests exercise partial/final confidence metadata, segment output, late final after stop, timeout, pending audio/send drain, and settings propagation.
- Every deleted direct-transcriber test has a named shared-client replacement or an already-existing equivalent; retain unrelated provider tests.
- Native Apple Swift CI build/lint/test plus a separately recorded real-Mac Gladia recording check verifies partial streaming and final transcript; keep this device gate open until run.

**Risks and limits**

- Issue prose understates metadata use: dedicated controller DOES consume event.confidence.
- Routing before bounded finalisation and utterance semantics are fixed risks lost final words and duplicated insertion.
- Shared-client changes also affect iOS, and generic-controller changes affect other hosted providers; targeted existing-provider regression checks are necessary.
- Value triage only; no native build/device/provider calls performed. Beads CLI reported absent by parent context; review JSON is analysis evidence only.

## #1108: refactor(mac): fold the ElevenLabs live controller onto SharedClientLiveController

Reviewer: `/root/issue_review_queue/review_1108`.

**Smallest worthwhile scope:** After prerequisites pass, switch ElevenLabs prefix and controller ownership to shared path, remove dedicated controller/audio processor and mac-only live transport, retain batch provider/validation behaviour, and port only affected unique tests. Preserve segment results and session callback isolation through general shared contracts; avoid provider conditionals in the shared controller.

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

**Smallest worthwhile scope:** After prerequisites, document the dedicated/shared behaviour delta and route soniox/ to sharedClient.; Remove dedicated controller, audio processor, ControllerSet wiring, mac-only SonioxLiveTranscriber and its finalisation delegate; keep batch provider struct.; Port unique language and preroll assertions to shared client/controller; preserve settings via provider-neutral options and current-run callback safety.

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

**Additional limits**

- Five targeted code excerpts inspected; detailed planner should inspect full behaviour and existing tests.
- Beads CLI reported absent in supplied task context; no replacement tracker or external mutation created.

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

**Smallest worthwhile scope:** Extract shared injectable WebSocket transport with existing GA payload/model-specific prompt and language rules.; Implement explicit item-aware accumulation, full-session finalisation and bounded readiness/send/commit waits, preserving accepted pre-ready prefix and one overflow owner.; Wire factory and adapt platforms incrementally, preserving capture/session ownership, stop-generation protection, resampler tail, safety history and Mac prompt/segments; retain thin wrappers where parity is not yet proven.; Remove obsolete implementations only after both platform paths pass the migrated lifecycle contracts; do not require removal of public iOS adapter symbols for cosmetic acceptance.

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

**Verification**

- Nova and Flux multi-turn finals preserve earlier words, legitimate repeated text and final words without duplication.
- Exercise stop with interim-only tail, existing finals plus interim tail, delayed final, metadata-only completion, timeout, multiple trailing finals and rapid stop/restart; preserve recovered text on failure.
- Preserve cost visibility and required segment/duration output, or explicitly resolve equivalent downstream ownership before removal.
- Verify final events versus utterance-boundary callbacks and document the fate of liveStopGracePeriod using the bounded shutdown contract.
- Native macOS build/lint/tests pass and both Nova and Flux recordings are manually verified on macOS before closing the issue.
- No DeepgramLiveController or ControllerSet.deepgram references remain after integration.

**Risks and limits**

- Existing full-transcript accumulation is useful groundwork, not proof of Nova/Flux wire-protocol or final-tail parity.
- Shared finalisation can replace a visible interim tail with final-only accumulated text unless this is covered explicitly.
- Do not silently drop estimated costs or timestamped segments while consolidating.
- Linux/static inspection cannot establish microphone, transport timing or native UI behaviour; device evidence remains outstanding.
- Beads CLI is unavailable according to supplied session context; this JSON is review evidence, not a replacement tracker.

## #1113: refactor: one provider routing source (delete the mac prefix table and the iOS backend switch)

Reviewer: `/root/issue_review_queue/review_1113`.

**Smallest worthwhile scope:** Start with a SpeakCore batch routing contract that preserves existing local, direct-provider and OpenRouter distinctions, unknown-ID behaviour and API model names; platform adapters retain actual transport availability.; Introduce catalogue invariants using a documented explicit exception for OpenAI until its shared transport exists, and Apple/local handling as deliberate capability rules.; After prerequisite folds land, remove redundant cloud switches/controllers only for verified shared providers; preserve local branches and credential/configuration forwarding.; Describe one shared ownership policy accurately. Do not claim batch provider additions never require platform-specific registration until #1114 and actual transport parity justify it.

- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: macOS still routes AssemblyAI, Deepgram, Modulate, ElevenLabs, Soniox, Cartesia and Gladia to bespoke controllers, with a separate OpenAI realtime branch. Other clouds already use sharedClient. Local/SpeechAnalyzer/unsupported-local routing remains distinct.
- `Sources/SpeakCore/LiveTranscriptionClientFactory.swift`: Shared factory supplies most clouds but explicitly returns nil for .openai and .apple. Sending every non-Apple route here today breaks OpenAI.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: iOS currently preserves OpenAIRealtimeLiveTranscriber as an explicit backend and gates other shared providers on isSupportedOnIOS.
- `Sources/SpeakApp/TranscriptionProviderRegistry.swift`: macOS extracts provider prefix then verifies supported model IDs, except providers with an empty batch catalogue. This is ownership policy separate from the iOS policy.
- `Sources/SpeakiOS/Services/iOSBatchTranscriber.swift`: iOS has exact direct-provider matches, a local SpeechAnalyzer branch and an OpenRouter fallback; Google identifiers deliberately split direct requests from OpenRouter. A prefix-only common router would change transport and credential ownership.

**Dependencies**

- #1105–#1112 provider folds must land and demonstrate parity before corresponding native controllers are removed, especially shared OpenAI client #1111. Review approval is not evidence they landed.
- #1114 owns movement of batch implementations; keep #1113 limited to model ownership and route metadata.
- #1129 may own architecture documentation; coordinate the extension-point paragraph.

**Verification**

- Tests for Google direct versus OpenRouter ownership, exact-model checks, whitespace, unknown IDs, Apple local and downloaded-local handling.
- Catalogue coverage tests must assert expected provider/API-model/transport decisions as well as non-nil results; merely routing unknown models to OpenRouter proves little.
- Apple Swift native macOS/iOS build and lifecycle regression tests after each fold; preserve start/stop, final transcript, API keys, endpoints, language, vocabulary and error recovery.

**Risks and limits**

- Blanket isSupportedOnIOS=true is justified only after shared transport and required configuration are actually supported.
- Factory instantiation coverage cannot establish provider authentication, microphone, socket or final-transcript correctness.
- Linux inspection cannot validate Apple framework builds or physical device behaviour.
- Beads CLI absent per supplied session context; review JSON is interim evidence, not task tracking.

## #1114: refactor: one OpenAI-compatible multipart batch client in SpeakCore; table-drive the thin mac wrappers

Reviewer: `/root/issue_review_queue/review_1114`.

**Smallest worthwhile scope:** Introduce a SpeakCore multipart transport with caller-owned endpoint and authentication headers, plus ordered form fields and file-part parameters; keep provider decoding and capability routing in adapters.; Reuse the existing staging lifecycle and stream file bytes into the staged body in bounded chunks; ensure all success/error/cancellation paths remove staged audio.; Migrate OpenAI/Groq first and the directly verified ElevenLabs duplicate with its existing xi-api-key semantics; planner can include Mistral/RevAI only after checking endpoint, field, polling and error differences.; Remove the iOS private helper duplication through SpeakCore helpers or the verified transport.; Keep the six provider wrapper files and metadata unchanged; do not require every multipart provider to adopt the first patch.

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

- `Sources/SpeakiOS/Views/SettingsView.swift`: AppSettings remains embedded at lines 86–998. There are 16 literal defaults keys INCLUDING hasLaunchedBefore, plus rememberedRemoteTranscriptionMode: enum must contain 17 current keys, not the issue acceptance count of 16.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Adjacent grouping structs are UI catalogue helpers. Assign files by actual ownership; do not blindly move all helpers with AppSettings. Settings screens remain in the same large file.
- `Tests/SpeakiOSTests/TranscriptionSelectionPersistenceTests.swift`: Existing injected UserDefaults suites test persistence and selection restoration; retain these behavioural checks.

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

**Smallest worthwhile scope:** Introduce canonical credential identifiers/metadata in SpeakCore; preserve existing bytes, Azure exception, all current keys, and existing CloudKit syncable subset. Replace production duplication where consumers actually refer to these credentials.; Project platform-specific credential rows from catalogue with deliberate supported-provider filters; preserve UI metadata, special inputs, Keychain failures/deletion behaviour and observable updates. Dictionary-backed in-memory storage may proceed only with full consumer migration and equivalent behaviour.; Centralise only proven equivalent settings keys; migrate differing legacy keys only when destination is absent. Do not blindly unify platform defaults or silence/mode semantics.; Exclude unconditional transfer expansion and unconditional SettingsSync deletion. Planner may include either only after it explicitly handles typed version-compatible transfer or replaces SyncAvailability/SyncStatus dependencies with truthful availability/status semantics.

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

**Smallest worthwhile scope:** Inject the recording service dependencies actually read during start, stop, completion and recovery through explicit values or narrow closures; use the injected history manager consistently.; Keep production defaults in one safe construction path, retaining working singleton access for existing callers and background/intent entry points. Do not replace initialized static lets with bootstrapped implicitly unwrapped variables.; Use a lightweight recording dependency bundle only if needed for readable construction; do not require an app-wide IOSAppEnvironment, WatchCaptureReceiver module move, extension bootstrap, global current environment or view conversion in this increment.; Document broader environment/view migration as deferred follow-up requiring a concrete consumer or ownership problem, not zero .shared grep results.

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

## #1118: refactor: one HistoryRecord model and one store in SpeakCore for macOS and iOS; sync carries the full record

Reviewer: `/root/issue_review_queue/review_1118`.

**Smallest worthwhile scope:** Stage one: introduce the shared, versioned local HistoryRecord and supporting portable types in SpeakCore with legacy macOS/iOS decoding fixtures and explicit platform adapters. Preserve existing on-disk representations through adapters until conversion is proven; do not force wholesale view renames or delete aliases for cosmetic reasons.; Stage two, separately reviewable: isolate the existing iOS persistence operations behind an actor while preserving snapshot/recovery format, protected-file writes and the current recovery decisions. Keep observable UI state on MainActor and serialize load/mutation/save to avoid async ordering regressions.; Defer the common WAL replacement and legacy-file rename to a later evidence-backed migration. Keep the current CloudKit projection in this phase. A future sync extension must distinguish portable user history/cost data from local file references, local-only errors and diagnostic/network payloads rather than blindly upload every field.

- `Sources/SpeakApp/HistoryItem.swift`: The macOS record already uses createdAt and updatedAt, but owns richer costs, modelUsages, networkExchanges, events, diagnostics, audioFileURL and latency; this confirms duplication while showing that some proposed renaming is stale.
- `Sources/SpeakiOS/Views/iOSHistoryModels.swift`: The iOS record has transcription/model/duration names and originPlatform; errorMessage is explicitly documented as local-only, not synced. A superset model must preserve those deliberate semantics.
- `Sources/SpeakSync/SyncModels.swift`: The current nine-field projection excludes diagnostics and costs. A shared local model does not require replacing this wire API.
- `Sources/SpeakSync/SyncRecord.swift`: Both CKRecord directions use legacy scalar fields and permissive defaults. Replacing them outright with recordJSON would risk older-client interoperability and introduces a schema rollout distinct from local consolidation.
- `Sources/SpeakiOS/Views/IOSHistoryPersistence.swift`: The @MainActor class performs synchronous read, encoding, hashing and writes. Its recovery logic preserves unreadable files, pending deletes, same-second updates, per-item digest bases, protected writes and failed-cleanup retry; a bare WAL swap is not demonstrated equivalent.

**Dependencies**

- #1103 consolidation umbrella; no dependency on provider/recording rewrites.
- #1117 is narrowed recording dependency injection; do not introduce an app-wide dependency container.
- #1119 owner must choose the surviving CloudKit container and complete provisioning/device gates. This local scope must neither choose nor migrate containers.
- Separate CloudKit schema/payload expansion from this implementable local phase; coordinate future rollout with #1119 without treating local work as blocked.

**Verification**

- Fixtures derived from each actual legacy schema, with synthetic/scrubbed content, preserve identifiers, timestamps, raw/polished text, model selection, duration, costs and optional diagnostics after decode and platform round trip.
- Fault-injection tests preserve primary and sidecar on read/decode failure, pending deletes, same-second edits, stale-sidecar cleanup failure, and retries without resurrecting or losing transcripts.
- Concurrency tests exercise mutation arriving during initial load and overlapping save/delete requests; final persisted state must match the latest accepted operations.
- Apple Swift CI builds both app targets and runs relevant history tests; inspect iOS isolation to ensure disk and hashing operations occur off MainActor.
- Real upgrade checks on macOS/iOS confirm old history remains visible, new transcripts survive restart and existing sync banner behaviour is unchanged. This is a remaining device gate, not claimed evidence.

**Risks and limits**

- This read-only review inspected five targeted code excerpts; the planner must map supporting-type dependencies and actor call ordering before implementation.
- The full original acceptance criteria are intentionally not satisfied by this narrow phase: common WAL storage and full-record sync remain separate follow-up decisions.
- Do not invent real user records for fixtures or move personal diagnostic data into remote sync by default. Generate representative scrubbed fixtures from actual encoder shapes.
- Linux cannot validate Apple frameworks or device upgrades; do not claim static review or portable tests establish device behaviour.
- Beads CLI is absent per supplied session context; no tracker operations or repository changes were performed.

## #1119: feat(sync): one CloudKit container for macOS and iOS so history and keys actually sync across devices

Reviewer: `/root/issue_review_queue/review_1119`.

**Smallest worthwhile scope:** Keep #1119 open as an owner-gated migration. Present the current four-container inventory and the issue recommendation (retain the existing Mac containers for each train) as a recommendation only. After Chris chooses, use a separate planning agent to resolve actual manifest source, supported history schema, key migration semantics, conflict/retry policy, and signing gates. Do not add a cloudContainer alias, change entitlements, reset live state, or build/activate migration in this pass.

- `Sources/SpeakSync/SyncConfiguration.swift`: iOS and macOS choose separate ReleaseTrain container properties. History checkpoint keys are not container-scoped. macOS checks the chosen identifier against entitlements; iOS assumes managed provisioning.
- `Sources/SpeakCore/ReleaseTrainCatalogue.swift`: Stable resolves to iCloud.com.justspeaktoit.ios versus iCloud.com.justspeaktoit; Alpha uses the analogous separate .alpha pair. Generated-file header names ReleaseTrains.json as source, so the issue reference to Config/ReleasePipeline.json must not be followed without checking the actual generator.
- `Sources/SpeakSync/HistorySyncEngine.swift`: Engine injects UserDefaults and CloudKit transport; targeted initialisation excerpt has no container identity transition handling. Its zone/subscription state references shared SyncConfiguration keys.
- `Sources/SpeakSync/CloudKitKeySync.swift`: Distinct EncryptedSecret and EncryptedSecretMetadata records plus derived-key verification/encryption paths mean a safe migration needs explicit key/passphrase and metadata semantics; opaque ciphertext copying is insufficient.
- `/workspace/scratch/a8be40db3c71/comments/1119.json`: Cached live issue comments are empty; no owner destination decision is recorded there.

**Dependencies**

- #1103 consolidation epic C2
- #1118 local compatibility only; full-record sync remains gated on privacy/schema
- #1116 shared settings identifiers if future migration markers are added
- Chris must select the surviving Stable and Alpha containers
- Apple entitlement/provisioning configuration and physical Mac+iPhone verification

**Verification**

- Owner destination decision recorded before destination-dependent implementation.
- Preserve Alpha/Stable separation and old-container data; migration resumes after interruption and marks success only after all required uploads succeed.
- Future tests cover changed/unchanged container checkpoint behaviour, duplicate/conflicting records, unavailable cloud, interrupted migration and secret key/metadata failures.
- Apple Swift CI must pass SpeakSync guards and key-sync tests plus both platform configuration checks.
- Provisioned fresh and upgrading iPhone plus Mac on one iCloud account must demonstrate history/key behaviour, including existing old-container data; static Linux review cannot prove this.

**Risks and limits**

- Premature container changes can hide existing history or strand secrets; incorrect checkpoint reset or completion markers can lose migration progress.
- The issue preparation section conflicts with its explicit owner-before-code gate; honour the gate.
- Same-container history visibility also depends on deferred compatible schema/privacy decisions, not just matching strings.
- No repository edits, native tests, portal operations or device tests performed. Beads CLI is unavailable per supplied session context; this JSON is review evidence only.

## #1120: chore: move the transcribe.cpp binary target and the local-transcription benchmark out of the root Package.swift

Reviewer: `/root/issue_review_queue/review_1120`.

**Smallest worthwhile scope:** Move benchmark sources/tests and its unchanged binary URL/checksum into Benchmarks/LocalTranscription with a root SpeakCore path dependency. Remove root benchmark/binary targets, update checksum discovery, explicit make bench invocation and existing command/path references. Preserve transcribeCpp API. Repair or relocate the existing benchmark pin invariant so it checks the graph actually used by the benchmark. Preserve benchmark data and qualification gates.

- `Package.swift`: Binary target and benchmark product/test targets remain in the root manifest; SpeakApp links WhisperKit and FluidAudio, not CTranscribe.
- `scripts/verify-checksums.sh`: Checksum extraction is hard-coded to root Package.swift and must follow the moved manifest.
- `Tests/SpeakCoreTests/ManifestParityTests.swift`: Root test reads the current benchmark runner path and root Package.resolved; relocation must preserve a meaningful runtime-version check against the benchmark's resolved dependency.
- `Tests/SpeakCoreTests/ModelCatalogTests.swift`: Non-benchmark tests explicitly use transcribeCpp and legacy transcribe-cpp decoding. Keep the shared engine case/string mappings; deletion is unnecessary and breaks existing compatibility tests.
- `Sources/LocalTranscriptionBenchmark/EngineRunners.swift`: Targeted reference search finds the CTranscribe importer only in benchmark code and no workflow benchmark-name references.

**Dependencies**

- Consolidation epic #1103 D1; independent of #1121 runtime removal/native-linking choice.
- Coordinate any concurrent Package.swift, benchmark, checksum, or manifest-parity edits.

**Verification**

- Static manifest/reference audit: root has no benchmark/binary targets and shipping products retain required dependencies; relocated benchmark owns all former sources/tests.
- Use Apple Swift/Xcode CI for clean root resolution/build and prove no CTranscribe root artifacts, then independently resolve/build/test the benchmark package.
- Run make verify-checksums with the unchanged artifact URL/checksum and verify make bench invocation/help.
- Validate the existing runtime-version pin invariant against the benchmark's own resolved graph; preserve transcribe-cpp decoding tests.

**Risks and limits**

- Read-only source inspection supports structural isolation, not quantified CI-time savings or a claim that every existing CI job downloads the artifact.
- Moving tests out of default root test discovery needs an explicit benchmark validation path; do not silently lose assessment-gate coverage.
- No Apple-native build or device results obtained on this Linux reviewer.
- Beads CLI is absent per supplied context; this JSON is interim review evidence, not a task tracker.

## #1121: decision: replace the pip-installed Python sherpa-onnx subprocess with a linked runtime, or remove the path

Reviewer: `/root/issue_review_queue/review_1121`.

**Smallest worthwhile scope:** A separate planning agent may qualify existing analytics schema and data coverage, retrieve 90-day observed usage grouped by verified sherpa-capable dimensions, separate ambiguous Parakeet counts, and return an evidence brief for Chris. Do not modify runtime, remove models, add telemetry, or select a branch during this scope.

- `Sources/SpeakApp/SherpaOnnxRuntimeManager.swift`: Still creates a Python venv and installs sherpa-onnx==1.13.2 with pip; the runtime issue is real.
- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: FluidAudioParakeetModel and WhisperKitStreamingModel route before the broad local/streaming prefix. Prefix-wide removal or usage counting would conflate separate native runtimes with sherpa.
- `Sources/SpeakCore/ProductAnalyticsDimensions.swift`: Current typed events emit model_family, engine_type and provider_type rather than an arbitrary selected-model identifier. parakeet explicitly combines sherpa-onnx and FluidAudio builds; nemotron and zipformer are annotated as sherpa-backed.
- `Sources/SpeakCore/ProductAnalytics.swift`: Collection is consent-gated, so absent observed events cannot establish absence of offline usage.
- `Sources/SpeakApp/LocalPostProcessingModelManager.swift`: Another runtime independently invokes Python, installs llama-cpp-python and uses LocalProcessRunner. The issue-wide no Python under SpeakApp acceptance criterion cannot be met by sherpa-only work, and shared process helpers cannot simply be deleted.

**Dependencies**

- #1103 consolidation epic D2
- Requires authenticated read-only PostHog evidence and explicit Chris branch choice
- Related local post-processing runtime work must remain separately scoped; no linked-runtime or App Store guard decision inferred
- Cached issue comments are empty

**Verification**

- Record exact observation window, query, event types, distinct observed users/installations, and telemetry coverage limitations. No usage query was run by this reviewer.
- Establish which current or historical fields can distinguish sherpa from FluidAudio/WhisperKit. Report ambiguous or unavailable data explicitly instead of treating it as zero.
- Present both retain/native-link and remove alternatives with observed impact; wait for Chris to choose before implementation.
- Correct later acceptance scope to no Python in the sherpa path, unless separately approved work also replaces local post-processing. Any runtime branch needs native build and actual fixture/device validation.

**Risks and limits**

- No native runtime or physical-device results were obtained. Linux is not the decision blocker; absent usage evidence and owner choice are.
- Opt-in analytics undercounts privacy/offline users and 90-day schema availability may be incomplete.
- Broad local/streaming deletion would risk removing native FluidAudio/WhisperKit options.
- Beads CLI is absent; this JSON is review evidence only, not a replacement tracker.

## #1122: chore: strict concurrency on every target now; Swift 6 language mode module by module

Reviewer: `/root/issue_review_queue/review_1122`.

**Smallest worthwhile scope:** One PR enables complete concurrency checking in explicit Swift 5 language mode for owned Swift source/test targets and mirrors it across relevant Tuist targets, recording reproducible diagnostics per module. Preserve runtime code and existing XCTest policy. After measured diagnostics, choose individual small modules for separate Swift 6 migration PRs; do not pre-authorise a whole-app migration, blanket semaphore removal or default-main-actor annotation cleanup.

- `Package.swift`: Tools version remains 5.9; only SpeakCore declares StrictConcurrency. App, iOS, sync, automation, hotkey, CLI, benchmark and test source targets lack the corresponding explicit setting. The binary CTranscribe target must not be treated as a Swift source target.
- `Project.swift`: Separate settings dictionaries feed app, watch, keyboard, share, widget and test targets; the searched SWIFT_ settings do not show strict concurrency or a language-mode override.
- `Sources/SpeakApp/HistoryManager.swift`: The previous main-actor/semaphore deadlock has already been removed. Termination deliberately writes synchronously, retains the WAL and guards startup load state; an automatic async rewrite could lose final transcript persistence.
- `AGENTS.md`: Current conventions specify XCTest and prohibit the main-actor semaphore deadlock pattern. A compulsory new-test framework change would conflict with current guidance and is independent of concurrency coverage.

**Dependencies**

- Parent epic #1103; coordinate with other consolidation work touching Package.swift or Project.swift.
- Apple Swift/Xcode CI is required to obtain real per-module diagnostics; Linux can support configuration inspection but cannot provide that baseline.
- No live issue comments change the scope.

**Verification**

- Verify supported Apple Swift toolchain accepts the exact chosen StrictConcurrency setting and Swift 5 language-mode configuration; do not assume the proposed manifest syntax is correct.
- Build macOS and actual iOS/watch/extension target configurations on Apple CI and publish warning totals per module with command/toolchain details; do not count a macOS build of iOS-guarded code as iOS coverage.
- Existing native build/test gates pass with no mode-induced errors; report and stop expansion if diagnostics exceed the issue threshold of about 150.
- Keep subsequent language-mode changes gated by measured diagnostic scope and relevant behavioural tests, especially recording shutdown and history persistence.

**Risks and limits**

- Warnings-only checking provides visibility rather than proof of race-free runtime behaviour.
- Changing tools version can alter default language mode unless explicitly pinned; apply changes only to owned Swift targets.
- A zero DispatchSemaphore count is not a sufficient correctness criterion; synchronous termination and callback contracts require individual analysis.
- Physical microphone, Watch and shutdown behaviour remain native verification gates. No builds or device checks were performed for this value review.
- Beads CLI is absent per parent context; this scratch JSON is review evidence, not a replacement tracker.

## #1123: chore: give the watch targets a real SpeakWatchCore package target instead of 12 file-path inclusions

Reviewer: `/root/issue_review_queue/review_1123`.

**Smallest worthwhile scope:** Introduce dependency-free SpeakWatchCore target AND library product; move the seven existing sources and focused tests, preserve SpeakCore import compatibility, replace watch source inclusions with product imports, and update the release catalogue generator/path assertions. Keep internal implementation details internal. No change to capture behaviour, identity values or provisioning.

- `Project.swift`: Both watch targets still compile individual SpeakCore source paths; the app has seven inclusions and the widget five. The adjacent comment documents a watchOS package compatibility workaround.
- `Package.swift`: Package declares macOS/iOS only and has no SpeakWatchCore target/product. SpeakCore itself currently declares no dependencies, so planners must verify the claimed product-level escape from package graph compatibility rather than assume it.
- `Sources/SpeakCore/ReleaseTrain.swift`: Release identity uses ALPHA compile state and Bundle.main metadata, with a generated internal catalogue. Moving this code requires preserving train identity and storage selection.
- `Sources/SpeakCore/ReleaseTrainCatalogue.swift`: Generated implementation detail is internal; it need not become public when moved alongside ReleaseTrain.
- `scripts/generate-release-train-config.py`: Generator still writes Sources/SpeakCore/ReleaseTrainCatalogue.swift; extraction must update this path and its validation references.

**Dependencies**

- Part of #1103 D4; independent from CloudKit-container migration and local-runtime decisions.
- Preserve existing TUIST_WATCH_APP/provisioning gate; do not enable distribution or publish releases.
- Coordinate generated release configuration path with concurrent release-train work.

**Verification**

- On Apple Swift/Xcode, generate Tuist with watch target enabled and build watch app plus complication for watchOS Simulator. Confirm package graph resolves for this product; if not, use an isolated dependency-free local package rather than restore path inclusions.
- Run focused watch core tests and existing SpeakCore consumers/tests to check unchanged imports and lifecycle/protocol behaviour.
- Check release catalogue generation is reproducible and no stale moved-source path references remain; retain one canonical JSON catalogue.
- Verify Stable/Alpha identity and app-group outputs remain equal before/after extraction, including Bundle.main fallback semantics in package builds.
- Treat issue grep-count assertion as a structural smoke check, not sufficient acceptance.

**Risks and limits**

- Native framework/package compatibility cannot be proven on this Linux host; watch simulator builds remain an integration gate.
- A same-manifest dependency-free target may still encounter dependency resolution constraints: existing SpeakCore is already dependency-free. Planner must investigate this before committing to the exact issue recipe.
- Moving code changes module visibility and compile conditions; avoid exposing generated catalogue internals or weakening Alpha/Stable isolation.
- No physical watch recording/runtime correctness claim follows from this extraction.
- Beads CLI is absent per supplied context; scratch decision is review evidence only.

## #1124: test: one StubURLProtocol in a shared test-support target; delete the 31 per-file copies

Reviewer: `/root/issue_review_queue/review_1124`.

**Smallest worthwhile scope:** Add XCTest-free shared support for ordinary complete responses, thrown failures, request/body capture and genuinely isolated per-session fixtures; migrate a bounded representative batch across test targets. Keep cancellation/partial/deferred protocols until an explicit compatible API is justified. Do not require exactly one URLProtocol subclass. Preserve assertion meaning and existing test identities.

- `Tests/SpeakAppTests/OpenAITranscriptionProviderTests.swift`: Uses an async throwing handler in a Task; the proposed synchronous tuple handler does not directly preserve its contract.
- `Tests/SpeakCoreTests/OpenRouterAudioCatalogNetworkTests.swift`: Sends response headers and incomplete JSON before hanging, and reports didStart/didStop. Returning nil without responding is not equivalent.
- `Tests/SpeakCoreTests/TTSProviderTransportDoubles.swift`: Ordinary response/recording seam is suitable for consolidation; normalises body streams once and locks state. File also contains call counter, async assertion and response helpers that must remain.
- `Tests/SpeakiOSTests/BatchProviderRoutingTests.swift`: Records request then fails with userAuthenticationRequired, which can use a throwing shared handler without provider-specific shared code.
- `Tests/SpeakAppTests/PostHogAnalyticsTestSupport.swift`: Recorder controls deferred responses and whether they finish; lock plus stopped flag suppresses callbacks after cancellation. These are substantive transport timing semantics, not simple canned responses.

**Dependencies**

- Child of consolidation epic #1103; no production feature dependency.
- Planner must inspect Package.swift/Project.swift target linkage and ensure support remains test-only.
- No live issue comments add constraints.

**Verification**

- Demonstrate simultaneous sessions cannot observe or reset each other's handlers/recordings, including identical request URLs.
- Verify body stream capture remains available to both handler and assertions without a second drain.
- Run existing migrated provider and routing tests, compare discovered existing tests before/after, and separately count any new support-contract tests.
- Apple Swift macOS tests plus Xcode iOS tests are required before integration; Linux static checks cannot establish native URLProtocol behaviour.
- For any specialised fixture later migrated, preserve partial-body delivery, deferred completion, cancellation hooks and absence of callbacks after stop.
- Correct issue API inconsistency: its declared non-optional response tuple cannot return nil; choose explicit semantics in the plan.

**Risks and limits**

- Scope identity must reach requests constructed inside provider code without altering asserted headers/URLs or relying on a process-global fallback; request-property propagation needs native verification.
- Replacing many independent static handlers with one global handler would increase cross-test contamination.
- No product UI or latency change is claimed. Five targeted protocol excerpts reviewed; full migration inventory belongs to planning.
- Beads CLI is absent per parent context; this scratch JSON is analysis evidence only.

## #1125: chore: delete dead scripts, retired workflow stubs and the unratified patterns YAML; fix the README pointer

Reviewer: `/root/issue_review_queue/review_1125`.

**Smallest worthwhile scope:** Delete three obsolete scripts, three candidate patterns YAML files and three obsolete/advisory workflow files.; Correct README version/build guidance with current Alpha/Stable runbook and active mechanism; avoid suggesting manual commands bypassing approval.; Update existing identity assertions to require absence of retired workflows and preserve all active release protection.; Ignore untracked SpeakiOS.xcodeproj unless it is present and proven empty/generated; local deletion is not a PR deliverable.

- `README.md:115–122; scripts/version.sh:6`: README recommends obsolete version.sh commands and BUILD, while script points at BUILD rather than the current build mechanism.
- `.github/workflows/prepare-stable.yml:40; .github/workflows/publish-stable.yml:34; Docs/alpha-stable-release-trains.md`: Active Stable flow uses release-train.mjs prepare/publish and explicit approved manifest hash. Preserve all these gates.
- `Tests/SpeakAppTests/DistributionBuildIdentityTests.swift:416–450,626–633`: Tests actually read both retired workflow files; replace these reads/assertions with file absence checks or deletion would fail tests. Preserve active keyboard-signing and frozen-candidate assertions.
- `.github/workflows/auto-release.yml; .github/workflows/publish-speak-cli.yml`: Manual retired stubs do no publishing; CLI stub exits 1.
- `.github/workflows/conformance-pr-review.yml; patterns.config.yaml`: Conformance workflow is an active PR-triggered external advisory action, not literally dead; its job is continue-on-error and profile explicitly candidate/unratified. Removing the workflow plus unused profiles is reasonable within the issue’s explicit default-delete scope.
- `Repository-wide hidden-file rg search excluding .git`: No callers of bump-version.sh or verify-binary.sh outside their own content; version.sh only in README. Retired workflow paths only occur in identity tests; no tracked SpeakiOS.xcodeproj files found.

**Dependencies**

- Part of #1103 E2; independent of the other consolidation issues.
- Review comments cache is empty; no later owner decision contradicts requested cleanup.
- Planner should confirm branch protection does not require the advisory conformance job before removing it.

**Verification**

- Repeat tracked and hidden-file reference search; only deliberate negative test assertions may retain deleted names.
- Run release-train Node tests and targeted identity test on Apple Swift CI; make lint where supported.
- Verify active prepare/publish workflows and explicit manifest-hash approval remain unchanged.
- Confirm README describes actual mechanism and no longer advertises BUILD/version.sh.

**Risks and limits**

- The external advisory action may implicitly consume patterns files; remove it together with those files, not independently. Live branch protection was not inspected by this bounded read-only reviewer.
- Linux cannot validate Apple frameworks; native CI verification is still required, but does not block implementing this cleanup.
- Beads CLI is absent per supplied session context. No repository changes, external comments or release actions performed.

## #1126: ci: one composite action for the Xcode + Tuist + keychain setup block; one runner-selection scheme

Reviewer: `/root/issue_review_queue/review_1126`.

**Smallest worthwhile scope:** Extract repeated Xcode selection/Tuist installation with explicit inputs and preserve existing versions. Keep platform-specific generation, metadata, signing, preflight and final cleanup in their current positions unless a proven equivalent small helper fits.; Remove obsolete PR 1038 routing while preserving current hosted defaults and exact-SHA native-pool eligibility. Centralise only if every event/fork/fallback path retains equivalent behaviour.; Do not add Apple setup to Ubuntu orchestration or collapse the hardware-specific device runner. Avoid arbitrary environment-map APIs or unsupported action lifecycle assumptions.

- `.github/workflows/ci.yml`: Exact reviewed SHA plus source-repository/event checks select the native pool for two jobs. Six other visible routing expressions retain the special PR 1038 case. Tuist install/generation repeats in CI.
- `Docs/native-runner-pool.md`: Documents PR 1038 as merged, exact revision opt-in, hosted fallback, per-Mac admission hooks, architecture/host/workspace-separated cache state. This is a live design constraint, not duplication to remove blindly.
- `.github/workflows/release-ios.yml`: Toolchain and API-key setup precede upload-reuse preflight; provisioning/profile validation precedes conditional project generation. Generation also copies Package.resolved and reports keyboard rollout policy. One combined step cannot simply preserve this ordering.
- `.github/workflows/release-mac.yml`: Explicit final always() cleanup deletes signing keychain and ASC key; preserve its end-of-job and failure semantics.
- `.github/workflows/alpha-release.yml; .github/workflows/prepare-stable.yml; .github/workflows/ios-device-matrix.yml`: Alpha/Stable orchestration uses Ubuntu and reusable Apple workers; physical device workflow intentionally selects ios-device hardware. Forcing all through Apple setup or one runner label is unnecessary.

**Dependencies**

- Part of consolidation #1103 E3. Coordinate workflow edits with #1127.
- Owner decision: release worker verification waits for the NEXT real Alpha; do not dispatch release or Stable.
- PR 1038 merged status is supported by native-runner-pool.md; parent can confirm live status from existing repository context before removal.

**Verification**

- Run actionlint and validate local action input/lifecycle syntax against supported schema.
- CI must run relevant changed-action/workflow lanes and pass; account for path filters when extracting action files.
- Check runner selection for approved/unapproved main and same-repository PR SHAs, fork PRs and default/unset variables, retaining local admission controls and cache isolation.
- Review diff for unchanged frozen-manifest checkout, signing/profile checks, generation flags, reuse preflight, release permissions and always() cleanup.
- PR must name release workers as changed but unverified until next real Alpha; no release dispatch for verification.

**Risks and limits**

- No native or release run was performed in this read-only review; static evidence cannot prove signing or device behaviour.
- Literal zero occurrence counts are secondary to preserved gates and correct job execution; do not skip required CI merely to centralise routing.
- Beads CLI is absent per supplied context; this JSON is interim decision evidence, not a replacement tracker.

## #1127: chore(tooling): consolidate release tooling from six languages to shell plus JavaScript

Reviewer: `/root/issue_review_queue/review_1127`.

**Smallest worthwhile scope:** Consolidate Node tooling test discovery behind one documented make test-tooling entry point and one canonical test location, updating moved tests' relative paths and all workflow references.; Include the existing Ruby profile-creation suite in CI immediately; retain Python and Ruby test commands until any separately justified migration achieves parity.; Centralise JS ReleasePipeline loading only where it removes repeated parsing; preserve the distinct ReleaseTrains catalogue and current Swift projection freshness check.; Correct the issue's acceptance criteria to measure complete coverage and unchanged release behaviour. Defer blanket Python/Ruby ports pending concrete maintenance cost or defect evidence.

- `.github/workflows/ci.yml: Test CI and release gates / Test release-notes generator`: Node tests run from scripts/tests, scripts/release-train.test.mjs and Tests/ReleaseNotesTests. Ruby release_apple_test.rb and Python unittest discovery run; create_ios_app_store_profile_test.rb is omitted. generate-release-train-config.py --check already protects projection freshness.
- `scripts/tests/create_ios_app_store_profile_test.rb: IOSProfileBootstrap::FakeTransport / ProvisionerTest`: A self-contained scripted transport suite already tests provisioning conflict handling without live credentials. Adding it to CI provides immediate value without rewriting the ASC client.
- `scripts/release-train.mjs / scripts/release-train-lib.mjs: validateManifest`: The orchestrator reads ReleasePipeline.json at three call sites; the shared library already protects immutable source, tag/train identity, dependency hash and notes hashes. A shared JS config loader can clarify that boundary while preserving these invariants.
- `scripts/generate-release-train-config.py: SOURCE / rendered; Project.swift; Sources/SpeakCore/ReleaseTrainCatalogue.swift`: Swift projection is generated from Sources/SpeakCore/Resources/ReleaseTrains.json. Project.swift reads that same catalogue. The two JSON files have different responsibilities; an exactly-two-readers rule must not conflate them.
- `.github/workflows/release-ios.yml / release-appstore.yml / reconcile-apple-releases.yml`: Production release workers still depend on Python stamping/archive/profile checks and Ruby upload/distribution/reconciliation. Porting them is a separate, higher-risk effort requiring real Alpha evidence.

**Dependencies**

- Coordinate touched test paths and references with dead-file removal #1125 and release consolidation #1126 under epic #1103.
- Owner requires verification in the next real Alpha; no release dispatch is authorised.
- Keep existing frozen manifest and explicit Stable approval gates unchanged.

**Verification**

- Inventory pre/post Node test cases and run all moved suites through the new command to show no coverage loss or relative-path regression.
- Run existing Ruby profile and release tests, Python unittest discovery and projection --check; confirm CI invokes each suite.
- If adding a loader, test missing/invalid config and preservation of existing config values without weakening manifest/hash checks.
- Record next owner-initiated real Alpha verification for any release-path changes. Do not dispatch a release or infer Stable approval from CI.

**Risks and limits**

- Moving tests can break repository-root assumptions and coverage discovery; treat test-count parity and path updates as the primary near-term risk.
- A mechanical rewrite is not proof of equivalence for JWT signing, retries, credentials, keychain cleanup or Apple provisioning.
- Static review and Linux tooling cannot prove an Apple upload or native keychain behaviour.
- Beads CLI is absent per supplied session context; this JSON is interim decision evidence, not a substitute tracker.

## #1128: test: drop swift-snapshot-testing (three PNGs) and fold the Tooling/ SwiftLint graph back into the root package

Reviewer: `/root/issue_review_queue/review_1128`.

**Smallest worthwhile scope:** No repository change for the current proposal. Reconsider a separate, evidence-led dependency change only if measured resolution/build costs justify it and it preserves equivalent rendering regression coverage and independently controlled linter upgrades.

- `Tests/SpeakAppSnapshotTests/ViewSnapshotTests.swift`: Three behavioural view fixtures cover insertion-success HUD, all latency tiers/styles, and multiple audio levels. Shared helper compares full renders at 0.99 pixel and 0.98 perceptual precision; scale, font smoothing and appearance are explicitly controlled. macOS-major skip is an intentional baseline compatibility gate, and comments identify macos-26-arm64 as the CI image.
- `Package.swift`: SnapshotTesting is used only by its test target, not linked as an app target dependency. The root comment documents an actual previous linter downgrade from shared swift-syntax resolution (#677).
- `Tooling/Package.swift`: Independent resolution and a committed tooling lockfile intentionally decouple app/test updates from linter upgrades.
- `scripts/swiftlint.sh`: Wrapper executes SwiftLint binary artifacts from the isolated graph, preserving root-relative lint configuration and baseline paths.
- `AGENTS.md`: Repository instructions explicitly retain isolated SwiftLint resolution to prevent application dependency changes from downgrading lint tooling.

**Dependencies**

- #1103 consolidation epic E5
- #677 documents the isolation rationale; no new dependency conflict needs to be invented to retain isolation.

**Verification**

- For any revised proposal, demonstrate equivalent detection of broken HUD success content, badge layout/styles and audio-meter levels, rather than merely asserting the explicitly imposed image size.
- Preserve native macOS rendering tests and meaningful failure artifacts; verify baseline handling on the CI macOS version.
- Any future linter change must preserve its exact version and demonstrate unchanged normalised JSON violations, with no loss of independent upgrade control.

**Risks and limits**

- Read-only review used four targeted code files; no native rendering, lint execution or dependency resolution was performed.
- Test comments identify the CI platform; the live runner configuration was not separately audited.
- No measured dependency build/download cost is supplied by the issue.
- Beads CLI is unavailable according to parent context; this JSON is analysis evidence only, not an alternative task tracker.

## #1129: docs: rewrite Docs/Architecture.md to cover every module, both platforms, the extensions and the release train

Reviewer: `/root/issue_review_queue/review_1129`.

**Smallest worthwhile scope:** Rewrite Docs/Architecture.md under 400 lines as a current-state map of all SPM/Tuist targets, responsibilities, platform/extension data flows, sync boundaries, automation, observability, build/release train and evidenced concurrency. Use linked concise tables for target inventory and scoped Mermaid diagrams. Replace only AGENTS.md duplicated structure inventory with a doc link, preserving operational rules. Omit speculative target-state architecture or clearly identify links as undecided issue proposals.

- `Docs/Architecture.md`: Current graph starts at SpeakApp/WireUp and describes macOS managers; provider paragraph enumerates five live routes, while threading prose makes broad dedicated-actor/queue claims.
- `Package.swift`: Manifest includes SpeakSync, SpeakAutomationKit, SpeakCLI, SpeakHotKeys, benchmark, demo, binary and test targets beyond the three targets duplicated in AGENTS.md.
- `Project.swift`: Tuist declares macOS/iOS apps, keyboard/share/widgets/watch surfaces and UI-test fixture targets; some extension surfaces are feature-gated, and watch sources deliberately include selected shared files.
- `Sources/SpeakApp/SwitchingLiveTranscriber.swift`: Current ControllerSet still constructs dedicated Deepgram, Modulate, AssemblyAI, ElevenLabs, Soniox, Cartesia, Gladia and OpenAI controllers alongside SharedClientLiveController; the requested universal shared-client claim is not current truth.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: Actual iOS service files include IOSTranscriptionSession and TranscriptionRecordingService; targeted filename/symbol search found no IOSWireUp or IOSAppEnvironment, so those names cannot be documented as existing composition roots.

**Dependencies**

- Related #1113 and #1117 have conditional/narrow scopes; inspect their actual landed changes before documenting shared-controller or iOS composition-root changes. Neither blocks a current-state rewrite.
- #1119 CloudKit container unification needs owner choice and provisioning/device gates; document existing boundaries without suggesting a migration is decided.
- #1122 concurrency audit can supply precise evidence; do not depend on or repeat aspirational actor claims.
- #1125 architecture-description deduplication and AGENTS.md Project Structure edit should be coordinated to avoid conflicting edits.

**Verification**

- Enumerate every target from Package.swift and Project.swift, including conditional, test, demo, benchmark and binary targets; distinguish module dependencies from shared source inclusion.
- Check all code paths and local Markdown links exist, the document is below 400 lines, and the target inventory matches manifests.
- Manually verify claims about cloud provider routing, iOS composition, sync data/key boundaries, extension restrictions and actor ownership against current source; a path check alone cannot validate behaviour.
- Verify release prose preserves explicit Stable publication approval and current Alpha commissioning state. Documentation changes require no native build or device claims.

**Risks and limits**

- Reading future issue descriptions as current architecture would spread false constraints; avoid exact provider counts and unverified numerical extension memory limits.
- Do not claim all keys sync or all long-running IO is off MainActor without direct evidence.
- Linux suffices for document/path checks; it cannot validate microphone, Watch, AX or release provisioning behaviour.
- Beads CLI is absent per supplied context; this JSON is review evidence only, not a replacement tracker.

## #934: iOS: the clipboard holds a placeholder after stop, and a late polish overwrites what the user copied since

Reviewer: `/root/issue_review_queue/review_934`.

**Smallest worthwhile scope:** Keep the device gate open and perform the already requested iPhone acceptance matrix against the current Alpha when available. No new code or planner-to-SOL implementation dispatch is justified by this review; plan qualification only if accepted.

- Sources/SpeakiOS/Services/TranscriptionRecordingService.swift: clipboardTextAtStop returns raw text for Copy and Copy & Polish, nil for empty input/History Only; applyDestinationSideEffects calls copyRaw once and only reads back afterwards.
- Sources/SpeakiOS/Services/TranscriptionRecordingService.swift: startPostProcessing has no clipboard write; success updates the same History item and guards shared latest result by latestCompletionID. Completion settles History and operation assertion.
- Sources/SpeakiOS/Services/AutomaticPolishOperation.swift: PolishClipboard exposes one raw write. AutomaticPolishOperation has no clipboard capability, checks cancellation before and after provider work, handles unavailable background assertion, and uses finished guard for once-only cleanup.
- Tests/SpeakiOSTests/TranscriptionRecordingServiceTextTests.swift: testAutomaticDestinationsNeverWritePolishOrRestoreRaw covers explicit/legacy destinations, unchanged/different/identical/non-text copies, provider success/failure and missing key, asserting only one recorded write; preceding regression preserves recording A polish after cancelling B.
- Sources/SpeakiOS/Views/SettingsView.swift: destination summary uses approved Raw transcript is copied immediately. Polished text is saved in History. wording.
- Historical main commit f8af0b11 includes #1031 but explicitly states real hardware was not tested; cached issue comments contain no later device evidence.

**Dependencies**

- #1031 implementation was carried in main integration commit f8af0b11; do not create a duplicate fix.
- #945 owns outcome/read-back claims; #1001 owns explicit result Copy UI; #994 owns clipboard privacy settings.
- Physical iPhone and Apple Xcode environment needed for remaining delivery evidence.

**Verification**

- Record iOS version, build, trigger and foreground/background/locked execution state. Verify immediate paste contains raw transcript and delayed polish is in the same History item.
- Copy different, identical and non-text content in another app during polish and confirm survival across success/failure and background transitions; exercise locked Stop then unlock/paste.
- Run relevant iOS tests on Apple CI/device tooling and retain cancellation/expiration/out-of-order regressions. This review inspected their source; it did not execute them.

**Risks and limits**

- Static inspection and clipboard read-back do not establish physical device clipboard delivery. Do not close the explicit hardware gate on merged-code evidence alone.
- Do not introduce ownership-token replacement, a new foreground timeout, new Copy UI, release dispatch or container changes.
- Beads CLI is absent according to supplied review context; no tracker mutation or external post performed.

## #935: iOS: a Bluetooth route or engine configuration change silently kills capture

Reviewer: `/root/issue_review_queue/review_935`.

**Smallest worthwhile scope:** Retain #935 only as a device-acceptance gate: qualify controlled stop and saved output on physical iPhone across Apple capture, OpenAI Realtime and one shared backend, including hands-free armed and active utterance states. No new recovery architecture or speculative implementation.

- `Sources/SpeakCore/CaptureDisruptionObserver.swift`: Per-engine notification object filter, MainActor hop, capture generation check, usability check and subscription retirement coalesce disruption and invalidate queued stale callbacks.
- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Owned-engine configuration observer stops tap/engine and delegates provider draining through normal owner finalisation. Equivalent observer wiring exists in iOSLiveTranscriber.swift and OpenAIRealtimeLiveTranscriber.swift.
- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: Controlled stop retains active utterance ownership while finalising, stops detector subscriptions, and rejects a stale detector session ID.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Current session and lifecycle guards protect finalisation; originating capture callback preserves keyboard ownership, and automaticStopDestination preserves selected output routing.
- `Tests/SpeakCoreTests/CaptureDisruptionObserverTests.swift; Tests/SpeakiOSTests/HandsFreeCaptureDisruptionTests.swift`: Existing meaningful lifecycle regressions target duplicate/stale events, usable routes and active-utterance finalisation. Test presence is inspected, not a claimed execution result.

**Dependencies**

- #1032 implementation is carried by main integration commit f8af0b11d5c41fe6fd1fe06a95f351ca118a1780; the merge message explicitly says real iOS hardware was not tested.
- #936 owns interruption policy; #934 owns clipboard safety; preserve their integrated behaviour.
- Use the next available real Alpha/device validation opportunity; do not dispatch a release for this review.

**Verification**

- Record iPhone, iOS, headset and provider versions. Reproduce a real Bluetooth/route-format disruption and distinguish actual capture cessation from harmless route notification.
- Verify one finalisation, truthful stopped presentation, retained text/audio, correct history-only/keyboard/default destination, no duplicate output and successful fresh capture after route settles.
- Exercise harmless input-preserving route changes without disarming hands-free; verify actual lost input/stopped detector preserves an active utterance before disarming.
- Existing notification/lifecycle tests and Apple-native gates support software claims; attach actual device evidence before declaring full issue acceptance.

**Risks and limits**

- Static code inspection cannot establish physical Bluetooth or microphone behaviour; no native tests or device experiments were run in this review.
- Automatic continuation remains explicitly deferred and is not acceptance scope.
- Bounded inspection found implementation coverage, not an exhaustive correctness audit.
- Beads CLI is unavailable according to the supplied context; this scratch JSON is review evidence, not a replacement tracker.

## #946: iOS: the Siri stop phrase arrives as an interruption, ignoring the destination and raising a stale error

Reviewer: `/root/issue_review_queue/review_946`.

**Smallest worthwhile scope:** Run the dedicated Siri Stop phrase on a physical iPhone with integrated #935/#936 and record non-sensitive event/run ordering and returned dialogue. If a residual defect is shown, plan only truthful acknowledgement associated with that same run; otherwise close as covered. No implementation dispatch now.

- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Automatic destination is captured at start; controlled interruption sets captureStopNotice instead of lastSessionError, then finalises through the original owner or automaticStopDestination.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Still snapshots service.isActive; an inactive service produces foreground-stop guidance or No active recording. This permits an ordering-dependent acknowledgement but does not establish actual Siri execution order.
- `Sources/SpeakCore/RecordingLifecycleCoordinator.swift`: Only starting and recording count as active, excluding stopping.
- `Docs/ios-interruption-finalisation.md`: Explicitly retains physical Siri/background/locked capture validation and #946 acknowledgement as separate work.
- #936 landed controlled interruption finalisation; commit explicitly retains #946 residual acknowledgement. Cached comments are empty.

**Dependencies**

- #936 implemented; physical-device acceptance remains outstanding
- #935 controlled-stop ownership
- #945 owns Live Activity outcome wording, not Siri dialogue

**Verification**

- Cover unlocked and locked/background dedicated Siri Stop plus ordinary dedicated Stop shortcut control, recording device/iOS/build/provider.
- Verify original History Only, clipboard and Copy & Polish destinations and no stale failure alert.
- Capture interruption, intent entry, stopping, completion and dialogue ordering without transcript logging.
- Any justified later fix must keep idle Stop a no-op, avoid repeated delivery, and prevent an older run acknowledgement reaching a newer run; native tests and physical replay are required.

**Risks and limits**

- Static code review cannot establish Siri or microphone timing, device behaviour or successful physical acceptance.
- Do not introduce arbitrary grace periods, generic-interruption Siri attribution, transcript replay/cache, automatic resume or changed toggle/authentication semantics.
- Apple Swift/Xcode unavailable in this Linux environment; no native execution claimed.
- Beads CLI absent per review context; this JSON is review evidence only.

## #947: iOS: verify suspected Modulate opening-audio loss before adding preroll

Reviewer: `/root/issue_review_queue/review_947`.

**Smallest worthwhile scope:** A local, synthetic PCM qualification harness or narrowly scoped test instrumentation that runs start-before-capture against an actually delayed WebSocket handshake, records ordered chunk IDs/counts and task/handshake state, and compares received bytes. Use an existing injection seam or minimal test-only endpoint seam where viable. Do not implement a five-second buffer, provider-wide audit, common transport redesign or production telemetry. An independent planner must establish a viable Apple-runtime execution path before calling this qualified.

- `Sources/SpeakCore/ModulateLiveClient.swift`: start assigns the WebSocket task and resumes it synchronously. sendAudio guards task.running, adds the WAV header once, and reports send errors. A guard alone establishes possible discard before start/after stop, not handshake-pending loss.
- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Current iOS code calls client.start before invoking capture startup, including the injectable startCaptureAudio seam. This ordering invalidates no-start tests as an actual startup reproduction.
- `Tests/SpeakCoreTests/StreamingAudioPrerollTests.swift`: Existing test explicitly omits start and inspects buffer content. Its comment equating this with the handshake window is unsupported; it cannot establish the Modulate issue.
- `comments/947.json`: Historical comment itself concedes no device reproduction and no satisfaction of the re-entry gate. Its absence-of-buffer observation does not override the subsequently corrected issue body.

**Dependencies**

- Recheck lifecycle after #943; no hard dependency established.
- #998 / PR #1072 covers generic preroll tests, not real delayed-handshake startup qualification.
- Do not absorb #935, #936, #942, #946 or #934.
- macOS uses a separate provider path and requires separate evidence.

**Verification**

- Execute the actual resumed URLSession WebSocket with a delayed handshake; a fake transport or no-start buffer inspection alone is insufficient.
- Distinguish before-start sends, handshake-pending sends, transport failure and after-stop sends. Verify capture-order bytes, no gaps/duplicates and exactly one WAV header.
- Log only synthetic data identifiers and counts; exclude API keys, URLs containing credentials and user audio.
- If actual startup loss is reproduced, retain failing regression evidence and approve only a Modulate-specific fix with bounded overflow and cancellation/restart cleanup. If no loss is reproduced, close with evidence instead of adding buffering.
- Any opening-speech-fix claim additionally requires physical iPhone/TestFlight immediate known-phrase testing with delayed connectivity and recording/transcript comparison.

**Risks and limits**

- Read-only static review; no runtime, microphone, handshake delay or device behaviour verified.
- Apple Swift/Xcode execution is required for trustworthy platform transport results; Linux-only simulation cannot satisfy that gate.
- Do not infer task.running means handshake complete.
- Production buffering remains DEFERRED despite acceptance of qualification work.
- Beads CLI is absent per supplied session context; this JSON is review evidence only.

## #954: iOS: explain native Control setup and add accurate Action Button hints

Reviewer: `/root/issue_review_queue/review_954`.

**Smallest worthwhile scope:** No new feature code. Narrow this issue to a recorded real-iPhone walkthrough of the already implemented setup and hints, plus Dynamic Type and VoiceOver inspection. Make a code change only for an observed mismatch.

- `Sources/SpeakiOS/Views/SettingsView.swift`: Provides iOS 18 availability gating, Action Button Controls picker and press-and-hold instructions, Control Center and distinct bottom Lock Screen control setup. Preserves Shortcut, Back Tap, destination-specific guidance, no extra clipboard step, and first-use permission/unlock caveats.
- `JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtensionControl.swift`: Existing Control uses shared kind and ToggleTranscriptionControlIntent, destination-neutral description, and controlWidgetActionHint with Start for represented on state and Stop for represented off state as required by the issue.
- `Sources/SpeakiOS/Services/CaptureSurfaceRefresher.swift`: Shared Control identity and targeted control reload implementation are present; do not duplicate state publication here.
- `issue-commit-evidence.json`: Integration commit carries #1050 plus #1035 and explicitly leaves real-device verification outstanding. Source inspection independently confirms setup and hint implementation.

**Dependencies**

- #1050 implementation carried in integration main; stale issue comment describing unmerged #1025 no longer describes current source.
- #941/#1035 state behavior and #943 ownership must remain with their owners; do not introduce a parallel lifecycle fix.
- #953 background-start device qualification remains separate.
- #955 widget work is separate from Lock Screen bottom controls.

**Verification**

- On supported iOS 18.x and 26.x devices, follow all three native placement instructions and record device, OS and installed build.
- Verify displayed Start/Stop action hints in both directions, retained Control placements, Shortcut execution and selected result destination.
- Exercise app/Live Activity state changes with the integrated state fixes; record any permission, unlock or foreground prompt truthfully.
- Inspect the settings screen with Dynamic Type and VoiceOver; use an actual Apple SDK app/extension build if a correction is necessary.

**Risks and limits**

- Read-only code inspection confirms implementation, not actual picker labels, Action Button behavior or locked microphone capture. No device result was obtained in this review.
- The merge evidence explicitly says all device-dependent behavior remains unverified, so unconditional closure would discard an explicit acceptance requirement.
- Beads CLI is absent per supplied context; this JSON is interim review evidence and not a task tracker.
