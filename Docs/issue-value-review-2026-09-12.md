# Issue value review — 12 September 2026

This is review evidence, not a replacement for the canonical issue tracker. The initial inventory contained 98 open issues and four open PRs. This checkpoint contains 98 completed independent issue reviews, covering the entire initial inventory. Implementation and validation are separate from these recommendations.

## Method and product goals

Each issue receives its own value-review agent. Accepted scope goes to a different planning agent, then gpt-5.6-sol at medium reasoning for implementation. Reviews use source baseline `51286c58`, current issue bodies/comments, open PRs and recorded project decisions. During review, main advanced to `2ff982d` when Compare Models PR #1102 merged; relevant later plans account for those consumers.

Priorities: reliable and fast dictation; preserve first and final words; privacy and on-device options; transparent BYOK costs; native accessible controls; shared catalogues with deliberate platform differences. Refactor incrementally rather than rewrite. Existing PRs, device acceptance, provider access and explicit owner decisions remain separate gates.

Native Apple builds and physical device checks cannot run on this Linux host. No native/device verification is implied by a decision.

## Implementation evidence

[Draft PR #1130](https://github.com/crmitchelmore/justspeaktoit/pull/1130) implements #1104. Its published tree matches the locally reviewed tree. Initial Apple CI found two initializer compiler errors and 15 lint findings; corrections are published at `2bb644d`. Its iOS job passed 480 unit cases and six simulator UI cases; the Mac suite ran 3,431 cases with five skips and one stale ElevenLabs contract expectation. That expectation plus fixture race fixes are published at `dea8de8b` for rerun; native final acceptance remains pending.

[Draft PR #1131](https://github.com/crmitchelmore/justspeaktoit/pull/1131) implements #1115 settings extraction. The exact 17 persisted keys have a compatibility test, moved bodies were mechanically checked, Apple CI found a cross-file access error in APIKeysView.entries; the one-line internal-visibility correction is published at `b7f05f2`; inherited extra blank lines are corrected at `93d140b` for rerun. Simulator navigation remains pending.

[Draft PR #1132](https://github.com/crmitchelmore/justspeaktoit/pull/1132) implements #1120 benchmark isolation. All eleven moved source/test files preserve their bytes, the checksum and legacy decoding remain, and an independent native benchmark CI gate is added. Native resolution and the real binary checksum passed. Native lockfile drift identified five unreachable test/tooling pins; the exact native correction is published at `de20d22`. Retained dependency versions are unchanged. Benchmark build/test qualification remains pending.

[Draft PR #1133](https://github.com/crmitchelmore/justspeaktoit/pull/1133) implements #1125 retired tooling cleanup. 100 Node tests pass. Conformance removal remains gated by legacy branch-protection verification: the connector returned 403 for that separate protection family; active rulesets do not require it.

[Draft PR #1134](https://github.com/crmitchelmore/justspeaktoit/pull/1134) implements #1129 current architecture documentation. Manifest, source, link and fence checks passed. This describes current ownership and outstanding risks.

[Draft PR #1135](https://github.com/crmitchelmore/justspeaktoit/pull/1135) implements #1127 tooling test discovery. 125 Node and 40 Python tests plus projection checks passed. Ruby is unavailable locally and its CI gate remains required.

[Draft PR #1136](https://github.com/crmitchelmore/justspeaktoit/pull/1136) implements #994 clipboard privacy on #1131. It defaults transcript copies to local-only with five-minute system expiry, exposes finite lifetime and Universal Clipboard choices, and preserves later-copy ownership. Policy/persistence tests are added; Apple execution and device expiry/Handoff remain gates. Native lint found two long internal identifiers and two blank-line violations; `c06de6d` corrects them without changing persisted names. The fix is merged into dependent #1137 and #1139 drafts.

[Draft PR #1137](https://github.com/crmitchelmore/justspeaktoit/pull/1137) implements #996 safe startup error recovery on #1136. It distinguishes actual missing keys, locked storage and permission denial, keeps cancellation/ownership suppression, and does not expose arbitrary provider descriptions at startup alerts/intents. Focused tests are added; Apple execution, Settings navigation and device continuation remain gates. Published commit: `09003d5`.

[Draft PR #1138](https://github.com/crmitchelmore/justspeaktoit/pull/1138) implements #661 keyboard documentation corrections. The three runbooks now match shipping handoff and manifest/train identities; source/link checks passed. Physical acceptance stays open.

[Draft PR #1139](https://github.com/crmitchelmore/justspeaktoit/pull/1139) implements #999 strict offline capture on #1137. Known-offline ordinary live requests may select a capable local recognizer, while explicit/profile remote requests refuse. The final Apple backend remains strict after missing-key fallback and on rolling restarts. Native/device network qualification is pending.

[Draft PR #1140](https://github.com/crmitchelmore/justspeaktoit/pull/1140) implements #664 verification runbook and result template. It preserves Chris’s detailed TextEdit results, Notes and baseline blocked rows, and the distinction between exact delivery and preserving user edits. Source/link checks passed; it asserts no new Mac run.

[Draft PR #1141](https://github.com/crmitchelmore/justspeaktoit/pull/1141) implements #963 Stop-only small Live Activity presentation. iOS 18 guards, all ten states, 44-point Stop target and privacy-minimal content are source-checked; native rendering and paired tap/Double Tap delivery remain required. Existing owner and completion semantics are preserved.

[Draft PR #1142](https://github.com/crmitchelmore/justspeaktoit/pull/1142) prepares #1105 AssemblyAI shared-path parity on #1130. It adds optional snapshots/boundaries, framed bounded PCM and ordered graceful finish. Parent review corrected a stale member reference, callback lifetime, stalled-send bounds and authoritative snapshot replacement. Legacy APIs remain; the dedicated Mac controller and production route stay until native/provider parity is proven. Static checks passed; Apple execution remains pending. Published commit: `04435b5`.

Detailed accepted-scope plans are in `issue-plans-2026-09-12/`. [Runtime analytics qualification](issue-plans-2026-09-12/1121-evidence.md) found insufficient runtime-identifying production telemetry; unavailable usage is not zero usage.

## Delivery checkpoint

These rows distinguish review approval from delivered work. Draft PRs are unmerged and retain the native, device, access or owner gates in their descriptions and plans. A plan-only row is still outstanding.

| Issue | Plan | Delivery evidence |
|---|---|---|
| #1009 | [Detailed plan](issue-plans-2026-09-12/1009.md) | Plan only; SOL deliverable outstanding |
| #1010 | [Detailed plan](issue-plans-2026-09-12/1010.md) | Plan only; SOL deliverable outstanding |
| #1014 | [Detailed plan](issue-plans-2026-09-12/1014.md) | Plan only; SOL deliverable outstanding |
| #1016 | [Detailed plan](issue-plans-2026-09-12/1016.md) | Plan only; SOL deliverable outstanding |
| #1017 | [Detailed plan](issue-plans-2026-09-12/1017.md) | Plan only; SOL deliverable outstanding |
| #1018 | [Detailed plan](issue-plans-2026-09-12/1018.md) | Plan only; SOL deliverable outstanding |
| #1021 | [Detailed plan](issue-plans-2026-09-12/1021.md) | Plan only; SOL deliverable outstanding |
| #1027 | [Detailed plan](issue-plans-2026-09-12/1027.md) | This review and delivery matrix provide coordination evidence; epic acceptance remains open |
| #1051 | Planning in progress | Plan only; SOL deliverable outstanding |
| #1052 | Planning in progress | Plan only; SOL deliverable outstanding |
| #1088 | Planning in progress | Plan only; SOL deliverable outstanding |
| #1103 | [Detailed plan](issue-plans-2026-09-12/1103.md) | This review and delivery matrix provide coordination evidence; epic acceptance remains open |
| #1104 | [Detailed plan](issue-plans-2026-09-12/1104.md) | [Draft #1130](https://github.com/crmitchelmore/justspeaktoit/pull/1130), `dea8de8b`; unmerged, acceptance pending |
| #1105 | [Detailed plan](issue-plans-2026-09-12/1105.md) | [Draft #1142](https://github.com/crmitchelmore/justspeaktoit/pull/1142), `04435b53`; unmerged, acceptance pending |
| #1106 | [Detailed plan](issue-plans-2026-09-12/1106.md) | Plan only; SOL deliverable outstanding |
| #1107 | [Detailed plan](issue-plans-2026-09-12/1107.md) | Plan only; SOL deliverable outstanding |
| #1108 | [Detailed plan](issue-plans-2026-09-12/1108.md) | Plan only; SOL deliverable outstanding |
| #1109 | [Detailed plan](issue-plans-2026-09-12/1109.md) | Plan only; SOL deliverable outstanding |
| #1110 | [Detailed plan](issue-plans-2026-09-12/1110.md) | Plan only; SOL deliverable outstanding |
| #1111 | [Detailed plan](issue-plans-2026-09-12/1111.md) | Plan only; SOL deliverable outstanding |
| #1112 | [Detailed plan](issue-plans-2026-09-12/1112.md) | Plan only; SOL deliverable outstanding |
| #1113 | [Detailed plan](issue-plans-2026-09-12/1113.md) | Plan only; SOL deliverable outstanding |
| #1114 | [Detailed plan](issue-plans-2026-09-12/1114.md) | Plan only; SOL deliverable outstanding |
| #1115 | [Detailed plan](issue-plans-2026-09-12/1115.md) | [Draft #1131](https://github.com/crmitchelmore/justspeaktoit/pull/1131), `93d140b4`; unmerged, acceptance pending |
| #1116 | [Detailed plan](issue-plans-2026-09-12/1116.md) | Plan only; SOL deliverable outstanding |
| #1117 | [Detailed plan](issue-plans-2026-09-12/1117.md) | Plan only; SOL deliverable outstanding |
| #1118 | [Detailed plan](issue-plans-2026-09-12/1118.md) | Plan only; SOL deliverable outstanding |
| #1120 | [Detailed plan](issue-plans-2026-09-12/1120.md) | [Draft #1132](https://github.com/crmitchelmore/justspeaktoit/pull/1132), `de20d22c`; unmerged, acceptance pending |
| #1121 | [Detailed plan](issue-plans-2026-09-12/1121.md) | [Qualification brief](issue-plans-2026-09-12/1121-evidence.md); usage unavailable, owner choice pending |
| #1122 | [Detailed plan](issue-plans-2026-09-12/1122.md) | Plan only; SOL deliverable outstanding |
| #1123 | [Detailed plan](issue-plans-2026-09-12/1123.md) | Plan only; SOL deliverable outstanding |
| #1124 | [Detailed plan](issue-plans-2026-09-12/1124.md) | Plan only; SOL deliverable outstanding |
| #1125 | [Detailed plan](issue-plans-2026-09-12/1125.md) | [Draft #1133](https://github.com/crmitchelmore/justspeaktoit/pull/1133), `86801ffb`; unmerged, acceptance pending |
| #1126 | [Detailed plan](issue-plans-2026-09-12/1126.md) | Plan only; SOL deliverable outstanding |
| #1127 | [Detailed plan](issue-plans-2026-09-12/1127.md) | [Draft #1135](https://github.com/crmitchelmore/justspeaktoit/pull/1135), `5c3e2a66`; unmerged, acceptance pending |
| #1129 | [Detailed plan](issue-plans-2026-09-12/1129.md) | [Draft #1134](https://github.com/crmitchelmore/justspeaktoit/pull/1134), `5d0802b9`; unmerged, acceptance pending |
| #485 | [Detailed plan](issue-plans-2026-09-12/485.md) | Plan only; SOL deliverable outstanding |
| #611 | [Detailed plan](issue-plans-2026-09-12/611.md) | Plan only; SOL deliverable outstanding |
| #614 | [Detailed plan](issue-plans-2026-09-12/614.md) | Plan only; SOL deliverable outstanding |
| #656 | [Detailed plan](issue-plans-2026-09-12/656.md) | Plan only; SOL deliverable outstanding |
| #661 | [Detailed plan](issue-plans-2026-09-12/661.md) | [Draft #1138](https://github.com/crmitchelmore/justspeaktoit/pull/1138), `efcad5ee`; unmerged, acceptance pending |
| #664 | [Detailed plan](issue-plans-2026-09-12/664.md) | [Draft #1140](https://github.com/crmitchelmore/justspeaktoit/pull/1140), `1141e47e`; unmerged, acceptance pending |
| #776 | [Detailed plan](issue-plans-2026-09-12/776.md) | Plan only; SOL deliverable outstanding |
| #802 | [Detailed plan](issue-plans-2026-09-12/802.md) | Plan only; SOL deliverable outstanding |
| #821 | [Detailed plan](issue-plans-2026-09-12/821.md) | Plan only; SOL deliverable outstanding |
| #919 | [Detailed plan](issue-plans-2026-09-12/919.md) | Plan only; SOL deliverable outstanding |
| #934 | [Detailed plan](issue-plans-2026-09-12/934.md) | Plan only; SOL deliverable outstanding |
| #935 | [Detailed plan](issue-plans-2026-09-12/935.md) | Plan only; SOL deliverable outstanding |
| #947 | [Detailed plan](issue-plans-2026-09-12/947.md) | Plan only; SOL deliverable outstanding |
| #954 | [Detailed plan](issue-plans-2026-09-12/954.md) | Plan only; SOL deliverable outstanding |
| #963 | [Detailed plan](issue-plans-2026-09-12/963.md) | [Draft #1141](https://github.com/crmitchelmore/justspeaktoit/pull/1141), `e094c924`; unmerged, acceptance pending |
| #994 | [Detailed plan](issue-plans-2026-09-12/994.md) | [Draft #1136](https://github.com/crmitchelmore/justspeaktoit/pull/1136), `c06de6de`; unmerged, acceptance pending |
| #996 | [Detailed plan](issue-plans-2026-09-12/996.md) | [Draft #1137](https://github.com/crmitchelmore/justspeaktoit/pull/1137), `09003d54`; unmerged, acceptance pending |
| #999 | [Detailed plan](issue-plans-2026-09-12/999.md) | [Draft #1139](https://github.com/crmitchelmore/justspeaktoit/pull/1139), `f33cc187`; unmerged, acceptance pending |

## Decisions

| Issue | Decision | Value |
|---|---|---|
| [#1009](https://github.com/crmitchelmore/justspeaktoit/issues/1009) — Spoken routing: end with to Notes, to Mac, as a reminder, just copy and it goes there | NARROW | Proceed with a small deterministic, explicitly enabled spoken-command option for supported local destinations. This removes a settings interaction during hands-free capture while protecting the primary promise of preserving dictated words. The proposed Notes/Reminders/Mac/agent/LLM routing platform exceeds demonstrated value and current executors; no new transport or paid processing should be introduced here. |
| [#1010](https://github.com/crmitchelmore/justspeaktoit/issues/1010) — Agent conversation mode: Action Button talks to your AI agent, reply arrives on the lock screen | NARROW | A deliberate agent conversation can reduce interaction while hands are occupied, but the default product remains instant, private dictation. Proceed only with bounded qualification of the existing OpenClaw path; the proposed public destination, sticky routing and lock-screen reply feature do not yet have enough lifecycle evidence to implement safely. |
| [#1014](https://github.com/crmitchelmore/justspeaktoit/issues/1014) — Focus filters choose destination, profile and model (SetFocusFilterIntent) | NARROW | Proceed with a small opt-in Focus override for existing capture destinations and the already-supported per-run model/language fields. Automatic history-only capture has concrete privacy value and removes repeated Settings changes. A new general profile system and the removed Send to Mac destination add unnecessary scope. |
| [#1016](https://github.com/crmitchelmore/justspeaktoit/issues/1016) — Return a TranscriptEntity with a Siri result snippet, and index dictations for Siri | NARROW | Structured transcript output has practical Shortcuts value: users can select raw or polished text and retain stable identity instead of parsing a string. Begin with an authenticated history entity and a new Get Last Transcript action. Automatic Siri indexing, speculative OS-27 sync and multiple follow-up buttons add privacy and platform scope without improving core capture reliability. Existing receipt-backed Siri stop feedback reduces the urgency of a new snippet. |
| [#1017](https://github.com/crmitchelmore/justspeaktoit/issues/1017) — An automation-friendly "Transcript ready" notification for the iOS 27 notification trigger | NARROW | An explicitly enabled, privacy-preserving completion notification has useful independent value for background dictation and Watch imports: users can discover that their saved result is ready without reopening History speculatively. The existing delivery and Live Activity surfaces already cover much of the journey. Do not justify implementation with unverified iOS 27 automation or latency claims. Proceed only with a small completion-notification scope; qualify automation separately before templates or marketing. |
| [#1018](https://github.com/crmitchelmore/justspeaktoit/issues/1018) — iOS 27 LongRunningIntent + ExecutionTargets for 'stop, transcribe, deliver' (beta, verify at GM) | NARROW | Reliable completion after stopping supports the core dictation promise, but the original clipboard-placeholder rationale is obsolete. Proceed only with a shipping-SDK/device qualification spike; do not adopt the proposed APIs as an assumed production fix. Native progress could be valuable if it extends a demonstrably failing post-stop operation without delaying raw text. |
| [#1021](https://github.com/crmitchelmore/justspeaktoit/issues/1021) — Agent-awaitable phone dictation: speak await / MCP await_transcript | NARROW | Proceed with a bounded local automation wait. Agents can receive a newly completed dictation without clipboard transfer or repeated history polling; this directly reduces friction in the existing dictation workflow. The existing CLI/MCP are the right extension point, but phone/watch reliability and unrelated-transcript attribution must not be assumed. Do not add or restore Send to Mac transport. |
| [#1024](https://github.com/crmitchelmore/justspeaktoit/issues/1024) — Send to Mac as a real headless destination on the existing transport (superseded by removal) | REJECT | Do not implement the original proposal. The explicit 9 September owner decision removed Send to Mac, and current code and documentation match that decision. Restoring pairing, reconnect, receipts and automatic cursor insertion would reopen a deliberately removed feature and add reliability, privacy and wrong-window risks to the core fast-dictation workflow. The issue remains useful as historical design evidence, not active implementation scope. |
| [#1027](https://github.com/crmitchelmore/justspeaktoit/issues/1027) — Epic: iOS capture — make one press always work, never lose the first words, land the text where the user was typing | NARROW | The outcome is the core product promise: reliable instant dictation with preserved text and truthful destination feedback. Retain the epic as an evidence-led coordination and qualification checklist. Its large implementation inventory describes old snapshots, duplicates implemented children, and includes optional experiments that must not become prerequisites for core reliability. No separate giant implementation is justified. |
| [#1051](https://github.com/crmitchelmore/justspeaktoit/issues/1051) — feat: add direct Azure Speech and MAI batch and live transcription | NARROW | Direct Azure input is explicitly requested and supports BYOK/provider choice. Current main already implements direct batch and actual live transcription, so another adapter adds no value. Keep this issue as the installed-app acceptance record; focus remaining effort on real picker/microphone/finalisation acceptance and any concrete defects it exposes. |
| [#1052](https://github.com/crmitchelmore/justspeaktoit/issues/1052) — feat: add Azure MAI-Voice speech generation | NARROW | Explicitly requested speech output capability fits BYOK choice and transparent costs, but the substantive MAI synthesis integration already exists. Proceed with bounded qualification and any evidenced failure-handling fixes, rather than implementing another catalogue or route. Do not close against mocked or compiled-client evidence alone. |
| [#1087](https://github.com/crmitchelmore/justspeaktoit/issues/1087) — feat: add hosted Bodhan Indic-Transcribe and Indic-Speak after API qualification | DEFER | Hosted Indic speech could improve English/Hindi dictation and playback without a local runtime, which is a useful BYOK extension. The issue explicitly conditions implementation on real API qualification; supplied access evidence still shows no signed-in account, separate usable keys or verified free credit. Shipping a selectable provider now would risk unreliable dictation and unclear cost for no demonstrated quality gain. Resume qualification when authorised access exists, then reassess implementation. |
| [#1088](https://github.com/crmitchelmore/justspeaktoit/issues/1088) — research(mac): qualify AuK and AuK-Flash within a supported local TTS runtime | NARROW | Private text-only speech generation fits the local-first product goal, but a new model must improve usable speech quality or latency over existing system voices. Proceed only with bounded runtime qualification and a go/no-go record; app integration has no demonstrated value until actual Apple playback and resource use are measured. |
| [#1089](https://github.com/crmitchelmore/justspeaktoit/issues/1089) — research: qualify hosted Tontaube speech API and distinguish it from local V1 | DEFER | Hosted Tontaube qualification is worthwhile provider-choice research, but its benefit to native speech playback remains unproved. The supplied issue records no authorised API key; without that, implementing a selectable provider would add a failing path and undermine reliable playback and transparent capabilities. Preserve the research issue and resume when free authorised access is available. |
| [#1101](https://github.com/crmitchelmore/justspeaktoit/issues/1101) — Compare models: run one audio sample through N transcription models, judge blind, keep a scoreboard | ALREADY COVERED | High product value: personal blind comparisons let users choose transcription quality, latency and cost for their own voice. PR #1102 has now merged and implements this feature; a second implementation would duplicate working architecture. Retain the issue acceptance as a validation gate rather than start another feature build. |
| [#1103](https://github.com/crmitchelmore/justspeaktoit/issues/1103) — Epic: consolidation roadmap — one provider stack, one iOS composition root, one history and sync path | NARROW | Retain this as coordination for incremental reliability and maintenance improvements, with each child governed by its independent value review. Shared provider contracts reduce platform drift, targeted dependency injection improves lifecycle testing, and safer history IO protects transcripts and responsiveness. The line-count and language-count targets do not justify a bulk rewrite or deletion of useful coverage. No additional umbrella implementation PR is warranted. |
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
| [#485](https://github.com/crmitchelmore/justspeaktoit/issues/485) — Investigate local/on-device Voxtral realtime support | NARROW | Proceed with a bounded macOS Apple Silicon qualification, then a measured go/no-go. The explicit P1 provider request makes assessing the absent local capability worthwhile; cloud Voxtral does not meet offline/privacy needs. Existing local transcription lowers the value of adding a large runtime without measured accuracy, language or latency benefit. Research is authorised now; production integration is not yet justified by the evidence. |
| [#611](https://github.com/crmitchelmore/justspeaktoit/issues/611) — Streaming insertion + latency as a first-class metric | NARROW | Fast, trustworthy dictation is the primary product goal, but most proposed software already exists. Proceed with a bounded measurement and target-qualification plan; do not rebuild insertion or latency UI, widen the AX allowlist to meet a numeric target, or optimise cold start without measured bottlenecks. |
| [#614](https://github.com/crmitchelmore/justspeaktoit/issues/614) — Adopt SpeechAnalyzer/DictationTranscriber (iOS 26/macOS Tahoe) + voice-activated hands-free mode | NARROW | The on-device default and optional hands-free mode match fast, private, accessible dictation. Both now exist in main, so another implementation would duplicate working architecture. Narrow this parent issue to device qualification and accurate acceptance wording; its older comments incorrectly describe hands-free as unimplemented. |
| [#648](https://github.com/crmitchelmore/justspeaktoit/issues/648) — [Feature] Paid Access | ALREADY COVERED | Optional managed billing removes API-key setup friction for nontechnical users and has clear value, provided local/BYOK remain first-class and costs are explicit. PR #665 already owns this implementation, including simplified model selection and post-processing. A second implementation would duplicate sensitive billing/routing state and reduce reliability. Coverage means existing ownership, not shipped or launch-ready. |
| [#655](https://github.com/crmitchelmore/justspeaktoit/issues/655) — Automation surface phase 2: `speak` CLI over the local transport | DEFER | The CLI has clear value for developers who need repeatable transcription with the same configured providers and keys as the native app. Its implementation already exists; more feature code is not justified by the remaining acceptance gaps. Keep the issue open for released-app provider and current Homebrew distribution evidence. |
| [#656](https://github.com/crmitchelmore/justspeaktoit/issues/656) — Automation surface phase 3: MCP server exposing dictation tools | NARROW | The implemented local MCP surface directly supports agent-assisted dictation without moving provider credentials outside the app. Building another server has no value. Finish the remaining named-client qualification so users can rely on the documented Claude Code setup; retain the explicit opt-in privacy boundary. |
| [#657](https://github.com/crmitchelmore/justspeaktoit/issues/657) — watch: complication + Smart Stack entry to start recording from the watch face | ALREADY COVERED | Starting a short voice capture from the watch face directly supports instant native dictation. The requested implementation is already present; duplicating it adds no value. Keep the issue open as the explicit paired-device acceptance gate rather than commission another feature implementation. |
| [#659](https://github.com/crmitchelmore/justspeaktoit/issues/659) — watch: extended runtime session for wrist-down recordings | DEFER | Keeping every spoken word during wrist-down capture is core reliability value. The implementation already uses the ordinary audio background mechanism with interruption handling, durable active-capture recovery and idempotent finalisation. Latest issue comments explicitly narrow remaining acceptance to paired hardware. Further runtime code without a demonstrated failure has low value and risks replacing a deliberate policy choice with an unrelated extended-runtime category. Defer additional implementation, preserve the hardware gate and do not close as verified. |
| [#661](https://github.com/crmitchelmore/justspeaktoit/issues/661) — iOS keyboard v2: run the physical-device matrix and flip the TestFlight flag | NARROW | Reliable dictation into other apps is central to the product, but this issue's original flag-flip and direct-capture assumptions are stale. The shipping keyboard already uses handoff, while the design document now records direct microphone capture as unavailable and retained only for possible future platform changes. A small documentation correction is valuable now because the existing runbook would send testers to nonexistent manual workflow inputs and imply that direct capture is a current rollout goal. Physical handoff verification remains valuable and open. |
| [#664](https://github.com/crmitchelmore/justspeaktoit/issues/664) — test(mac): verify streaming insertion across the allowlisted target apps | NARROW | Proceed with the remaining two-app qualification gate because safe, exact insertion is core to reliable dictation. Preserve completed TextEdit evidence, finish Notes and both one-shot baselines, and keep five-app expansion in #611. No replacement streaming implementation or broad test tooling project is justified by this issue. |
| [#776](https://github.com/crmitchelmore/justspeaktoit/issues/776) — Ship opt-in PostHog analytics transport, consent UI and audited rollout | NARROW | Proceed with the missing direct-macOS privacy controls and qualification evidence. An exact-payload inspector and operational local kill switch make the approved consent promise inspectable and give users control without affecting fast dictation. The transport, consent toggle and initial events already exist; rebuilding them or enabling wider collection has low value and would violate explicit rollout gates. |
| [#802](https://github.com/crmitchelmore/justspeaktoit/issues/802) — Epic: protect the core dictation journey with fast macOS E2E regression tests | NARROW | High value: reliable dictation is the product promise, and shipped orchestration can regress despite passing provider/inserter unit tests. Continue from the substantial merged harness; do not rebuild it or claim the eight P0 journeys already pass. Prioritise a small missing production orchestration slice over expanding combinatorial test counts. |
| [#814](https://github.com/crmitchelmore/justspeaktoit/issues/814) — feat(analytics): wire detailed transcription, post-processing and settings telemetry | DEFER | Latency distributions and terminal outcome counts could expose slow providers, lost final text and failed insertion, directly supporting fast, reliable dictation. Broad settings surveillance is less clearly tied to a product decision. Do not implement expanded collection now: the issue explicitly requires #776 production go/no-go evidence plus a clean week of phase-one payload inspection, and no supplied evidence clears that gate. This is a sequencing decision, not a rejection of useful reliability measurement. |
| [#821](https://github.com/crmitchelmore/justspeaktoit/issues/821) — Product proposal: dynamic OpenRouter transcription and TTS model catalogue | NARROW | The one-key catalogue, selection and model-test journey is already delivered. The valuable remaining engineering slice is reducing time to first audible speech with progressive playback while retaining reliable cancellation and privacy. Rebuilding discovery or adding MAI-Transcribe-2 again provides no value. Broad provider-specific knobs are not justified without documented capability metadata and a concrete user need. |
| [#919](https://github.com/crmitchelmore/justspeaktoit/issues/919) — feat: integrate Blue Machines AI Aurora STT when API access is available | NARROW | Proceed with bounded provider qualification under the explicit 9 September missing-provider request. A usable Aurora integration could expand multilingual dictation choice, but the supplied discovery evidence does not establish a usable API, free account access, language quality or latency. Shipping an unqualified picker option would weaken the app’s reliable dictation and transparent BYOK experience. |
| [#929](https://github.com/crmitchelmore/justspeaktoit/issues/929) — research(mac): qualify Indic-Speak runtime before local TTS integration | DEFER | Local Hindi and English speech generation supports privacy and the explicit missing-provider request. The worthwhile outcome is a qualified, usable local runtime; another picker entry or speculative bridge provides no user value. Retain the narrow qualification spike but defer execution until authorised model acquisition and Apple Silicon runtime access are available. The supplied evidence contains no result that clears either gate. |
| [#934](https://github.com/crmitchelmore/justspeaktoit/issues/934) — iOS: the clipboard holds a placeholder after stop, and a late polish overwrites what the user copied since | NARROW | The raw-once contract directly protects instant usable dictation and prevents destruction of later user copies. Current main already implements the approved fix; repeating implementation adds no user value. Narrow the remaining issue to its explicit physical-iPhone delivery qualification gate. |
| [#935](https://github.com/crmitchelmore/justspeaktoit/issues/935) — iOS: a Bluetooth route or engine configuration change silently kills capture | NARROW | Reliable capture and preservation of the last words are core product requirements. The controlled-stop implementation already landed in main via #1032 and integration commit f8af0b1. Reimplementing it has no demonstrated value; the remaining valuable scope is physical-device qualification of the implemented behaviour, with fixes only for reproduced failures. |
| [#946](https://github.com/crmitchelmore/justspeaktoit/issues/946) — iOS: the Siri stop phrase arrives as an interruption, ignoring the destination and raising a stale error | DEFER | Reliable delivery and truthful Stop feedback matter to core hands-free dictation. Destination preservation and stale-alert suppression are now implemented under #936. The remaining Siri acknowledgement race warrants physical-device qualification before adding code; no observed ordering evidence or residual reproduction accompanies this issue. |
| [#947](https://github.com/crmitchelmore/justspeaktoit/issues/947) — iOS: verify suspected Modulate opening-audio loss before adding preroll | NARROW | Protecting opening words directly supports instant, reliable dictation, but current evidence does not prove startup loss. Proceed only with bounded synthetic transport qualification; keep all production buffering changes deferred until actual startup loss is reproduced. This avoids adding latency, memory and lifecycle complexity on the basis of a misleading no-start test. |
| [#954](https://github.com/crmitchelmore/justspeaktoit/issues/954) — iOS: explain native Control setup and add accurate Action Button hints | NARROW | Native trigger discovery directly reduces setup effort for fast dictation and matches native system controls. The requested implementation is now present on main; repeating it has no value. Retain only the explicit device and accessibility acceptance gate before declaring the issue complete. |
| [#956](https://github.com/crmitchelmore/justspeaktoit/issues/956) — iOS: defer Vocal Shortcuts setup guidance pending device verification | DEFER | A verified voice-trigger setup could improve hands-free accessibility and discovery with little UI cost. Publishing unverified instructions would undermine reliable capture and clear recovery, which outrank speculative trigger breadth. The explicit physical-device re-entry gate remains unsatisfied; no comments supply new device evidence. |
| [#958](https://github.com/crmitchelmore/justspeaktoit/issues/958) — iOS: defer automation recipes pending a verified device walkthrough | DEFER | A demonstrated deliberate trigger-to-History recipe could reduce repeated setup friction and support fast native capture. The explicit physical-device walkthrough gate remains unsatisfied in the supplied evidence. Adding another gallery or parameters would duplicate current main and would not prove reliable capture, stop or delivery. |
| [#959](https://github.com/crmitchelmore/justspeaktoit/issues/959) — iOS: defer AirPods-triggered priming and background hands-free arming | DEFER | Hands-free convenience fits instant dictation, but accessory connection does not establish recording intent. The supplied issue correctly distinguishes microphone-free preparation from background VAD. Current Start already has the LiveActivityIntent correction, so the residual Bluetooth-specific benefit needs measurement before adding actions, lifecycle ownership or listening behaviour. Preserve foreground explicit arming and truthful readiness. |
| [#960](https://github.com/crmitchelmore/justspeaktoit/issues/960) — iOS: defer calendar-scheduled Live Activity pending need and device evidence | DEFER | A meeting-timed recording card could reduce effort for a specific recurring meeting workflow, but no such unmet need or observed timing benefit is supplied. Existing explicit start paths now contain the earlier Live Activity fixes. Calendar reading, scheduling, cancellation and Lock Screen disclosure add scope and privacy cost without evidence they improve the core instant, reliable dictation outcome. Reassess against the fixed existing start journey before funding a feature. |
| [#961](https://github.com/crmitchelmore/justspeaktoit/issues/961) — iOS: defer repeated foreground auto-start pending ownership and activation policy | DEFER | Warm-return auto-start can save a tap, but repeated implicit microphone activation lacks a defined user-intent boundary. Reliable capture and clear privacy controls have greater value than extending automation while explicit command ordering and hands-free re-arm policy remain material. Existing startup guards now address part of the original safety concern; they do not establish consent or ordering for each foreground return. |
| [#962](https://github.com/crmitchelmore/justspeaktoit/issues/962) — iOS/watchOS: defer a separate wrist Control pending paired-device relay evidence | DEFER | Starting reliable phone dictation from the wrist fits instant native capture, but a second control adds discovery and maintenance cost without evidence the existing control cannot serve that purpose. The current issue explicitly requires a paired-device experiment before implementation. Preserve this product gate; existing native Watch recording is a different capability. |
| [#963](https://github.com/crmitchelmore/justspeaktoit/issues/963) — Pinch to stop: a Double Tap primary action on the Live Activity in the watch Smart Stack | IMPLEMENT | A visible wrist Stop control reduces the need to retrieve a phone during an existing dictation. It directly serves fast, reliable native capture and can reuse the established Stop intent. The refined Stop-only scope is worthwhile without shipping or enabling the separate native Watch recorder. |
| [#964](https://github.com/crmitchelmore/justspeaktoit/issues/964) — Watch-native triggers: App Shortcut (Siri), watchOS 26 Control, Ultra Action button, Double Tap stop | DEFER | A native Watch trigger can reduce capture friction, but adding several entry points before proving reliable Watch recording and delivery would expand unverified failure paths. Existing in-app Double Tap and complication intents already supply much of the requested value. The current explicit baseline hardware gates remain unmet in supplied evidence; this is a sequencing/value decision, not a Linux-only deferral. |
| [#965](https://github.com/crmitchelmore/justspeaktoit/issues/965) — watchOS: defer startup reorder and recording cues pending hardware evidence | DEFER | Preserving opening words and making recording readiness clear fit the core product goals. However, no measured Watch startup or cue failure demonstrates value for a lifecycle change. Current serialisation and recovery protect retained audio; speculative reordering risks that stronger user outcome. The explicit hardware re-entry gate remains appropriate. |
| [#966](https://github.com/crmitchelmore/justspeaktoit/issues/966) — iOS: defer background Watch uploads pending post-retry device evidence | DEFER | Completing Watch captures without reopening the phone would support reliable, low-friction dictation. However the premature terminal-failure defect is now repaired in current code; no post-repair device evidence establishes a remaining completion failure worth adding relaunch-safe provider/session orchestration. Preserve this explicit evidence gate, rather than implementing speculative background scheduling. |
| [#967](https://github.com/crmitchelmore/justspeaktoit/issues/967) — watchOS: defer chunked capture transfer pending paired-device evidence | DEFER | Earlier usable text from long Watch notes could improve speed, but the issue supplies no paired-device baseline showing a file-size bottleneck or user need. Current durable handoff already addresses loss and duplicate delivery. Segmenting now would add substantial recovery and transcript-boundary complexity to the core reliable-dictation path without demonstrated benefit. |
| [#968](https://github.com/crmitchelmore/justspeaktoit/issues/968) — iOS/watchOS: defer Watch completion notifications pending paired-device evidence | DEFER | Reliable Watch capture and explicit access to saved text fit the core speed, privacy and native simplicity goals. A new notification has unproven incremental value until the existing paired-device History and keyboard retrieval journey is measured. Current code already saves durably and exposes Copy; avoid adding permission prompts, alert noise and another delivery surface without a demonstrated retrieval problem. |
| [#969](https://github.com/crmitchelmore/justspeaktoit/issues/969) — watchOS: defer native widget Double Tap and learned relevance pending evidence | DEFER | A visible Smart Stack recording gesture could reduce interaction for reliable native dictation. However, the explicit recorder hardware baseline remains unproven; adding a trigger now would expand the surface before capture and delivery are demonstrated. Learned relevance has no demonstrated navigation problem or validated habit evidence and conflicts with the preserved neutral-idle decision. The current review supplies no new evidence to lift either gate. |
| [#970](https://github.com/crmitchelmore/justspeaktoit/issues/970) — watchOS: defer direct Watch uploads pending phone-absent device evidence | DEFER | Direct upload can reduce time to a usable transcript when the phone is absent, but no recurring need or measured destination benefit is established. The current durable relay already protects recordings while the phone is unavailable. A second paid upload path adds credential, reconciliation and battery complexity against the product priorities of reliable capture, privacy and transparent costs. Latest cached comments contain no new evidence to change the explicit deferred decision. |
| [#971](https://github.com/crmitchelmore/justspeaktoit/issues/971) — watchOS: defer TestFlight rollout pending device baseline and tester need | DEFER | Wider Watch testing can establish reliable hands-free capture, but distribution work has no demonstrated tester need or recorded paired-device baseline in the supplied evidence. Existing development signing supports baseline collection. Respect the explicit re-entry gates; a beta toggle or new workflow adds state and maintenance before a user benefit is established. |
| [#973](https://github.com/crmitchelmore/justspeaktoit/issues/973) — iOS: defer mixable-first background activation pending device evidence | DEFER | Instant dictation matters, but this policy change has no measured startup benefit or reproduced failure. Current isolated activation already fails fast; choosing mixing early can change other-audio playback. Preserve reliable capture until physical-device evidence demonstrates worthwhile scope. |
| [#974](https://github.com/crmitchelmore/justspeaktoit/issues/974) — One audio-session configuration shared by readiness, detector and transcribers; caller-owned deactivation | DEFER | Reliable first-word capture and repeat keyboard dictation matter, but uniform audio options are not themselves a user benefit. Main now has owned session lifecycle and startup observations; the supplied issue and empty comments contain no new physical-device trace showing that configuration churn causes failure or material latency. Changing mixing, Bluetooth output or deactivation ownership without that evidence risks reliable capture and other audio. |
| [#975](https://github.com/crmitchelmore/justspeaktoit/issues/975) — iOS: defer credential startup optimisation pending residual-wait evidence | DEFER | Fast dictation is a core product goal, but the current loader already coalesces bootstrap and recording work. No measured residual wait demonstrates that changing scheduling would improve speech capture. Preserve provider correctness, secure loading and cancellation until physical-device evidence identifies a material cost. |
| [#976](https://github.com/crmitchelmore/justspeaktoit/issues/976) — iOS: defer capture before SpeechAnalyzer setup pending residual-gap evidence | DEFER | Preserving opening words directly serves instant, reliable native dictation. Current main now removes model installation from analyzer startup, but supplied evidence does not measure the remaining installed-model setup interval or attribute lost opening speech to it. Introducing capture while analyzer setup is pending adds lifecycle and buffering risk without a demonstrated benefit. Retain the explicit residual-gap gate. |
| [#977](https://github.com/crmitchelmore/justspeaktoit/issues/977) — iOS: defer warm SpeechAnalyzer sessions pending latency and resource evidence | DEFER | Fast, reliable on-device starts are a core product goal, but retaining analyzers adds idle resource and lifecycle costs without a measured residual latency benefit. Current installed-only startup and foreground preparation must be measured first; no new evidence in the issue comments overturns the explicit gate. |
| [#978](https://github.com/crmitchelmore/justspeaktoit/issues/978) — iOS: defer keyboard readiness pre-roll pending opening-audio evidence | DEFER | Preserving opening words is central to reliable instant dictation, but readiness pre-roll has no demonstrated recoverable loss interval. It changes an explicit idle-audio privacy promise while leaving the stopped-engine setup gap uncovered. Evidence-first qualification has value; production buffering does not yet justify its complexity. |
| [#979](https://github.com/crmitchelmore/justspeaktoit/issues/979) — iOS: defer shared capture engine pending residual device evidence | DEFER | Fast, reliable dictation makes a proven ownership-related delay worth fixing, but multiple AVAudioEngine owners alone do not establish user harm or a benefit from a shared engine. Current code already preserves the activated audio session during keyboard handoff and has explicit capture ownership, disruption handling and safe buffer processing. A process-wide engine would add format, lifecycle and privacy risk without measured residual benefit. |
| [#980](https://github.com/crmitchelmore/justspeaktoit/issues/980) — iOS: defer Bluetooth microphone defaults pending device evidence | DEFER | Reliable capture of opening words is a core product outcome, but changing microphone defaults without measured app-specific failure and user intent can break headset/pocket dictation. Current evidence supports qualification on a physical device, not a new routing policy. |
| [#981](https://github.com/crmitchelmore/justspeaktoit/issues/981) — iOS: defer cloud socket overlap and endpoint warming pending device evidence | DEFER | Faster first text directly supports instant dictation, but current evidence establishes serial setup only, not meaningful residual delay or benefit from extra probes. Preserve reliable first words, owned cancellation and transparent provider costs until separate measurements justify each candidate. |
| [#982](https://github.com/crmitchelmore/justspeaktoit/issues/982) — iOS: defer tap and I/O buffer tuning pending device evidence | DEFER | Faster first useful text directly supports instant dictation, but changing tap sizes, I/O preferences or pool capacity has no demonstrated user benefit. Preserve audio reliability until physical-device evidence identifies a residual bottleneck. Current code has gained first-input and loss reporting, which improves the evidence path without itself proving tuning is useful. |
| [#984](https://github.com/crmitchelmore/justspeaktoit/issues/984) — iOS: defer hands-free pre-roll handover changes pending audio-coverage evidence | DEFER | Preserving opening words is central to reliable, effortless dictation. Current code still leaves detector setup audio outside the supplied snapshot, but this does not identify an observed missing-speech interval or establish that a later snapshot fixes it. Honour the explicit audio-coverage qualification gate; do not dispatch a speculative handover timing change. |
| [#985](https://github.com/crmitchelmore/justspeaktoit/issues/985) — iOS: defer cold-launch pruning pending attributed device evidence | DEFER | Fast first-word capture is a primary product goal, but current evidence does not identify a removable launch cost. Deferring required background or credential readiness could lose Watch transcripts or change the selected provider. Preserve the device-attribution gate; no scheduling change is justified now. |
| [#986](https://github.com/crmitchelmore/justspeaktoit/issues/986) — A warm window after every dictation: prepared engine, preheated analyzer and cached keys | DEFER | Faster repeated dictation supports the primary speed goal, but the proposed universal warm window combines materially different resource and privacy states without measured incremental benefit. Current Instant Dictation already retains a readiness engine and bounds/heals its lifetime. Existing explicit issue guidance requires repeated-start latency and idle resource measurements after lifecycle fixes before expanding retention. Preserve that evidence gate; this is not a Linux-only deferral. |
| [#987](https://github.com/crmitchelmore/justspeaktoit/issues/987) — Headless triggers reuse the keyboard readiness warm state | DEFER | Preserving the first words of Action Button dictation is high product value, but this is an integration dependent on a capture-ownership mechanism that does not exist on current main. The keyboard itself tears down its readiness engine before provider capture; there is no proven warm capture handle for headless starts to reuse. Implementing a heartbeat shortcut now risks lost input and conflicts with the explicit issue comment's ownership/device gate. |
| [#988](https://github.com/crmitchelmore/justspeaktoit/issues/988) — Dual-path first partial: on-device volatile text while the cloud socket connects | DEFER | Earlier visible text could reassure cloud dictation users, but the promised sub-0.5-second result is an estimate with no measured route-specific benefit. Running two recognisers introduces lifecycle, battery and transcript-authority complexity into the core reliability path. The latest issue comment explicitly retains evidence gates; current code also makes directly reusing partialText unsafe for display-only preview. |
| [#989](https://github.com/crmitchelmore/justspeaktoit/issues/989) — Leading-silence guard: detect dead Bluetooth input and auto-fall-back to the built-in mic | DEFER | Preventing lost first words is central to reliable, instant dictation. However silence cannot establish microphone failure, and automatically moving capture from a selected headset to the phone can reduce quality and violate user expectations. The latest issue comment explicitly preserves the selected microphone pending device evidence and a fallback policy. Current evidence does not justify automatic rerouting. |
| [#994](https://github.com/crmitchelmore/justspeaktoit/issues/994) — Clipboard hygiene: expiring, local-only transcripts with an explicit Universal Clipboard opt-in | IMPLEMENT | A concrete privacy improvement aligned with the privacy-first product: existing transcript writes set only the pasteboard string, so users have no explicit control over transcript clipboard retention or cross-device eligibility. A single policy can cover automatic delivery and deliberate copies without affecting transcription latency or the established raw-only delivery contract. |
| [#996](https://github.com/crmitchelmore/justspeaktoit/issues/996) — Unified error taxonomy and one CaptureCommandRouter for every entry point | NARROW | Proceed with safe typed start-failure mapping and actionable recovery guidance. The current intent catch-all still wrongly directs users to permission settings for unrelated failures, harming reliable instant dictation. A universal recorder/router rewrite adds regression risk without equivalent user value now that ownership and quick-action routing fixes have landed. |
| [#998](https://github.com/crmitchelmore/justspeaktoit/issues/998) — Regression harness: simulator XCUITests on the transcript hook, seam tests for lifecycle, a device matrix job | ALREADY COVERED | Reliable first-word capture and retained final text are core product outcomes, so the harness was worthwhile. Main now contains the simulator capture journeys, shared preroll contract table, simulator-labelled CI, manual Action Button matrix and disabled-by-default device job. A second umbrella implementation would duplicate delivered work. This does not mean every original speculative assertion is proven or every hardware scenario passes. |
| [#999](https://github.com/crmitchelmore/justspeaktoit/issues/999) — Offline-first routing: record with no signal on-device, re-transcribe with the cloud model when online | NARROW | Proceed with capability-checked offline start routing: avoiding a known-offline cloud connection directly supports instant and reliable dictation. Separate and defer automatic later cloud upload: it changes privacy, billing and ownership of an already usable transcript, while manual saved-audio recovery already exists. |

## #1009: Spoken routing: end with to Notes, to Mac, as a reminder, just copy and it goes there

Reviewer: `/root/issue_review_queue/review_1009`.

**Smallest worthwhile scope:** Opt-in setting, default off; first release supports a small documented English command vocabulary with a required distinctive trailing trigger, mapping only to clipboard and historyOnly (optionally existing auto once precedence tests cover it). Unknown or unsupported commands remain literal text.; Pure SpeakCore parser returns original text, derived content and recognised command metadata without executing effects. Match only final complete clauses, honour an explicit literal escape and reject empty-content/ambiguous cases. Do not add an LLM or user-editable phrase editor in this issue.; Planner must define and test precedence: explicit Stop override, explicit Start override, recognised spoken command, then global default. When a command is suppressed by an explicit override, preserve its words unless a clear reviewed contract says otherwise.; Resolve before completeRun, keyboard publication and external writes. Save original text for recovery and use derived content consistently for result, shared completion and permitted delivery. A history-only spoken command must prevent automatic keyboard insertion; just-copy must skip legacy auto-polish.; Use existing native settings and truthful completion feedback. Provide an accessible way to recover/copy the original; do not promise Undo of already inserted external text or advertise unavailable routes.

- `Sources/SpeakiOS/Views/SettingsView.swift:18-75`: Executable choices are auto, clipboard, clipboardAndPostProcess and historyOnly. There is explicitly no Mac destination, and no Notes or Reminders executor in this enum.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift:743-766`: Existing contract is explicit Stop parameter over remembered Start override over global setting. Spoken commands must preserve explicit intent choices and carry origin metadata rather than guessing from a resolved enum.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift:970-1085`: History and returned result are set, then keyboard offers can be inserted BEFORE applyDestinationSideEffects. The issue proposed insertion point is too late: routing must be resolved before keyboard publication, and raw/derived text ownership must be explicit.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift:1591-1678`: Destination application owns clipboard/shared completion; historyOnly suppresses clipboard and polish. Existing legacy clipboard path can auto-polish, so a spoken just-copy command must also suppress legacy polish.
- `Sources/SpeakCore/AutomationIntentSupport.swift`: Pure shared policy functions provide the appropriate architecture and test boundary; the inspected helper has no spoken routing parser.
- `comments/1009.json`: Latest comment explicitly requests opt-in deterministic supported-only scope, false-positive tests, preserved original text, parameter precedence and locale/escape behaviour; it defers LLM routing.

**Dependencies**

- #1013 parameter precedence already exists and must be extended without regressing explicit intent choices.
- #1008 auto routing and #1002/#1003 keyboard publication require coordinated integration before any keyboard insertion.
- #1024 supersedes Send to Mac: do not restore.
- #1010 agent routing is separate and excluded.
- Existing receipt/history recovery contracts must support the distinction between original transcript and delivered content.

**Verification**

- Pure tests for disabled mode, ordinary sentences ending in to Notes/to Mac/just copy, quoted examples, trigger escape, punctuation/case/whitespace, unsupported locale/destination, empty body, and ambiguous or duplicate commands.
- Integration tests prove explicit parameter precedence; original transcript recovery; no keyboard insertion for history-only; exactly one permitted clipboard write; no post-processing for just-copy; and consistent returned/shared/delivered text.
- Apple Swift/Xcode CI for native build and affected suites; real iPhone checks for background/locked capture and keyboard receipt behaviour before claiming those journeys verified.

**Risks and limits**

- Natural-language suffixes are also legitimate content. Default-on bare-phrase stripping would violate reliable dictation and is rejected.
- The existing stop pipeline has effects before the issue suggested hook. A parser-only implementation wired at applyDestinationSideEffects would leak text to the keyboard and give inconsistent history/results.
- History/iCloud retention remains subject to existing settings; do not add new transcript telemetry or claim historyOnly means on-device-only.
- No Watch, locked-device, microphone or keyboard-delivery evidence was collected; Linux cannot validate Apple frameworks.
- Beads CLI absent per supplied context; this scratch JSON is review evidence only.

## #1010: Agent conversation mode: Action Button talks to your AI agent, reply arrives on the lock screen

Reviewer: `/root/issue_review_queue/review_1010`.

**Smallest worthwhile scope:** A distinct planning agent should define and, where possible, implement bounded test seams for a single configured conversation: capture result ownership, cancellation, expiry and late reply identity. Produce a repeatable internal device qualification scenario and record actual results when a gateway/device is available. Keep production feature flags and selectable destinations unchanged. Reassess the full feature only after that gate passes.

- `Sources/SpeakiOS/Services/OpenClawChatCoordinator.swift`: Already sends through ensureConversationReady and client.sendMessage with the conversation sessionKey; reuse this path and final capture rather than creating a second recorder.
- `Sources/SpeakiOS/Services/OpenClawChatCoordinator+HandsFree.swift`: Existing configurable record/send/speak/resume loop and run-id filtering cover foreground conversation machinery. Assistant persistence uses currentConversation, so qualification must verify ownership across conversation switches and delayed replies.
- `Sources/SpeakiOS/Services/OpenClawActivityManager.swift`: Activity state contains status, title, messageCount and duration, with locally updated activity and pushType nil; it does not establish background reply receipt or opt-in reply preview.
- `SpeakiOSApp/FeatureFlags.swift`: OpenClaw is hidden by default behind SHOW_OPENCLAW_TAB for internal testing.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Current hardware destinations are auto, clipboard, clipboardAndPostProcess and historyOnly; none sends to an agent.
- `comments/1010.json`: Latest review explicitly requires background failure, cancellation, reply ownership and expiry qualification before exposing an agent destination; transcript sending and lock-screen previews must be separately opt-in.

**Dependencies**

- Configured OpenClaw gateway and internal SHOW_OPENCLAW_TAB build for a real end-to-end qualification run.
- Existing capture result ownership and OpenClaw coordinator; do not duplicate foreground hands-free conversation mode.
- Explicit user consent for transcript destination, plus separate lock-screen reply-preview consent.

**Verification**

- Model-level tests prove expired or cancelled sessions cannot send later captures, and delayed replies cannot attach to another conversation.
- A configured iPhone internal build demonstrates locked/background send and reply completion, interruption, denied notifications and app suspension/termination recovery; record failures as well as successes.
- Verify original transcript remains recoverable in History and no automatic retry creates duplicate agent actions.
- Verify explicit destination selection and separate preview consent; switching/expiry must revert subsequent capture to normal dictation.

**Risks and limits**

- Existing code evidence is not proof of background execution, microphone access or lock-screen delivery; no native/device checks performed in this review.
- Do not rely on the issue's unverified 30-second or iOS 27 assumptions without Apple documentation and device evidence during planning.
- Agent messages can cause external actions; never infer agent sending from ordinary dictation or a spoken destination phrase without deliberate opt-in.
- Beads CLI is absent per supplied context; this JSON is interim review evidence, not a replacement tracker.

## #1014: Focus filters choose destination, profile and model (SetFocusFilterIntent)

Reviewer: `/root/issue_review_queue/review_1014`.

**Smallest worthwhile scope:** Add one opt-in native Focus filter using only currently executable destinations plus existing model/language vocabulary; omit new general profile creation and polishing configuration.; Store/reset a validated App Group Focus override, merge field by field with explicit intent > Focus > global, and freeze the effective values for the whole recording.; Show the effective destination and Focus influence in existing capture status using native controls and accessible copy. Keep keyboard profile ownership unchanged.

- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Existing destination/model/language intent inputs validate against executable iOS capabilities before microphone acquisition; reuse this validation.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Run parameters are adopted at start; explicit model chooses batch/live mode and keyboard profiles deliberately retain ownership. Focus must fill unspecified fields once at start without overwriting explicit values or keyboard profiles.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Stops use explicit destination, then remembered per-run destination, then global. Persist the resolved Focus destination in the run so Focus deactivation cannot redirect an active recording.
- `comments/1014.json`: Latest issue comment explicitly narrows destinations, excludes Send to Mac, and requires start-time snapshot, visible effective destination, and no-clipboard regression.

**Dependencies**

- Reuse #1013/#1076 per-run parameter resolution; this seam already exists.
- #1024/#952 explicitly removed Send to Mac; do not restore it.
- #1007/#1080 history sync is separate.
- Coordinate any concurrent changes to capture parameter resolution and recording service.

**Verification**

- Unit-test field-level precedence, unset values, invalid/deleted model IDs, and mode selection through the existing validator.
- Test Focus activation/deactivation/change during recording: active route stays frozen; the next capture uses the new effective configuration.
- Assert history-only completion never writes clipboard through automatic, explicit, interruption and Live Activity stop paths unless an explicit stop destination intentionally overrides it.
- Run Apple native CI for App Intents availability and build; verify actual Focus settings registration, reset/deactivation delivery, cold launch and effective-state copy on a real iOS device.

**Risks and limits**

- Hidden context-driven routing can surprise users; visible effective destination and reliable reset are required.
- Model overrides can change provider/privacy/cost; use existing capability/credential failures and never silently substitute a named model.
- No Apple framework build or device Focus behaviour was verified in this Linux review.
- Beads CLI is absent; this decision file is analysis evidence only.

## #1016: Return a TranscriptEntity with a Siri result snippet, and index dictations for Siri

Reviewer: `/root/issue_review_queue/review_1016`.

**Smallest worthwhile scope:** Add an iOS AppEntity projection over existing local History, using existing history UUID and raw/polished text, creation date and duration only where the model supplies them truthfully.; Add a new requiresAuthentication Get Last Transcript entity action and identifier query; leave every existing String action and saved Shortcut contract unchanged.; Keep transcript content out of automatic indexing/donation and avoid cross-device promises. Defer Stop/Dictate entity variants and interactive snippets until capture-specific completion identity and entity-bound copying can be implemented without global-last races.; Exclude Send to Mac and donated Append to Note workflow from this implementation.

- `Sources/SpeakiOS/Activity/AutomationIntents.swift`: Both still return String. Stop already supports bounded Wait For Polish, run-specific waiting and keyboard-session ownership; Get Last already loads history and selects nonempty polished/raw output under requiresAuthentication.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Existing copy action reads mutable SharedTranscriptionState.currentTranscriptText rather than an identified history entry; it must not be reused for an old entity snippet. Stop dialog already consumes capture receipts.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Stop owns verified delivery outcomes and uses historyItem.id for handoff. A second receipt or inferred delivery-success model would duplicate current ownership.
- `README.md; .copilot/skills/justspeaktoit-design.md`: Native quality and privacy support a small authenticated Shortcuts entity; blanket transcript indexing is a separate privacy decision.

**Dependencies**

- Preserve #1015 Wait For Polish behaviour and #1002 keyboard ownership.
- Reuse #1008 receipt ownership if adding a snippet later; never infer copy/delivery success from an entity.
- #1025 removed Send to Mac; honour explicit removal permanently unless Chris changes direction.
- Do not depend on #1119 CloudKit container migration or unverified iOS-27 SyncableEntity claims.

**Verification**

- Unit-test projection/selection for raw-only, polished, empty history and deleted identifier results; never resolve missing IDs to the newest transcript.
- Apple CI must compile AppIntents metadata and verify new entity properties/query availability against the existing deployment target.
- Device/Shortcuts checks must confirm authentication, property branching and unchanged saved String shortcuts; Linux inspection cannot demonstrate Siri rendering or lock-screen privacy.

**Risks and limits**

- Query/display representations must not bypass authentication or unintentionally expose full private text through suggestions.
- Source-device and duration metadata must not be fabricated for old entries.
- A future snippet Copy button needs an entity/run-specific payload: the current CopyFullTranscriptIntent can copy a newer transcript.
- Beads CLI is absent per supplied session context; this JSON is review evidence only.

## #1017: An automation-friendly "Transcript ready" notification for the iOS 27 notification trigger

Reviewer: `/root/issue_review_queue/review_1017`.

**Smallest worthwhile scope:** Add one disabled-by-default completion-notification setting using native controls; request notification permission only when the user enables it.; Use a stable title and History ID, generic hidden-content body by default, and Open History action; omit full-text previews, clipboard actions and automation templates in the initial scope.; Emit at most once per eligible nonempty saved background completion or successful Watch import; suppress redundant foreground/active result surfaces according to an explicit policy.; Define initial readiness as saved transcription ready, with subsequent polishing visible through History; preserve all current delivery outcomes regardless of notification permission or enqueue failure.

- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift:975-1080`: stopRecording already creates a History item, offers keyboard delivery, applies the destination, builds an evidence-based receipt, and stamps a capture-scoped completion identifier. Reuse the History identity for notification navigation; do not introduce another global latest-transcript payload.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift:1107-1145`: Existing completeRecordingActivity already exposes a result preview and receipt; optional post-processing starts afterwards. A new alert needs explicit surface deduplication and a defined raw-versus-polished readiness contract.
- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift:255-286`: importOne persists History durably before acknowledging the capture, then offers keyboard delivery and optionally reprocesses the History item. Notification should occur only after a successful nonempty saved result, and must not claim it enables background import execution.
- `Sources/SpeakiOS`: Targeted search found no existing UNUserNotificationCenter or transcript-ready notification implementation.
- `comments/1017.json`: Latest review explicitly requires real target-OS automation qualification, stable History identity, preview opt-in, deduplication with #1001/#1007, and denied-permission/locked/repeated/failure checks.

**Dependencies**

- Coordinate result-surface policy with #1001/#1007 and preserve current keyboard/History delivery.
- Reuse existing History identity and navigation; do not restore removed Send to Mac.
- Automation templates and any iOS 27 trigger support claim depend on authoritative SDK documentation plus one real target-OS automation showing available variables.
- Beads CLI is absent per intake; this file is review evidence only.

**Verification**

- Unit-test notification eligibility and identity/deduplication with denied permission, foreground completion, Live Activity already presenting a result, repeated completion/import retries, empty text, failed capture and failed History persistence.
- Verify opt-out never requests permission or emits alerts and payloads contain no transcript text by default.
- Use native CI for compile/tests; on-device checks must cover locked previews, app killed/background, History navigation, Watch retries and concurrent captures.
- Before automation expansion, record target OS/build, actual trigger variables and one working automation; publish no sub-second, guaranteed or unattended-delivery claims without evidence.

**Risks and limits**

- System delivery timing and background execution cannot be guaranteed by enqueueing a notification.
- Phone stopRecording comments explicitly distinguish History recording from durable delivery receipts; planner must establish an appropriate persistence boundary before reporting saved readiness.
- History ID and capture completion ID are distinct today; notification navigation must not retrieve an unrelated latest transcript.
- Raw and polished text may settle at different times; do not emit duplicate ready notifications or silently vary their semantic meaning.
- iOS 27 trigger/payload assertions remain unverified here. Static inspection does not establish device behaviour.

## #1018: iOS 27 LongRunningIntent + ExecutionTargets for 'stop, transcribe, deliver' (beta, verify at GM)

Reviewer: `/root/issue_review_queue/review_1018`.

**Smallest worthwhile scope:** Have a separate planner define a bounded qualification experiment: verify exact API declarations, availability and supported SDK; measure one slow post-stop polish under lock/background; test execution placement and cancellation with the existing AudioRecordingIntent Live Activity. Decide adoption only from measured benefit. No production code implementation is justified by this review alone.

- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Polish now updates History and current-run transcript state, clears per-run completion state and ends its assertion. Raw transcript is immediately available; expiration handling is explicit and idempotent.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Stop uses the shared recording service, handles keyboard ownership separately, and refuses to stop an independently owned foreground recording. It deliberately permits lock-screen use while returning only a word-count dialog.
- `Sources/SpeakiOS/Activity/AutomationIntents.swift`: Returning transcript requires authentication. Optional polish waiting already shares a whole-operation time budget and falls back to raw text.
- `comments/1018.json`: Latest explicit triage requires SDK/device qualification and keeps clipboard ownership under #934/#1031 and finalisation bounds under #993.

**Dependencies**

- #934/#1031 clipboard contract must remain intact
- #993 owns capture/finalisation bounds
- Shipping Apple SDK declarations and an iOS device capable of exercising the claimed API are qualification gates
- Send to Mac was explicitly removed; omit Mac delivery from scope

**Verification**

- Record SDK/OS versions and verified Apple API signatures rather than copying speculative issue declarations
- Compare baseline assertion expiry with proposed runtime on physical device, including slow network and cancellation
- Verify no microphone ownership regression, duplicate Live Activities, first-word delay, or lost final transcript
- Preserve immediate raw text, authenticated transcript return, per-run isolation and supported-OS fallback
- If qualification fails or yields no user benefit, record rejection without adding API scaffolding

**Risks and limits**

- No claim that LongRunningIntent or allowedExecutionTargets is available or has the issue-described semantics; those claims were not independently verified here
- Linux static inspection cannot prove locked-device execution, process placement or Live Activity coexistence
- Adding runtime scope around detached polish may require explicit cancellation/lifetime redesign, not merely two protocol conformances
- Beads CLI is unavailable per supplied context; this JSON is interim review evidence only

## #1021: Agent-awaitable phone dictation: speak await / MCP await_transcript

Reviewer: `/root/issue_review_queue/review_1021`.

**Smallest worthwhile scope:** Add await_transcript to the shared automation protocol and speak await/MCP exposure with a server-enforced maximum of 600 seconds. Define next as a qualifying insertion after an atomically established cursor once initial history load is complete. Define since_id, unknown/deleted cursor, retry/idempotency and waiter ownership rules before implementation. Reuse existing history insertion and transport/deadline mechanisms; support local dictation first. Existing CloudKit insertions may qualify only under explicit freshness/source semantics; do not advertise guaranteed phone/watch delivery or introduce transport changes.

- `Sources/SpeakCore/AutomationProtocol.swift`: Shared wire verbs include start/stop/history but no await verb; existing bounded deadlines and request IDs provide a foundation, not completed await semantics.
- `Sources/SpeakApp/Transport/AppAutomationHandler.swift`: History currently returns a snapshot; handler waits for initial history load and uses the persisted store. A next-entry wait needs explicit cursor/subscription rules.
- `Sources/SpeakApp/HistoryManager.swift`: Insertion updates disk-backed and paged collections, persists WAL, then invokes onItemAppended. Subscription must coexist with this existing callback rather than replace its consumer.
- `Sources/SpeakApp/MacHistorySyncAdapter.swift`: New remote entries already use HistoryManager.append; edits use update. Existing sync can feed insertion events without a new remote transport, but old cloud backfill is not necessarily a fresh dictation.
- `Docs/automation.md`: CLI and MCP already share the running app and credential ownership, supporting a small additional verb rather than a separate service.

**Dependencies**

- #655/#656 established CLI/MCP work: extend and coordinate rather than duplicate.
- #1007/#1080 govern remote arrival; verify current merged scope and preserve phone/watch device gates.
- Latest cached issue comment requires a cursor contract, deterministic cancellation/reconnect/simultaneous waiters, and bundled CLI/MCP acceptance.
- Explicit Send to Mac removal remains authoritative.

**Verification**

- Test that pre-existing history, initial load, edits and cloud backfill cannot accidentally fulfil a new reply request.
- Test atomic subscribe/cursor races, completion at deadline, disconnect/cancellation, app shutdown, waiter cleanup and simultaneous waiters with explicit matching semantics.
- Test repeated request IDs and reconnects without duplicate or cross-request delivery; reject invalid timeout/cursor values deterministically.
- Exercise actual bundled CLI JSON/text and MCP tool flows against the app on macOS, including timeout and error results.
- Native Apple CI must compile/test changes; separately verify actual phone/watch CloudKit arrival on real devices before claiming that workflow works.

**Risks and limits**

- Most important design risk is treating any new history insertion as the intended reply: local concurrent dictation, imported entries and cloud backfill can be unrelated. A cursor alone establishes ordering, not user intent.
- Single existing append callback must not be hijacked; additive observation must have deterministic lifetimes.
- Long waits must not occupy global command serialization or block start/stop/status commands.
- Code inspection does not validate physical dictation or CloudKit push. Beads CLI is absent; this JSON is review evidence only.

## #1024: Send to Mac as a real headless destination on the existing transport (superseded by removal)

Reviewer: `/root/issue_review_queue/review_1024`.

**Smallest worthwhile scope:** No code or detailed implementation plan. Keep this issue as a superseded design record, or close as not planned while preserving its removal decision; parent owns tracker action.

- `Docs/MACOS_RECEIVER.md:3-21`: Documents completed removal of the iOS pairing UI and Settings entry; explicitly retains the Mac server for CLI/MCP automation and the client for wire-protocol loopback tests. CloudKit history is the remaining cross-device lane.
- `Sources/SpeakiOS/Views/SettingsView.swift:18-66`: Supported destinations are auto, clipboard, clipboardAndPostProcess and historyOnly; comments explicitly explain the absence of a Mac branch. No sendToMac destination exists.
- `Sources/SpeakiOS/Views/SettingsView.swift:2877-2925`: iCloud History Sync remains user-visible, with availability, pending-entry and last-sync states. This is history synchronisation, not acknowledged insertion at the Mac cursor.
- `Sources/SpeakiOS/Services/SendToMacService.swift`: Historical issue path is absent from current checkout, consistent with removal.
- `/workspace/scratch/a8be40db3c71/comments/1024.json`: No cached issue comments override the explicit superseding decision.

**Dependencies**

- Preserve Mac-side transport used by CLI #655 and MCP #656; it is unrelated to restoring the removed iOS client.
- CloudKit history work, including #1119 owner/container and device gates, is separate; no container migration is authorised here.

**Verification**

- Read-only check confirms removed iOS client path and absence of a Mac destination in the current enum.
- Do not reinstate iOS pairing or cursor-delivery claims and do not delete retained Mac automation transport.
- Any future revival needs a fresh user decision and device validation for acknowledgements, local-network denial, sleeping Macs and insertion target safety.

**Risks and limits**

- Static source inspection does not prove CloudKit sync or physical Mac/iPhone behaviour.
- CloudKit history availability is not equivalent to guaranteed immediate delivery or automatic cursor insertion.
- Beads CLI is absent per supplied context; this scratch JSON is review evidence, not a substitute tracker.

## #1027: Epic: iOS capture — make one press always work, never lose the first words, land the text where the user was typing

Reviewer: `/root/issue_review_queue/review_1027`.

**Smallest worthwhile scope:** Reconcile the epic checklist against current main and all per-issue review decisions, identifying implemented, accepted residual, device qualification, deferred and rejected children.; Make core release acceptance about successful start, preserved first/final words, truthful status and correct delivery; keep speculative trigger/agent/Watch features outside the must-pass set.; Link existing deterministic tests and device matrix evidence for each core journey. Only create new implementation work for a demonstrated residual gap not already owned by a child.

- `Sources/SpeakiOS/Services/CaptureCommandRunner.swift`: Current main already centralises capture deep links and quick actions, guards active starts and surface ownership, pins destination overrides to capture identity, and preserves per-run parameters and specific start outcomes.
- `Tests/SpeakiOSUITests/CaptureFlowUITests.swift`: The epic claim of zero iOS capture automation is stale: deterministic simulator tests exercise real view/coordinator state, transcript retention and repeated captures. The class explicitly excludes hardware audio and system Live Activity guarantees.
- `.github/ISSUE_TEMPLATE/action_button_device_matrix.md`: An existing device matrix already covers locked cloud capture, first press after 8h, dismissed activities, crash recovery, rapid toggles, destination truthfulness, interruptions, Bluetooth and first-word loss with build/OS identifiers.
- `/workspace/scratch/a8be40db3c71/comments/1027.json`: The cached review explicitly identifies specifications conflicting with landed #1025 and #913 and requires rechecking present code before implementing child issues.

**Dependencies**

- Consume individual child issue decisions; do not duplicate their planning or implementation.
- Keep #934/#935/#954 physical-device qualification distinct from code completion. #998 harness is already covered.
- Retain evidence gates on #946/#974/#986–#989. Prioritise accepted narrow work such as #994 clipboard policy, #996 error consistency and #999 strict offline behaviour through their own child plans.
- Preserve explicit removal of Send to Mac (#1024), Watch shipping/device gates (#657/#659), and owner release decisions.

**Verification**

- Every mandatory core journey has an owning child, current code/test evidence, explicit residual status, and a physical-device row where needed.
- Do not close the epic solely because child PRs merged; required device evidence records actual source/build, OS, route, provider, destination and observed outcomes.
- No duplicate capture framework, no restored Send to Mac, no Watch enablement, and no Stable publication inferred from reconciliation.

**Risks and limits**

- This bounded read-only review inspected three targeted implementation/test/qualification excerpts; it is not an audit or a completed hardware test.
- Native builds require Apple Swift/Xcode; no native builds or physical-device runs performed.
- Beads CLI is absent per supplied context; this analysis JSON is not a replacement tracker. External tracker edits remain with the parent.

## #1051: feat: add direct Azure Speech and MAI batch and live transcription

Reviewer: `/root/issue_review_queue/review_1051`.

**Smallest worthwhile scope:** Retain existing direct Azure implementation. Plan a focused installed-app acceptance pass for both platforms: correct batch/live picker placement, preserved selections and friendly History, credential/endpoint recovery, first and trailing words, cancel/stop and no assistant output. Implement only defects demonstrated by that pass; no new Azure OpenAI deployment route or provider rewrite.

- `comments/1051.json`: Latest cached comment assigns implementation to PR #1063 and explicitly says OpenRouter MAI does not satisfy the issue.
- `Sources/SpeakCore/AzureTranscriptionModels.swift`: Canonical batchOptions define Fast, MAI-2 and MAI-1.5; liveOptions distinguish Azure Speech Voice Live and unversioned MAI Voice Live.
- `Sources/SpeakApp/AzureTranscriptionProvider.swift`: AzureTranscriptionProvider routes recorded audio through shared AzureBatchTranscriptionClient and warns key validity does not establish model access.
- `Sources/SpeakCore/AzureVoiceLiveClient.swift`: Actual WebSocket streaming client preserves preroll, bounds outbound audio and exposes finishAndWait support; assistant generation disabled by contract.
- `Tests/SpeakCoreTests/AzureSpeechIntegrationTests.swift`: Opt-in credentialed synthetic-audio tests cover MAI files and both live models, including trailing words; ordinary CI does not spend credits.
- `Docs/azure-speech.md`: Documents September 10 successful compiled-client Fast/MAI/live fixture checks using existing trial credits, earlier UK South access failure, and explicitly outstanding installed-app microphone/iOS device acceptance.

**Dependencies**

- Existing implementation ownership PR #1063; reconcile its resolved review findings before assigning any new code.
- OpenRouter #821/#916 is related provider coverage but not a substitute.
- An installed Alpha on macOS/iOS and existing eligible Azure resource are needed for remaining acceptance.

**Verification**

- Confirm recorded and streaming selections run the documented provider route on macOS and iOS.
- Exercise authentication/quota or access failure, empty/silent input, cancellation, first-word preservation and finalisation using synthetic audio and existing credits only.
- Treat documented compiled-client success as historical evidence, not fresh device results; record installed version and resource eligibility for actual checks.
- Require focused regression tests and Apple Swift/Xcode CI for any resulting fix; Stable publication remains separately authorised.

**Risks and limits**

- No code edits or new provider calls performed in this read-only value review.
- Installed-app microphone and iOS device acceptance remains unproven by the inspected material; do not close as fully delivered.
- Azure access varies by resource; never infer it from a saved key or enable paid credit/upgrades.
- Beads CLI is reported absent by parent context; this JSON is analysis evidence only.

## #1052: feat: add Azure MAI-Voice speech generation

Reviewer: `/root/issue_review_queue/review_1052`.

**Smallest worthwhile scope:** Audit the existing MAI voice path against the remaining acceptance matrix and retain the documented macOS-only TTS restriction.; Strengthen opt-in response qualification beyond RIFF prefix to nonempty decodable audio and separately record Voice-2/Flash access; a missing Flash resource is a blocker, not inferred support.; Add only concrete missing failure handling/tests for successful-empty audio, authentication/quota, cancellation and selection preservation; use existing SpeakCore descriptors and macOS adapter.; Complete actual installed macOS picker, History name, synthesis and audible playback checks when the eligible resource and Apple environment are available.

- `Sources/SpeakCore/AzureSpeechVoices.swift`: Canonical resource-returned voice identities include MAI-Voice-2/Flash; requests reuse existing credentials, preserve IDs, reject empty text and unsupported MAI prosody, and use origin-bound redirects.
- `Sources/SpeakApp/TextToSpeech/AzureSpeechClient.swift`: Existing macOS TTS adapter synthesises MAI voices, retains neural fallback and displays unknown MAI cost. Key validation explicitly does not infer model access. Successful HTTP responses are saved and duration-loaded without an explicit empty-payload guard.
- `Tests/SpeakCoreTests/AzureSpeechIntegrationTests.swift`: Opt-in test selects an actual resource-returned MAI-Voice-2 voice and checks HTTP 200/RIFF, but does not prove nonempty decoded audio, playback, Flash support or installed picker behaviour.
- `Docs/azure-speech.md`: Documents macOS-only Azure TTS and shared transport, preserved credentials/selections, UK South access failure, and a 10 September East US MAI-Voice-2 WAV success using existing trial credits. Explicitly distinguishes compiled-client checks from installed app/device gates.
- `/workspace/scratch/a8be40db3c71/comments/1052.json`: Latest comment assigns implementation ownership to #1063 alongside #1051, requires real playback and endpoint/region qualification, and forbids duplicate catalogue work.

**Dependencies**

- #1063 owns existing implementation; coordinate residual work with #1051.
- Eligible existing Azure resource/credits and Apple runner/device for actual playback/picker verification.
- No new credits, paid activation, region/tier upgrade or Stable publication authorised.

**Verification**

- Use a tiny synthetic text fixture with existing credentials/credits only; preserve redacted endpoint/region/model, response and playback evidence.
- Verify neural saved selections remain usable; unavailable MAI access produces a clear recovery state and never inherits neural pricing.
- Focused tests must exercise 401/403/429, cancellation, empty text and 200-empty/invalid audio handling, plus friendly-name/selection persistence; check existing coverage before adding tests.
- Affected Apple builds and normal PR checks; installed-app playback remains open until observed. Platform restriction must be documented and enforced in picker behaviour.

**Risks and limits**

- Read-only triage; no tests or live provider probes were run by this reviewer. Historical successful responses are documented evidence, not independently reproduced results.
- Current provider availability/Flash support requires official-contract and resource qualification by the planning/implementation stage.
- Linux cannot establish playback quality or installed macOS/iOS behaviour; this does not prevent focused code/test work.
- Beads CLI absent; this JSON is review evidence, not a replacement tracker.

## #1087: feat: add hosted Bodhan Indic-Transcribe and Indic-Speak after API qualification

Reviewer: `/root/issue_review_queue/review_1087`.

**Smallest worthwhile scope:** After access becomes available, qualify short synthetic English/Hindi STT and TTS requests with redacted metadata and latency evidence. Only successful qualification should start provider/catalogue implementation planning. No placeholder provider or speculative endpoint code now.

- `README.md:Features`: Native SwiftUI transcription prioritises live text, privacy and frictionless output; language coverage is useful only with reliable real service behaviour.
- `Sources/SpeakCore/TranscriptionProviderRegistry.swift:TranscriptionProviderMetadata and TranscriptionProvider`: Shared provider protocol and configurable apiKeyIdentifier support a qualified batch provider and distinct credentials without new generic infrastructure.
- `Sources/SpeakCore/ModelCatalogTypes.swift:ModelCatalog.Option`: Shared model metadata includes latency and pricing; those fields should reflect observed service capabilities rather than guessed performance.
- `AGENTS.md:Shared Evolving Catalogues; .copilot/skills/justspeaktoit-design.md:Messaging Guidelines`: One shared catalogue and truthful speed/privacy/cost messaging are required; this supports a narrow qualified addition, not duplicated platform lists.
- `review-input/1087.md; comments/1087.json`: Issue snapshot records login redirect, no matching key names or verified starter credit; cached comments contain no newer access resolution. Targeted Sources/Docs search found no Bodhan/Indic integration.

**Dependencies**

- Authorised developer access with separate STT and TTS keys and confirmed free credit; no purchase or paid activation.
- #929 is local Indic-Speak qualification with separate runtime/licence gates; do not merge or replace its scope.
- No newer access evidence in cached issue comments.

**Verification**

- Verify actual returned transcript and native playback of WAV output, including documented PCM16 24 kHz mono contract.
- Verify distinct keys, empty input, errors, cancellation and the 30-second STT limit; establish truthful batch/streaming and long-TTS handling.
- Following successful qualification, require shared catalogue/parity tests, preserved defaults and native macOS/iOS runtime validation before a selectable integration.

**Risks and limits**

- Access evidence comes from supplied issue snapshot; no login, key extraction, paid activation or live API call was attempted in this value review.
- Linux cannot establish native audio playback quality; this deferral is due to API access and qualification, not merely build environment.
- Beads CLI is absent per parent context; this JSON is review evidence only.

## #1088: research(mac): qualify AuK and AuK-Flash within a supported local TTS runtime

Reviewer: `/root/issue_review_queue/review_1088`.

**Smallest worthwhile scope:** Produce a bounded AuK/AuK-Flash localTTS qualification record: verify available runtime/resource options against pinned evidence, record a present-host no-go if none qualify, and specify a reproducible synthetic text-only probe for a qualified Apple host. Do not download/load the full model on the undersized host or add a mocked/provider placeholder. No cloning or editing UI.

- `Sources/SpeakApp/TextToSpeech/TTSProtocol.swift`: Providers include system and cloud services; no AuK or downloaded localTTS case is present. A catalogue addition alone cannot make this model executable.
- `Sources/SpeakApp/TextToSpeech/SystemTTSClient.swift`: Existing offline system speech provides a zero-API-cost baseline for meaningful quality and latency comparison.
- `Sources/SpeakApp/SherpaOnnxRuntimeManager.swift`: Existing runtime requires ASR tokens/encoder/decoder/joiner bundles. Its presence does not establish AuK speech-decoder support.
- `review-input/1088.md`: Supplied pinned evidence reports >20.7 GiB float32 combined weights before additional allocations, exceeding the stated 16 GiB Mac. No inference has run; memory figures are estimates, and public model access is not the blocker.

**Dependencies**

- A supported AuK/AuK-Flash text-generation runtime on Apple hardware with sufficient measured headroom, or a verified smaller-memory implementation.
- Retain #1121 usage-evidence and Chris decision gate for sherpa runtime removal versus native linking; this issue neither chooses that architecture nor assumes sherpa supports AuK.
- Licence and acquisition checks must cover exact model, dependencies and revisions, despite the supplied MIT checkpoint status.
- Canonical SpeakCore model metadata is required only after a pass; preserve defaults and existing local/remote distinctions.

**Verification**

- Record exact checkpoint/runtime/dependency versions, licences, acquisition sizes, supported device backend and resource preflight.
- A claimed pass requires real synthetic speech plus native Apple playback, latency, measured peak memory, cancellation cleanup and empty-input behaviour; distinguish estimates from measurements.
- Compare the observed outcome with existing system TTS before recommending integration. If no supported host/runtime exists, retain an explicit blocked/no-go result without declaring completion of inference acceptance.
- Only after go: isolated adapter implementation, canonical metadata, meaningful tests, Apple Swift build and UI validation, PR/review/CI and protected merge.

**Risks and limits**

- No live upstream requalification or real inference performed in this value review; upstream facts are supplied pinned issue evidence.
- No generic Llama adapter can be presumed to support the speech decoder. No purchases or paid-credit activation.
- Apple playback and physical resource behaviour cannot be validated in this Linux review.
- Beads CLI unavailable per task context; this JSON is review evidence only, not a substitute tracker.

## #1089: research: qualify hosted Tontaube speech API and distinguish it from local V1

Reviewer: `/root/issue_review_queue/review_1089`.

**Smallest worthwhile scope:** Keep this as hosted qualification research pending access. Once access exists, collect one reproducible short synthetic speech result and contract evidence before commissioning a provider integration plan. Do not add local V1 to downloaded Mac models.

- `README.md`: Native macOS/iOS app prioritises fast voice workflows and privacy; existing speech capability means another provider needs demonstrated user value.
- `Sources/SpeakApp/TextToSpeech/TTSProtocol.swift`: Existing providers already have explicit routing and credential contracts; Tontaube is absent from this provider enumeration.
- `Sources/SpeakCore/MistralTTSAPI.swift`: Existing shared provider transport handles actual response formats, account voice discovery, cancellation and typed failures; these are relevant future integration seams, not evidence that Tontaube works.
- `AGENTS.md`: Shared metadata must be canonical in SpeakCore; downloaded local execution and remote access must remain clearly distinguished.
- `/workspace/scratch/a8be40db3c71/review-input/1089.md`: Supplied qualification record reports no matching key, hosted language/model uncertainty, Opus-only documented hosted output and unsupported local Mac runtime. No subsequent issue comments override these gates.

**Dependencies**

- Authorised hosted API access using free credits only; no purchase or paid activation.
- Verify hosted model/version, languages, response container and service terms independently of local V1 model metadata/licence.
- Real Apple playback qualification; local runtime support remains a separate gate.

**Verification**

- Authorised free-key speaker discovery and short synthetic speech response with served-model/language evidence.
- Validate actual Opus container/codec and native decoding/playback; measure latency and test cancellation, empty input and errors.
- If qualified, require shared catalogue/transport tests plus Apple Swift/Xcode build and native UI validation before enabling provider selection.

**Risks and limits**

- Hosted documentation and marketing claims may differ; supplied provider facts were not freshly verified in this bounded value review.
- Code inspection does not prove provider access, service quality, licensing suitability or native audio playback.
- Beads CLI is unavailable per parent context; this JSON is review evidence only, not task-tracker replacement.

## #1101: Compare models: run one audio sample through N transcription models, judge blind, keep a scoreboard

Reviewer: `/root/issue_review_queue/review_1101`.

**Smallest worthwhile scope:** No new implementation identified within this bounded review. Validate the merged feature against the five issue acceptance bullets, and file only specific reproduced residual defects. Do not add replay, automatic word error rate or default-model switching.

- `Sources/SpeakApp/CompareModels/CompareModelsController.swift`: Inspected origin/main, not stale working checkout. Controller filters usable models, requires two candidates, fans out one live capture, tracks generation/cancellation and capture ownership, preserves sample hash/duration, and exposes persisted aggregate scores.
- `Sources/SpeakApp/CompareModels/CompareModelsRoundView.swift`: Unlabelled columns remain blind until reveal; word diffs compute off main actor; complete ranking gates submission; revealed columns show latency and estimated cost; batch queue advances and round export is exposed.
- `Sources/SpeakApp/CompareModels/MacComparisonSyncAdapter.swift`: Round updates/deletions trigger sync; activation/account changes and periodic retries resume it; revision application and acknowledgements integrate with the round store.
- `Sources/SpeakCore/ModelComparison/ModelComparisonExport.swift`: JSON and Markdown encode rounds, sample identity, ranks, timestamps, transcripts, latency, cost and aggregate scores without embedding audio.

**Dependencies**

- Merged PR #1102, origin/main 2ff982d. Do not duplicate this implementation.
- Existing History CloudKit container/schema deployment and signed two-Mac validation; preserve #1119 owner/container decision gate.
- Apple Swift/Xcode native test/build environment.

**Verification**

- On a real Mac with two usable models, stream once and import once; confirm raw output, blind diffs, complete ranking, and post-judgement reveal.
- Complete three rounds and inspect persisted mean rank/wins/rounds plus latency/cost; verify batch files advance through consecutive rounds.
- Verify rounds/rankings on a second signed Mac using the same iCloud account and intended History container, including reconnection.
- Inspect JSON and Markdown exports for sample identity, models, ranks, latency, cost and timestamps with no embedded audio.
- Verify normal dictation before and after comparison and while the comparison feature is idle. Run native test suites and build gates on Apple Swift.

**Risks and limits**

- Static source inspection cannot establish microphone, provider network, normal-dictation latency, or two-Mac CloudKit correctness. ALREADY COVERED means the requested implementation is present, not that physical acceptance has been demonstrated.
- Inspection was deliberately bounded to four code excerpts; it is a value triage, not an exhaustive correctness audit.
- No native tests or external provider calls were executed. Unknown prices must remain unknown rather than imply zero cost.
- Beads CLI is absent per supplied context; this JSON is interim review evidence only.

## #1103: Epic: consolidation roadmap — one provider stack, one iOS composition root, one history and sync path

Reviewer: `/root/issue_review_queue/review_1103`.

**Smallest worthwhile scope:** Maintain the parent roadmap and dependency order using the approved child scopes; separate accepted implementation, qualification work, owner decisions and rejected proposals.; Delegate plans and SOL medium implementations to accepted child issues only. Do not create a duplicate cross-cutting mega-plan or umbrella code PR.; Measure success through preserved first words/final transcripts, correct provider routing and credentials, history durability, responsiveness, and simpler ownership. Treat deleted lines as a secondary observation.; Preserve deliberate platform differences, legacy persistence compatibility, diagnostic privacy and current snapshot/linter protection. Keep broad Swift 6 migration and runtime/container changes outside ungated cleanup.

- `Sources/SpeakCore/LiveTranscriptionClientFactory.swift`: Most cloud transports already have shared clients, while OpenAI explicitly returns nil and Azure carries endpoint configuration. This supports staged convergence after parity, not unconditional replacement of platform adapters.
- `Sources/SpeakSync/SyncModels.swift`: A deliberately bounded nine-field sync contract already bridges native records. Sharing local model code is separable from expanding remote data or migrating containers.
- `Sources/SpeakiOS/Views/IOSHistoryPersistence.swift`: Synchronous IO and hashing run on MainActor, but protected writes, primary/recovery readiness and per-item digest checks safeguard history. Responsiveness work must preserve those recovery contracts.
- `AGENTS.md`: Repository rules support canonical shared catalogues with genuine platform projections, deliberately isolated SwiftLint resolution, and distinct Alpha versus owner-approved Stable publication.

**Dependencies**

- All #1104–#1129 child reviews are authoritative for accepted scope; this epic must not override narrower decisions.
- #1104 parity work precedes each relevant controller fold; #1111 shared OpenAI transport precedes OpenAI routing removal; #1113 routing simplification follows actual landed parity.
- #1115 mechanical settings extraction precedes narrow #1116 catalogue work and #1117 recording-service injection.
- #1118 local history compatibility can proceed independently; #1119 container selection remains owner/provisioning/device gated.
- #1121 gathers runtime usage evidence before Chris chooses removal versus native linking.
- #1126/#1127 preserve release gates and need verification in the next real Alpha; #1128 is rejected; #1129 documents current architecture rather than speculative completion.

**Verification**

- Each child has an independent plan, scoped PR and honest check results; dependency completion means merged and verified code, not review approval.
- Native macOS/iOS CI verifies affected targets; provider lifecycle and history compatibility tests exercise outcomes rather than counts or non-nil factory construction.
- Retain physical-device, microphone, Watch, Bluetooth, CloudKit and upgrade checks wherever the child requires them; do not infer them from Linux inspection.
- Epic completion requires all children reconciled to implemented, explicitly deferred, superseded or rejected outcomes; deferred owner work is not silently marked implemented.
- No manual release workflow dispatch and no Stable publication inferred from main changes.

**Risks and limits**

- This bounded review inspected three targeted source excerpts plus repository guidance, the epic, empty cached comments and selected child decisions; it did not repeat the architecture measurement.
- The reported 9.2% duplication and line savings are historical assessment estimates, not verified current product benefit.
- CloudKit migration, runtime replacement and wide concurrency changes have separate compatibility risks and owner gates.
- Linux cannot validate native frameworks or hardware behaviour. Beads CLI is absent per session context; this JSON is temporary analysis evidence, not a replacement tracker.

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

## #485: Investigate local/on-device Voxtral realtime support

Reviewer: `/root/issue_review_queue/review_485`.

**Smallest worthwhile scope:** Audit the recent investigation against primary sources; pin one candidate realtime checkpoint and Swift-compatible runtime, confirm redistribution terms, and create an isolated macOS proof-of-concept/qualification harness only if plausible. Compare identical consented audio with an existing local option and record explicit go/no-go with resource and language tradeoffs. Keep iOS as a separately evidenced feasibility result. No app picker entry or shipping dependency before qualification succeeds.

- `Sources/SpeakApp/LocalModelManager.swift`: The local import path permits sherpa-backed Zipformer/Nemotron/converted Parakeet sources. It does not provide a generic Voxtral realtime adapter; adding a catalogue item would not create a working capability.
- `Sources/SpeakCore/ModelCatalog.swift`: Voxtral realtime is present as an API-key-backed cloud catalogue entry. That is distinct from downloaded local models.
- `Package.swift`: Package manifest includes FluidAudio; no MLX dependency found in targeted manifest inspection.
- `README.md`: Documents a downloaded on-device FluidAudio Parakeet realtime option, so local Voxtral needs demonstrated incremental benefit.
- `comments/485.json`: A prior investigation reports candidate Swift/MLX artefacts but explicitly built no proof of concept. Its runtime, licence, size and device feasibility statements remain historical claims to reverify, not validated current facts.

**Dependencies**

- Separate from cloud #484/#1053/#1061; do not duplicate those providers.
- Retain #1121 runtime linking/removal owner gate; qualification must not pre-empt the native-runtime distribution choice.
- Existing local Parakeet path from #561 supplies a comparison baseline.
- A separate planning agent must verify official model/runtime/licence sources before selecting a concrete checkpoint or dependency.

**Verification**

- Dated primary-source references for exact artefact revisions, licences, downloads, runtime API and platform support.
- Apple Silicon real-audio evidence for cold/warm start, first partial, stop-to-final, first/last word preservation, sustained memory and transcription accuracy against an existing local baseline.
- Show inference works offline after download; record failure, cancellation, unload and recovery behaviour.
- No iOS support claim from a package deployment target; real-device memory, thermal and foreground/background evidence is required before enabling iOS.
- Document integration seam and native build requirements; subsequent production work must include shared catalogue/platform filtering and honest download/readiness states.

**Risks and limits**

- No current model size, licence or runtime-feasibility claims were independently verified in this bounded value triage.
- Do not treat a prior arbitrary weight-size threshold or mandatory ANE execution as a universal feasibility law; use measured device resource budgets and user value.
- Linux static inspection cannot prove microphone performance or native runtime/device stability.
- No purchases, credit activation, paid billing, release dispatch, model download or repository edits performed.
- Beads CLI is absent per supplied context; this JSON is review evidence only.

## #611: Streaming insertion + latency as a first-class metric

Reviewer: `/root/issue_review_queue/review_611`.

**Smallest worthwhile scope:** Plan a reproducible benchmark protocol using existing session latency data: define first-visible-write versus confirmed-visible-text semantics, app/device/OS/provider/model/network conditions, warm versus cold runs and sample counts.; Use #664 for a target matrix covering selection, corrected partials, Unicode, caret/focus changes, readback failures and fallback delivery. Retain the existing two-app allowlist until new target evidence supports inclusion.; Collect a baseline before selecting a concrete capture-start optimisation; publish only measured, clearly scoped results. A narrow measurement/export helper is worthwhile only if the planner confirms existing history data cannot support the protocol.

- Sources/SpeakApp/LiveTextInserter.swift: InsertionStrategy.rangedStreaming, begin, update and streaming state already implement stable-region tracking, selection replacement, deferred AX readiness and firstInsertionAt instrumentation.
- Sources/SpeakApp/StreamingInsertionAllowlist.swift: bundleIdentifiers contains only com.apple.TextEdit and com.apple.Notes. Slack, VS Code and browser contenteditable fields are deliberately excluded because full-field AX readback is unreliable; accepting a write alone is insufficient proof of safe reconciliation.
- Sources/SpeakApp/LatencyInsights.swift: latencyInsightsByProvider consumes firstInsertMs and computes per-provider sample counts/p50/p95; latencyOverview computes capture-start percentiles; providerTable renders First words, First insert and Finish. These already address the historic missing-insertion-metric comment.
- Tests/SpeakAppTests/HistoryItemLatencyTests.swift: explicit tests cover streaming first insert, one-shot fallback, missing intervals and provider separation. Inspected only; no Apple-native execution performed.
- Cached comments/611.json: latest progress identifies PR #780 as metric completion and leaves five-target verification under #664, the capture-start budget and publication open.

**Dependencies**

- Coordinate with #664 as the single owner of per-app streaming qualification and any value-independent region verification; do not create a competing AX implementation.
- Existing PRs #644 and #780 delivered substantial scope and should be credited rather than repeated.
- Real macOS hardware, microphone, target app versions and provider access are needed for performance and AX evidence. No paid-credit activation or release dispatch is authorised by this review.

**Verification**

- Record reproducible per-provider capture-start, first-partial, first-insert and stop-to-final distributions with sample counts and warm/cold conditions; never claim the sub-100 ms budget from static inspection.
- Require real app evidence of no duplication or corruption before accepting each additional target; non-allowlisted apps must retain paste-at-end behaviour.
- Preserve existing percentile and fallback tests; run Apple Swift/Xcode checks for any eventual Swift changes. Benchmark publication requires actual measured samples.

**Risks and limits**

- Five common apps is an aspiration, not evidence that Slack/VS Code/browsers safely support the present AX strategy.
- A successful AX write timestamp is not independently measured screen-paint latency; benchmark labels must explain the checkpoint.
- Provider pre-connect and audio prewarming can alter resource use, privacy expectations and first-word preservation; no speculative implementation justified yet.
- This read-only bounded review does not establish real-device performance, app compatibility or benchmark results.
- Beads CLI is absent; this JSON is interim review evidence, not a replacement tracker.

## #614: Adopt SpeechAnalyzer/DictationTranscriber (iOS 26/macOS Tahoe) + voice-activated hands-free mode

Reviewer: `/root/issue_review_queue/review_614`.

**Smallest worthwhile scope:** Retain an evidence checklist for comparative first-partial latency and hands-free start/stop behaviour. Correct acceptance wording: armed mode must monitor microphone input for VAD, while preventing silent transcript creation or unintended remote transmission. Do not build another analyzer or VAD implementation. Raise fixes only for observed qualification failures.

- `Sources/SpeakCore/AppleLocalModels.swift`: Shared default prefers SpeechTranscriber, then DictationTranscriber, then legacy, with OS/device availability gates.
- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Starts analyzer for analyzer model IDs and falls back to legacy after eligible setup failure; cancellation does not start a fallback capture.
- `Sources/SpeakApp/MainManager+HandsFree.swift`: Default-off, OS-gated hotkey arming already wires pre-roll capture, silence duration, capture ownership, stop, cancellation and HUD state.
- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: iOS creates SpeechDetector with microphone input and pre-roll, then resumes detector after successful capture without clearing committed results on restart failure.
- `Sources/SpeakCore/AppleSpeechDetector.swift`: Shared SpeechDetector analyzer exists, prepares required assets and reports speech activity while silent input is not transcribed.

**Dependencies**

- #658 owns hands-free follow-up; reconcile its current review rather than create duplicate work.
- #780 latency instrumentation cited in cached comments provides a candidate measurement surface.
- Apple OS 26 hardware and Apple Swift/Xcode required for runtime qualification; older supported OS/device needed for fallback checks.

**Verification**

- On supported iOS/macOS hardware, confirm actual active engine and compare repeated identical 30-second passages against legacy Apple Speech; record first-partial and first-insert distributions, with analyzer first-partial p50 no worse than legacy as requested in issue comments.
- Verify hands-free onset target around 300 ms, preservation of first words, silence stop, final transcript delivery, visible armed state and explicit disarm.
- Verify no transcript/remote transcription during silent arming, cancellation, interruption and fallback on unsupported devices or missing/unavailable assets.
- Run native tests covering existing HandsFreeVoiceActivity, capture ownership/finalisation, settings and lifecycle paths as part of qualification; do not claim they prove microphone timing.

**Risks and limits**

- Press WER and speed claims are unverified and must not serve as benchmark evidence.
- Issue claims of no model download and Apple Intelligence dependency do not match code: assets are prepared and DictationTranscriber is explicitly documented as not requiring Apple Intelligence.
- Static inspection confirms implementation coverage, not runtime reliability or measured latency.
- Beads CLI absent per supplied context; this JSON is interim review evidence, not a replacement tracker.

## #648: [Feature] Paid Access

Reviewer: `/root/issue_review_queue/review_648`.

**Smallest worthwhile scope:** No new implementation from this intake. Retain issue as PR #665 launch umbrella; reconcile residual gates against its latest head and runbook, keeping feature disabled.

- `issue-context.json: PR #665`: Explicitly closes #648; latest September 12 update reports 158 Worker tests and fixes for separate purchase identities, shared quotas, settlement and metadata-only claim pruning. Feature remains off pending setup and staging.
- `origin/fix/review-paid-access:Sources/SpeakCore/PaidAccess/PaidAccessRouting.swift`: PaidBillingChannel centralises distribution choice; SimpleModelChoicesPolicy.hidesModelSelection requires actual paid routing; PaidRoutingDecision preserves local/BYOK outcomes.
- `origin/fix/review-paid-access:Docs/paid-access.md`: Internal-only PAID_ACCESS build flag; public builds compile feature dark; explicit external billing/Cloudflare setup and iOS routing/purchase gate.
- `comments/648.json`: Prior audit lists billing identity, channel trust, direct-download Apple identity and privacy decisions. Some are superseded by September PR fixes and must not be reopened from stale commentary.

**Dependencies**

- Continue within existing PR #665 ownership; do not commission competing implementation.
- Real Stripe prices, D1 identifiers, App Store products, staging and signed-build identity validation remain prerequisites.
- Outstanding iOS, voice-edit/live-polish and live client routing belong to existing paid-access follow-up scope; revalidate current PR before commissioning any.

**Verification**

- Use latest PR CI for Worker/typecheck/lint and native compilation; 158 tests is reported evidence, not rerun here.
- Before any activation validate purchase, renewal, expiry, refund, restore, quota and failure recovery in staging, plus signed native identity and billing UI.
- Verify public default BYOK/local operation, no paid-network contact for those paths, retained model access on lapse, clear cost/privacy disclosure, and no iOS purchase until paid routing is real.

**Risks and limits**

- Targeted read-only review; main contains no paid-access implementation because PR remains separate.
- No purchase, deployment or feature activation authorised by this review.
- Older comment claims about response-body retention and entitlement design are superseded; current PR says metadata-only claims and independent purchase records.
- External staging and native/device behaviour are unverified here; Beads CLI is absent per intake context.

## #655: Automation surface phase 2: `speak` CLI over the local transport

Reviewer: `/root/issue_review_queue/review_655`.

**Smallest worthwhile scope:** Obtain one clean supported Mac install using the current tap, verify speak resolves on PATH and reports matching version, enable Automation, and transcribe a short known audio fixture using the user's already-configured provider. Record evidence and close only when the remaining acceptance items pass. Make code changes only for a reproduced failure.

- `Sources/SpeakAutomationKit/CLIRunner.swift`: Existing thin request client renders transcripts and history, stable schema-versioned JSON, and meaningful exit codes.
- `Sources/SpeakApp/Transport/AutomationServer.swift`: Dedicated same-machine UNIX socket is explicitly separate from Bonjour transport; its handler lifetime is owned by the socket. Send to Mac removal does not imply removing this local automation surface.
- `Sources/SpeakApp/Transport/AppAutomationHandler.swift`: Checks audio file presence and size, then delegates to the app's TranscriptionManager and returns transcript/model/duration.
- `Docs/automation.md`: Documents opt-in, owner-only socket and current standalone CLI formula plus cask dependency. Older embedded-binary packaging evidence does not fully cover this distribution path.
- `/workspace/scratch/a8be40db3c71/comments/655.json`: 26 Aug installed app evidence covers opt-in/off, permissions, history and second instance. Comment explicitly leaves clean Homebrew install and actual transcribe-file provider run unverified.

**Dependencies**

- Parent #613 and existing merged CLI implementation #667; do not recreate phase 2.
- Current published Homebrew formula/cask and signed released Mac app required for acceptance.
- Independent of removed Send to Mac / superseded #1024.

**Verification**

- Record exact cask/formula/release versions and installation/PATH output.
- Run speak transcribe fixture.m4a and --json against the signed running app; confirm expected transcript, selected model/provider and documented envelope.
- Retain prior opt-in/off, permission and second-instance evidence; recheck where current release changes those seams.
- Restore initial automation setting; no release publication or paid-credit activation.

**Risks and limits**

- Read-only value review: no native runtime or Homebrew/provider verification performed.
- Linux cannot provide installed Mac app acceptance; this is an evidence gate, not a reason to replace working code.
- Cloud-provider fixture run may incur usage; use existing configured access within authorised scope and do not purchase credit.
- Beads CLI is absent per supplied context; this JSON is review evidence only.

## #656: Automation surface phase 3: MCP server exposing dictation tools

Reviewer: `/root/issue_review_queue/review_656`.

**Smallest worthwhile scope:** Qualification-only follow-up: use the documented current standalone speak installation, register it with an actual Claude Code client, and call get_history(limit:1) against the running app with explicit local Automation opt-in. Record app/CLI/client versions and redact transcript contents. Correct the small idempotency documentation mismatch if a documentation change is bundled. Do not commission a feature implementation solely to satisfy this issue.

- `Sources/SpeakAutomationKit/MCPRequestHandler.swift`: Existing initialize/tools/list/tools/call implementation advertises the four requested tools, validates requests, returns tool errors and structured results, and scopes idempotency keys per process.
- `Sources/SpeakAutomationKit/MCPStdioServer.swift`: Existing newline-framed stdio server handles oversized messages and EOF.
- `Tests/SpeakAutomationKitTests/MCPServerBehaviourTests.swift`: Tests cover the four-tool contract, transcript and structured results, history validation, idempotency, failures and stdio framing; not executed in this review.
- `Docs/automation.md`: Documents opt-in local socket, current standalone CLI installation, Claude Code configuration, tool schemas and recovery. Idempotency prose still says mcp-<id>, whereas code now adds processScope.
- `comments/656.json`: 26 August released-app evidence records successful MCP get_history against version 2.62.0, owner-only socket permissions, no second-instance takeover, and restoration of disabled Automation. Only Claude Code registration and call remain unverified; earlier automation-off blocker was subsequently resolved for protocol testing.

**Dependencies**

- #613 umbrella; #655 already implemented CLI/local socket. Coordinate the real Mac qualification with #655's remaining installation/provider checks.
- Existing PR #667 implementation is present on main; no new MCP architecture required.
- Do not restore removed Send to Mac (#1024).

**Verification**

- Actual Claude Code client registers the documented command and discovers exactly the four tools.
- A real get_history(limit:1) call succeeds against the running app; capture result shape and success without publishing private text.
- Restore the prior Automation setting/client configuration after a temporary qualification and confirm disabled automation removes access.
- Preserve existing August protocol evidence separately from new named-client evidence; close only after the outstanding acceptance criterion is met.

**Risks and limits**

- This read-only review does not prove native runtime or microphone behaviour. No native tests or client calls were run here.
- Automation grants same-user local processes microphone/history access while enabled; do not silently enable it or introduce network listeners.
- No paid-provider use is needed for get_history qualification; broader audio qualification belongs with #655.
- Beads CLI is absent per parent context; JSON is interim review evidence, not a replacement tracker.

## #657: watch: complication + Smart Stack entry to start recording from the watch face

Reviewer: `/root/issue_review_queue/review_657`.

**Smallest worthwhile scope:** Execute and record the existing signed paired-device checklist against an exact main SHA. Open a narrowly scoped repair only for an observed failure. Keep the feature and release signing gates unchanged until provisioning and acceptance are complete.

- `JustSpeakWatchWidget/WatchRecordingComplication.swift`: Existing circular and corner WidgetKit complication renders recording status through the shared action button.
- `JustSpeakWatchWidget/WatchCaptureStatusWidget.swift`: Existing rectangular Smart Stack widget displays capture state and in-flight count.
- `JustSpeakWatchShared/StartWatchRecordingIntent.swift`: watchOS 11 AudioRecordingIntent routes to the app coordinator; watchOS 10 has a foreground hand-off fallback. Extension code does not create a separate recorder.
- `JustSpeakWatch/WatchRecordingCoordinator.swift`: One shared recorder and toggle serialiser own recording entry points; headless toggle explicitly activates WatchCaptureStore before recording.
- `Project.swift; Docs/watch-provisioning.md`: Manifest retains TUIST_WATCH_APP gating and widget target; provisioning documentation requires bundle identifiers, shared Watch App Group, profiles and physical acceptance checks.
- `comments/657.json; issue-commit-evidence.json`: Latest cached comment says implementation shipped in #683 and explicitly keeps this open for hardware evidence. Recent #939 fix documents that headless delivery acceptance remains under #657/#659.

**Dependencies**

- #612 Watch capture parent
- #683 existing implementation
- #659 overlapping Watch hardware and battery acceptance
- #939 headless WatchConnectivity activation fix already on main
- Paired physical Watch/iPhone and valid signing/provisioning

**Verification**

- Record watchOS version, iPhone build, SHA and per-row PASS/FAIL evidence.
- Verify circular/corner and rectangular families; headless start/stop on watchOS 11+, recording indicator and accurate capture states.
- Verify rapid/repeated taps and in-app overlap yield one recorder and one History item.
- Verify app termination/partial recovery, stale Recording expiry, unavailable phone/reconnection, and denied microphone permission.
- Verify watchOS 10 foreground hand-off if available; collect one-minute battery/time observations with #659.

**Risks and limits**

- Static inspection does not prove headless audio, recording indicator, background transfer, signing or physical-device success.
- Existing code is covered; issue closure is not justified before the explicit hardware acceptance run.
- Do not enable Stable release inclusion or register/publish signing changes as part of this triage.
- Beads CLI is unavailable according to parent context; this scratch JSON is review evidence, not a substitute tracker.

## #659: watch: extended runtime session for wrist-down recordings

Reviewer: `/root/issue_review_queue/review_659`.

**Smallest worthwhile scope:** Run and record the existing three hardware acceptance cases against a current provisioned build. Use actual audio interruption/invalidation or termination/relaunch recovery; do not add WKExtendedRuntimeSession merely to manufacture an expiry case. Open a narrowly evidenced fix only if a case fails.

- `JustSpeakWatch/WatchRecordingRuntime.swift`: Activates AVAudioSession .record while foreground, observes interruptions/media-services reset, ignores stale notifications through run IDs and documents the deliberate audio-background choice over WKExtendedRuntimeSession.
- `Project.swift`: Watch target has UIBackgroundModes audio and explicitly avoids unrelated WKBackgroundModes categories.
- `JustSpeakWatch/WatchAudioRecorder.swift`: Single guarded finalisation stops audio, releases runtime, inspects playable audio and queues it. Relaunch recovery uses persisted identity, queue deduplication and clears the active marker only after successful enqueue.
- `Tests/SpeakCoreTests/WatchRecordingLifecycleTests.swift`: Deterministic policy and recovery coverage exists; it cannot establish actual watchOS suspension, battery cost or phone delivery.
- `comments/659.json`: Latest cached comment says runtime/capture recovery shipped in #669 and #721; all three remaining acceptance rows require paired Watch hardware.
- Recent #939 headless WatchConnectivity activation repair expressly leaves paired-device validation under #657/#659.

**Dependencies**

- Paired physical Apple Watch and iPhone with provisioned matching build
- Parent #612 and companion hardware gate #657
- Existing shipped #669/#721 recovery work; recent #939 headless activation fix should be included in tested SHA

**Verification**

- At least 60 seconds wrist down/screen asleep with spoken markers near 0, 30 and 60 seconds; all markers reach one iPhone History entry.
- With phone unavailable, interrupt or terminate a capture, relaunch where needed, verify one recoverable partial capture and eventual History delivery after reconnection, with no orphaned watch audio.
- Record Watch model/watchOS, iPhone build, source SHA, Low Power Mode and battery conditions; collect repeat runs or longer normalised energy measurement if one-minute percentage resolution is inadequate.

**Risks and limits**

- No physical hardware results obtained; neither static inspection nor existing pure lifecycle tests establishes OS behaviour.
- Issue title/body and latest comment terminology say runtime session/expiry, whereas actual implementation deliberately uses AVAudioSession background audio. Preserve outcome-based acceptance rather than requiring an inappropriate API.
- A forced termination cannot execute clean finalisation until relaunch; verify recovery rather than claiming synchronous expiry handling.
- Beads CLI is absent per supplied context; this JSON is review evidence only.

## #661: iOS keyboard v2: run the physical-device matrix and flip the TestFlight flag

Reviewer: `/root/issue_review_queue/review_661`.

**Smallest worthwhile scope:** A documentation-only PR should reconcile keyboard design/verification instructions with handoff shipping status, current manifest-based release workflow and the #991 finding. Preserve a concrete physical-device handoff matrix and evidence template. Mark direct-capture sections historical/experimental with an explicit new platform-evidence prerequisite. Do not change any flags, dispatch a release, fabricate device results or close the physical verification obligation.

- `Docs/ios-keyboard-v2-design.md`: Shipping status includes the handoff keyboard by default; the issue #991 update dated 2026-09-10 records unavailable direct microphone capture and says the retained flag is a record, not a roadmap. Older surrounding prose still calls it an unverified candidate.
- `Docs/ios-keyboard-mvp-verification.md`: Physical-device matrix defines device/OS/host evidence, handoff behaviour, permissions and release gates. Rollout sections still reference manual include_keyboard/enable_direct_capture workflow inputs and propose enabling direct capture after the matrix.
- `.github/workflows/release-ios.yml`: Current workflow is workflow_call with a required manifest only; environment sets TUIST_IOS_KEYBOARD=1 and TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0. Old manual-input instructions do not match this workflow.
- `Project.swift`: Independent TUIST_IOS_KEYBOARD and TUIST_IOS_KEYBOARD_DIRECT_CAPTURE policies remain; generating a development keyboard build does not authorise changing release defaults.
- `Sources/SpeakCore/KeyboardDictationMachine.swift`: KeyboardCapturePlanner.path defaults directCapturePolicy to disabled and returns handoff before checking extension permissions.

**Dependencies**

- #678 and PR #719 blockers were cleared according to latest cached issue comment; do not reopen them.
- #991 supersedes the direct-capture platform assumption.
- Coordinate release-runbook corrections with current Alpha/Stable train documentation; #1126/#1127 verification occurs in a real future Alpha, not an authorised dispatch now.

**Verification**

- Static cross-check that documented build/workflow inputs and app-group identity selection match current release-train configuration.
- Design and verification documents consistently state handoff shipping mode and disabled direct capture; no promise or instruction to flip direct capture as routine completion.
- Physical iPhone/iPad evidence remains required for Full Access, ready/not-ready handoff, transcript/cursor preservation, interruptions, system restrictions, VoiceOver/touch targets and memory. Record exact source/build/device/OS/host versions and PASS/FAIL evidence.
- Direct-capture enablement requires new supported platform evidence, dedicated physical verification and separate rollout approval; no rollout authorisation inferred.

**Risks and limits**

- Read-only source inspection does not establish installed extension presence, physical microphone behaviour, host editing safety or memory use.
- No Apple device/Xcode verification performed.
- The #991 finding is assessed as current repository evidence, not an independently reproduced platform result.
- Beads CLI is absent per supplied context; this scratch decision file is analysis evidence, not a task tracker.

## #664: test(mac): verify streaming insertion across the allowlisted target apps

Reviewer: `/root/issue_review_queue/review_664`.

**Smallest worthwhile scope:** Create a concise reproducible qualification runbook/result template if none exists, reflecting the actual two-app allowlist and existing TextEdit results. Finish Notes, setting-off baseline, and a non-allowlisted app baseline on an unlocked Mac. Re-run affected TextEdit scenarios only if current code differs materially from the evidenced build. Fix or disable only failures observed in the supported surfaces. Keep experimental default off and do not expand allowlist as part of this issue.

- `Sources/SpeakApp/StreamingInsertionAllowlist.swift`: Only TextEdit and Notes are permitted. Slack, VS Code, Safari and Chrome are deliberately excluded because kAXValue read-back cannot reliably verify the streamed region.
- `Tests/SpeakAppTests/StreamingInsertionSettingsTests.swift`: Existing tests cover default-off setting, current allowlist and deliberate excluded apps; repeating these tests does not complete physical app qualification.
- `Sources/SpeakApp/LiveTextInserter.swift`: Unverifiable region returns failed; lost target or failed final patch after writes returns applied while preserving existing partials. The latter protects against duplicate insertion but is not proof of exact final-text equality.
- `comments/664.json`: Chris's detailed v2.49.0 run records TextEdit PASS and Notes, setting-off, and Sublime Text baseline BLOCKED by locked Mac. Later bravostation summary incorrectly claims both allowlisted apps passed. Prefer the detailed primary run; Notes cannot be counted as verified.

**Dependencies**

- #611 owns expansion beyond two apps; #647 shipped ranged streaming insertion.
- Unlocked interactive Mac with Accessibility permission and a signed direct-distribution build; preserve build SHA, OS/app versions, provider/model and post-processing configuration.
- Beads CLI is absent in supplied environment; no substitute tracker was created.

**Verification**

- Record build | macOS | app/version | field | scenario | fallback/pause | exact final text match | pass/fail | evidence.
- Notes: partials, correction/retraction, selected-text replacement, Unicode/duplicate surrounding text, edits before/inside/after region, focus changes, History accessibility method and firstInsertMs.
- Setting off and non-allowlisted app: no partial insertion and exactly one final delivery.
- Keep Insert at Cursor as documented test configuration; do not claim Replace Field qualification.
- For loss of target/final-patch failures record safe preservation separately from exact final transcript match. A safety PASS cannot substitute for exact-match PASS.
- Native CI can verify code changes; manual AX evidence is still required for gate closure. Do not close from the contradicted summary.

**Risks and limits**

- This environment cannot produce physical macOS AX or provider observations. Qualification remains device-gated; useful runbook work can proceed now.
- Allowlisting is per bundle ID, so test named fields; one working Notes field does not establish all Notes controls.
- Historical TextEdit evidence is tied to mac-v2.49.0 and does not automatically qualify unrelated newer insertion changes.
- No release promotion or Stable publication is authorised by this review.

## #776: Ship opt-in PostHog analytics transport, consent UI and audited rollout

Reviewer: `/root/issue_review_queue/review_776`.

**Smallest worthwhile scope:** Plan and implement a direct-macOS release inspector attached to the actual transport serializer: consent, endpoint, queue depth, anonymous install ID/reset, bounded last-100 queued/sent event view/export, native controls and clear progress/error feedback. Never expose the ingestion key in inspector exports or publish user-level records.; Wire the existing core forceDisabled seam to an operational local production kill switch, preserving ordered cancellation/purge and opt-in semantics. Add meaningful wire-parity, withdrawal and kill-switch regressions.; Reconcile the issue/audit checklist against merged and newly implemented evidence. Prepare reproducible release-network/server qualification instructions without declaring gates passed or widening collection.; Keep daily-activity correctness and catalogue-to-docs drift as explicit small follow-ups in this tracker; avoid bundling new production event families.

- `Sources/SpeakApp/PostHogAnalytics.swift`: Minimal capture transport is excluded under APP_STORE; configuration absence is no-op; durable queue is capped at 1,000 events/seven days; cancellation/purge and bounded retries already exist. Queue and wire inspection are private, with no release inspector API.
- `Sources/SpeakApp/Views/Settings/SettingsView+About.swift`: Privacy settings expose analytics opt-in and policy link but no payload inspector, identity reset, export or operation feedback.
- `Sources/SpeakApp/WireUp.swift`: Initial consent, settings subscription and phase-one call sites are wired. Daily-active event currently runs on install/startup and marks the day after best-effort capture; it does not establish a multi-day-running-app daily signal.
- `Sources/SpeakCore/ProductAnalytics.swift; Docs/analytics-implementation-audit.md`: Core has forceDisabled and sample preview support; audit explicitly records missing production factory override, exact wire inspector, docs drift check and release/server qualification.
- `commit 764b9c3e36fe800946aad3e3e65a04ae173ea66c; cached comments/776.json`: Consent/queue reliability already merged with native candidate test evidence; latest owner comments explicitly retain retention, kill-switch and no-content inspection gates. Parent verified four production taxonomy events; this establishes event existence, not rollout qualification.

**Dependencies**

- #814 broader lifecycle/settings instrumentation must await a clean phase-one inspection week.
- #809 and #916 cover existing transport/consent and reliability implementation.
- Production-only project, EU vendor, explicit opt-in, separate identities, contact and sole-owner decisions are approved; do not request again or create Development.
- Server retention/settings evidence and key-rotation drill, release-network audit and identity separation remain required.
- iOS/TestFlight/App Store expansion and disclosures remain separately gated; Mac App Store must retain compile-out.

**Verification**

- Offline transport spy asserts unknown/opted-out/local-disabled states produce zero traffic; withdrawal cancels controlled work, purges persisted queue and removes install identity, including in-flight transitions.
- Inspector payload fields match the actual event wire envelope; credential omission is explicit and tested. Last-100 storage is bounded and reset/withdrawal clear identity-associated history. Reset/export show truthful completion/failure states.
- Apple Swift Debug/Release CI covers changed code; a release Mac run validates inspector UI, reset/export and zero-traffic consent behavior. Linux inspection alone cannot establish these results.
- Before enablement/expansion: complete retention/server settings evidence, approved key-revocation drill, full release network capture, policy publication, Sentry identity-separation checks and clean inspection week. Production taxonomy count alone cannot substitute.

**Risks and limits**

- Do not widen capture, enable iOS/store analytics or remove compile-out as part of engineering completion.
- Actual production events already exist per parent audit; recorded gates still require independent evidence and must not be inferred from ingestion.
- Cannot recall bytes already received by the server before withdrawal; cancellation guarantees must remain precise.
- Exact-payload visibility and privacy must reconcile the transport credential envelope by showing event JSON and clearly documenting excluded authentication material.
- Beads CLI is absent; this JSON is interim review evidence, not a replacement tracker.

## #802: Epic: protect the core dictation journey with fast macOS E2E regression tests

Reviewer: `/root/issue_review_queue/review_802`.

**Smallest worthwhile scope:** First increment: extend the current launched batch journey with deterministic post-processing-on success plus a post-processing failure followed by a successful next run in the same app process. Exercise real MainManager routing and assert the documented fallback, exact clipboard output and durable raw/processed History without stale or duplicate delivery. Use the existing global hotkey/recording/transport seams, isolation and diagnostic artifacts. Keep streaming and direct-target permission qualification explicitly open for subsequent increments.

- `Tests/SpeakAppUITests/CoreJourneyBatchUITests.swift`: Real Carbon chord drives production recording and validates exact clipboard output, strict synthetic audio HTTP request, production state progression and durable History. Native paste is conditional on actual posting access; direct AX insertion is not proved.
- `Sources/SpeakApp/WireUp.swift`: Existing isolated batch transport and recording seams support incremental scenarios without replacing production orchestration.
- `.github/workflows/ci.yml`: Two bounded ten-minute gates already exist; native selection covers launch, target fixture, hotkey and batch UI suites, with result verification and artifacts.
- `Docs/core-journey-e2e.md`: Runbook already distinguishes component contracts and actual native batch coverage; processing routing, streaming, failure/recovery and captured-target scenarios remain native gaps.
- `comments/802.json`: Owner reports passing native batch evidence and explicitly retains streaming, post-processing, failure/target and cold/device qualification gaps. Historical #913 bootstrap-only state is superseded.

**Dependencies**

- Reuse merged #804/#811/#817/#913/#916 harness and strict suite manifests; no duplicate foundation work.
- Keep #707 captured-target and #800/#801 clipboard regression contracts; complement existing unit/integration coverage.
- Native macOS Xcode CI required for execution; genuine permission-capable Mac needed for mandatory AX/physical checks.

**Verification**

- New scenarios must begin at real supported Carbon events; do not call orchestration methods directly.
- Validate real raw-to-processed output and History semantics, no unexpected network or real credentials, visible actionable error on failure and successful same-process recovery.
- Add new selected suites to fail-closed CI execution verification; preserve existing tests and ten-minute gate budget.
- Measure native duration and flake rate separately; retain 20 green runs including five cold runners before asserting qualification or completing epic.
- Static inspection on Linux is not execution evidence; do not weaken permission failures into claims of direct editor coverage.

**Risks and limits**

- Extending fixture seams can accidentally bypass production routing or expose test configuration in release builds; retain explicit DEBUG-only isolation.
- Existing fifteen-second gesture wait per run can consume budget when adding recovery scenarios; measure actual native runtime before expanding the matrix.
- AX permissions, physical microphone/Fn and real target apps remain separate qualification gates.
- Beads CLI is absent per supplied environment context; no tracker mutation attempted.

## #814: feat(analytics): wire detailed transcription, post-processing and settings telemetry

Reviewer: `/root/issue_review_queue/review_814`.

**Smallest worthwhile scope:** No new collection now. After the gate passes, reassess a first increment limited to exactly-one terminal outcome, measurable capture-to-first-text and stop-to-final latency, compiled model/provider/mode segmentation, and post-processing overhead. Add each setting only when it answers a named product question; do not automatically instrument every setting.

- `Sources/SpeakCore/AnalyticsPropertyValue.swift`: Native Boolean, integer and double payload values already exist; that portion is covered and should not be rebuilt.
- `Sources/SpeakCore/ProductAnalytics.swift`: Lifecycle types use coarse duration/word-count/latency buckets. Settings changes have no typed value. Catalogue presence is not production capture or terminal-event accounting.
- `Docs/analytics-implementation-audit.md`: Explicitly records absent exact timing/model/settings call sites and requires the clean phase-one week before expansion; source tests do not establish production network qualification.
- `Docs/analytics-plan.md`: Phase one remains activity/onboarding/first-transcription success, with one clean week of inspected payloads before expansion.
- #916 delivered scalar/consent/queue reliability foundations and explicitly retained rollout/device gates; it did not authorise #814 expansion.
- `/workspace/scratch/a8be40db3c71/comments/814.json`: No later issue comments override the dependency. Parent-provided production inspection found four custom event types only; this is not a clean-week approval.

**Dependencies**

- #776 production go/no-go, release network/withdrawal/inspector checks, retention and identity-separation evidence, then one clean phase-one inspection week.
- #776 currently accepted scope is inspector/reset/export/kill switch plus rollout audit, without event expansion.
- #916 covers typed scalar and queue/consent foundations, not #814.

**Verification**

- Record dated production go/no-go and seven-day payload-inspection evidence before enabling expanded events.
- For the later scoped implementation, prove one emitted terminal event per session across success/failure/cancellation/races; distinguish app emission from network delivery guarantees.
- Test native scalar encoding, compiled-catalogue allowlisting with unknown/custom IDs reduced to other, prohibited-content rejection, opt-out purge and no startup-hydration setting events.
- Verify disabled development/store transport, update both privacy documents before release, and run Apple Swift CI plus release-build network checks; Linux static inspection cannot establish these.

**Risks and limits**

- No fresh backend inspection performed; existing supplied production evidence is insufficient to clear the week-long rollout gate.
- Exact timings, language and many settings increase payload detail and cardinality even with no transcript content; collect only dimensions that answer a concrete reliability or product question.
- Dynamic OpenRouter discoveries must not silently broaden the compiled model allowlist.
- Beads CLI is absent; this review JSON is interim analysis evidence, not a replacement tracker.

## #821: Product proposal: dynamic OpenRouter transcription and TTS model catalogue

Reviewer: `/root/issue_review_queue/review_821`.

**Smallest worthwhile scope:** Plan and implement an opt-in internal progressive speech path for one verified supported response format, shared bounded transport/stream state in SpeakCore with native playback adapters, preserving completed-file/export behaviour and existing fallback. Measure time to first audible output. Keep capability/cost enrichment to verified metadata that can be labelled accurately; defer speculative controls and additional provider integrations.

- `Sources/SpeakCore/OpenRouterAudioCatalog.swift`: Shared capability-filtered discovery already has a six-hour cache, stale retained state, cancellation and refresh ownership protection.
- `Sources/SpeakCore/OpenRouterAudioModelDetail.swift`: Existing native form displays raw provider pricing, model-specific voices, STT file tests, speech previews and explicit cloud/cost disclosure; it does not normalise every pricing unit or expose a full provider-parameter editor.
- `Sources/SpeakCore/OpenRouterAudioClient+Download.swift`: Bounded response bytes are written to a private file; the URL is returned only after the response completes. Speech currently requires audio/mpeg, so network streaming alone does not give progressive playback.
- `Sources/SpeakApp/TextToSpeech/OpenRouterTTSClient.swift`: Normal macOS speech waits for synthesis completion and AVURLAsset duration; it preserves dynamic voice choices and owns temporary-file cleanup. Provider speed is deliberately avoided until supported metadata exists.
- `comments/821.json`: Retained 9 September macOS qualification exercised MAI-Transcribe-2 through the installed catalogue and file-test UI with a successful response; it explicitly leaves progressive playback and further device/provider qualification open.

**Dependencies**

- #916 and #918 already delivered core discovery, STT/TTS routing and native settings; do not duplicate them.
- A separate planner must verify the current OpenRouter speech response/codec contract and identify reusable native playback infrastructure before designing an incremental streaming path.
- Native Apple Swift CI and Mac/iPhone playback qualification remain required; existing provider credits only.

**Verification**

- Prove audible playback can start before the final response byte for a sufficiently long fixture and supported live provider; compare first-audio latency with the existing completion-based path.
- Exercise slow chunks, malformed/truncated compressed audio, cancellation before and during playback, timeout, HTTP errors, response limits and immediate subsequent requests without stale playback or file leaks.
- Verify Mac/iPhone stop, audio-route interruption and recording-session ownership with native tests/device evidence; do not infer those results from Linux or mocked transport.
- Retain existing discovery/cache/selection tests, show unavailable saved selections without replacement, and preserve accurate unknown-cost reporting and content-free telemetry.
- Keep the epic open until remaining acceptance items have explicit provider/platform evidence; do not equate one MAI file-test result with all-provider accuracy or normal dictation qualification.

**Risks and limits**

- Progressive MP3 decoding and buffering can introduce underruns, decoder failures or interference with microphone/audio-session ownership; this is a focused playback change, not a catalogue rewrite.
- Raw pricing units cannot safely be treated as equivalent or turned into an estimated cost without documented provider semantics.
- No new native/device/provider validation was performed during this bounded read-only value review.
- Beads CLI is unavailable in this environment per the supplied project context; this JSON is review evidence only, not a replacement tracker.

## #919: feat: integrate Blue Machines AI Aurora STT when API access is available

Reviewer: `/root/issue_review_queue/review_919`.

**Smallest worthwhile scope:** Have a separate planner define a finite primary-source/access qualification pass with a dated evidence result. If authoritative interface and permitted account access are still unavailable, record the exact remaining gates and stop without app code or a selectable placeholder. If they become available, plan one supported transport using the existing provider seam; do not assume OpenAI compatibility or invent streaming support.

- `README.md`: Native macOS/iOS transcription, accurate text, live feedback and privacy are core outcomes.
- `.copilot/skills/justspeaktoit-design.md`: Speed, privacy, transparent cost and native quality guide scope; unnecessary setup/UI must not be added for an unavailable provider.
- `Sources/SpeakCore/TranscriptionProviderRegistry.swift`: Existing protocol requires actual file transcription, API key validation, supported models and credential metadata. An announcement cannot supply these contracts.
- `Sources/SpeakApp/TranscriptionProviderRegistry.swift`: Registry contains 16 concrete providers with model-prefix and supported-ID routing; no Aurora provider is registered in this excerpt.
- `/workspace/scratch/a8be40db3c71/review-input/919.md`: 8 September checks found health/auth/sales surfaces without an inference contract; 9 September explicitly retains access and real-audio gates. Cached live comments contain no override.

**Dependencies**

- Authoritative endpoint/model ID, authentication, account entitlement, request/response and streaming/finalisation contract, audio formats and limits.
- Existing free credits/access only; no purchases, paid billing activation or outreach authorised.
- Shared SpeakCore catalogue and capability definitions, secure credentials, macOS/iOS routing, friendly History names.
- Beads justspeaktoit-275 remains the issue identity; CLI currently absent according to parent context.

**Verification**

- Qualification records vendor-owned contract sources and distinguishes verified access from unavailable evidence; account health or saved credentials do not count as inference success.
- Before claiming integration, transcribe a small synthetic real-audio fixture through the actual service using existing free access and preserve response/latency/error evidence without secrets.
- Conditional integration requires shared catalogue parity and supported-platform picker/routing tests, contract/error tests, stop/finalisation coverage when applicable, relevant lint/build/CI and macOS/iOS UI verification.
- Keep the issue open until the original integration outcome is validated; qualification alone does not complete #919.

**Risks and limits**

- This value review did not re-query vendor services; historical access evidence is explicitly dated and requires qualification before implementation.
- No proof of Aurora accuracy, Indian-language coverage, cost, privacy policy or streaming behaviour is inferred from its announcement.
- Apple native builds/device and microphone validation cannot be established by Linux static inspection.
- Do not reactivate the older daily discovery automation or infer Stable publication permission.

## #929: research(mac): qualify Indic-Speak runtime before local TTS integration

Reviewer: `/root/issue_review_queue/review_929`.

**Smallest worthwhile scope:** Once access is available, qualify exactly one Apple Silicon runtime with synthetic Hindi and English inputs and produce a reproducible go/no-go report. Keep app integration, catalogue/UI changes, packaging, and iOS support excluded until the result supports them.

- `README.md`: On-device privacy and native SwiftUI behaviour are stated product goals; SpeakCore owns shared model catalogue types.
- `Sources/SpeakApp/TextToSpeech/TTSProtocol.swift`: Existing macOS provider enum and routing cover hosted providers plus system synthesis, with no Indic-Speak provider. This is not already implemented by generic routing.
- `Sources/SpeakApp/TextToSpeech/SystemTTSClient.swift`: Local synthesis delegates to Apple speech APIs and the exposed system voices are filtered to English. This does not supply an Indic-Speak Llama/SNAC/Vocos runtime.
- `/workspace/scratch/a8be40db3c71/comments/929.json`: 10 September comment explicitly separates hosted Bodhan API issue #1087 from local access/licence/runtime qualification and says those gates remain.

**Dependencies**

- An explicitly authorised upstream acquisition route; issue snapshot says gated weights and no verified route. Licence/contact-sharing acceptance needs explicit authorisation under this issue scope.
- Exact compatible released weights and inference code, including resolution of the preview-v2 reference.
- Apple Silicon hardware and dependencies for actual audio qualification.
- #1087 covers the separate hosted Bodhan route; do not merge its evidence into local qualification.
- Beads justspeaktoit-3db remains canonical issue tracking; CLI is absent per parent context.

**Verification**

- Record authorised acquisition, applicable terms, pinned weight revision and matching inference revision; do not infer access from an accessible README.
- On named Apple Silicon hardware, verify valid 24 kHz output and native playback; measure first-audio latency, real-time factor and peak memory.
- Exercise cancellation, empty input and a longer sample to assess the documented drift risk.
- Only a successful runtime result permits a separate integration plan; no placeholder model entry.

**Risks and limits**

- This bounded review uses the supplied issue and latest cached comment as dated evidence; it does not claim a fresh remote access check or repeat deep research.
- Community MLX performance claims do not establish permission, application compatibility or measured local performance.
- Linux code inspection cannot establish Apple runtime behaviour or real audio quality.
- The general request to implement valuable issues does not itself clear the issue-specific model/contact-sharing acquisition gate.

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

## #956: iOS: defer Vocal Shortcuts setup guidance pending device verification

Reviewer: `/root/issue_review_queue/review_956`.

**Smallest worthwhile scope:** First qualify the existing Start Recording action on a physical iPhone. After a successful bounded unlocked start → real capture → verified stop → History flow, add one concise help row/section with the exact verified setup, stop method, limitations and Apple guide. Reuse native StepRow/BulletRow. No new intents, listening engine, gallery or capture changes.

- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Start Recording, Toggle Recording and Stop Recording already exist and conform to AudioRecordingIntent and LiveActivityIntent. Start is idempotent and foreground-continuable. These declarations establish reusable actions, not Vocal Shortcuts picker or microphone coexistence behaviour. Current actions also expose destination parameters; older issue assumptions about absent overrides should not be copied into new guidance.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Existing settings now include native control guidance, Shortcut setup, Start/Stop pairing, other hardware triggers, permission caveats and an unlocked History verification exercise. Vocal Shortcuts guidance remains absent.
- `/workspace/scratch/a8be40db3c71/comments/956.json`: No live comments or new physical-device outcomes were supplied.

**Dependencies**

- #954 native-control/setup guidance is already present; reuse its existing section after qualification.
- #953 background-start conformance is present, but does not satisfy Vocal Shortcuts evidence.
- #932 Live Activity lifecycle, #936 interruption finalisation and #934 clipboard safety remain separate owners; do not broaden this issue.

**Verification**

- Record device, OS, app commit/build, provider, destination, permissions and exact selectable action or personal-Shortcut wrapper.
- Prove unlocked warm real-speech capture and manual stop; with History Only verify transcript persistence, microphone capture termination and an unchanged synthetic clipboard sentinel.
- Test separate voice-stop behaviour and audio quality with Vocal Shortcuts enabled; record failures and retain a verified manual stop path.
- Record cold/warm locked and screen-off outcomes for any corresponding claims; verify each advertised OS separately.
- Only after re-entry, read the complete instructions on the device and run applicable iOS build/lint gates. Static-copy unit tests add no value.

**Risks and limits**

- No device verification was available; native build or simulator success cannot establish voice-trigger coexistence or locked capture.
- On-device phrase detection does not make a selected cloud transcription provider local.
- Do not imply voice phrases authenticate the speaker or prove readiness.
- No SOL implementation dispatch is warranted before the existing evidence gate is met.
- Beads CLI is absent per supplied context; this JSON is review evidence, not a replacement tracker.

## #958: iOS: defer automation recipes pending a verified device walkthrough

Reviewer: `/root/issue_review_queue/review_958`.

**Smallest worthwhile scope:** After a physical iPhone walkthrough passes, add one concise manually configured deliberate NFC Start Recording recipe to existing guidance, with an explicit reachable Stop Recording/Live Activity stop. Document shared destination semantics, observed foreground/unlock requirements and disabling/deleting the automation. No gallery infrastructure, tags/schema, new destinations or unattended triggers.

- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Start Recording is idempotent across starting/recording and checks foreground ownership; it now exposes Destination, Language, Model and Source parameters. The old claim that intent parameters remain unimplemented is stale. Foreground continuation and permission failure handling do not prove an NFC workflow works on a physical device.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Existing setup describes Toggle-only shortcuts, separately paired Start/Stop shortcuts, clipboard safety and access to the current gallery. Reuse this surface for any later verified recipe.
- `Sources/SpeakiOS/Views/AutomationGalleryView.swift`: Main already has a manual recipe gallery associated with #1015. Its presence is not evidence for the separate personal-automation device gate. Avoid creating a second gallery.
- `/workspace/scratch/a8be40db3c71/comments/958.json`: Latest cached comment protects capture ownership against arbitrary stop redirection; its assertion that intent parameters remain missing is superseded by current code. Source log labels must not be mistaken for persisted History tags.

**Dependencies**

- #1013: existing intent parameters; no duplicate implementation here.
- #1015: existing gallery and destination-composition recipes.
- #954/#957: existing Control and hardware-trigger setup copy.
- #1019/#1025: capture URLs and ownership; do not broaden destination authority or restore Send to Mac.

**Verification**

- Record device, OS, build/commit, provider, permission state, selected History Only destination and exact fresh setup steps.
- Use synthetic clipboard sentinel; prove recognisable speech reaches History after manual stop, microphone capture ends and sentinel remains unchanged.
- Repeat while already recording and after a cold launch; Start must not toggle off capture and stop must remain reachable.
- Observe locked, unlocked, screen-on and screen-off separately before advertising supported states; permit an accurately labelled unlocked-only recipe.
- Record any confirmation, unlock or foreground continuation, then disable/delete test automation. Only then implement and follow the resulting copy on the same advertised device/OS.

**Risks and limits**

- No physical-device verification supplied or performed. Native builds and simulator checks cannot satisfy this product-specific gate.
- Current destination parameter implementation was identified, not exhaustively audited for cross-surface ownership interleavings.
- Do not infer shared-shortcut installation installs a device-specific personal automation.
- Beads CLI absent per parent context; this JSON is review evidence only.

## #959: iOS: defer AirPods-triggered priming and background hands-free arming

Reviewer: `/root/issue_review_queue/review_959`.

**Smallest worthwhile scope:** No implementation from #959 now. Run the existing explicit Start to Stop to verified History workflow on the target iPhone/AirPods across cold, warm, locked and suspended conditions. Reconsider only a distinct measured microphone-free preparation benefit after those results; background arming remains a separate product policy choice.

- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Already conforms to AudioRecordingIntent, LiveActivityIntent and ForegroundContinuableIntent; idempotently checks active/background and foreground ownership. Historic missing-conformance rationale is now covered.
- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: Arming requests microphone permission, configures recording audio and creates an AVAudioEngine input tap. Reusing this path cannot implement microphone-free preparation.
- `Sources/SpeakiOS/Views/ContentView.swift`: Routes scene state synchronously to sceneActivityChanged with explicit controlled-stop preservation comment for #942.
- `Sources/SpeakCore/AppleSpeechAnalyzerLiveSession.swift`: Builds its module, compatible format, analyzer and result task per session, then starts analysis. No retained readiness claim is established by this constructor.
- `/workspace/scratch/a8be40db3c71/comments/959.json`: No newer issue comments override the supplied evidence gates.

**Dependencies**

- #953/#932 existing Start/activity corrections must be assessed on physical iPhone first; conformance already present.
- #977 owns generic analyzer preparation; #938 owns asset preparation.
- #942/#943 retain scene-exit preservation and explicit re-arm; #935/#936 own route/interruption settlement.
- #958 owns automation guidance; #980 owns route preferences.

**Verification**

- Record device, OS, app revision, AirPods, model/locale, permissions, route, actual prompts and verified saved transcript.
- If a distinct priming need survives: repeated same-route primed/unprimed measurements, first captured audio versus first result, post-suspension fallback, idempotence and truthful invalidation after process/model/route changes.
- Any future background arming requires explicit opt-in policy, visible actual listening, reachable Stop, enforced expiry, controlled settlement and route/call/Siri/process-loss device evidence.

**Risks and limits**

- No physical device measurements or native build performed; source inspection does not prove locked capture, Bluetooth automation or retained analyzer readiness.
- Do not infer in-ear/disconnect triggers, latency savings, resource cost or App Review acceptance.
- Do not add Prime/Arm intents, background modes, model downloads or shared-engine changes under this disposition.
- Beads CLI absent per supplied review context; this JSON is temporary decision evidence.

## #960: iOS: defer calendar-scheduled Live Activity pending need and device evidence

Reviewer: `/root/issue_review_queue/review_960`.

**Smallest worthwhile scope:** No implementation now. Document one concrete opt-in scheduled-meeting use case and compare the current Start/Lock Screen Control journey on a physical device. Only if a distinct benefit remains, request a bounded scheduling policy/prototype decision. Do not fold an idle Start button, EventKit infrastructure or automatic microphone capture into this review.

- `Sources/SpeakCore/TranscriptionActivityManager.swift`: Current code requests immediate activities, adopts only active candidates, and isolates async updates by recording run. The historical #932 lifecycle deficit is already repaired in source; scheduling is not its repair.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Existing idempotent Start conforms to AudioRecordingIntent, LiveActivityIntent and ForegroundContinuableIntent. Narrow foreground retry already exists for liveActivityUnavailable, so new calendar-specific start identities would duplicate it.
- `JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtensionLiveActivity.swift`: Recording/listening states expose Stop; result states expose result actions. An idle Start button is a distinct smaller proposal, not grounds to authorise calendar integration.
- `Sources/SpeakiOS; Sources/SpeakCore; Project.swift; SpeakiOSApp`: Targeted search found no EventKit, EKEvent or NSCalendars integration. Calendar scheduling entails a new feature boundary.
- `/workspace/scratch/a8be40db3c71/comments/960.json`: No newer comments supersede the explicit need and physical-device evidence gates in the issue.

**Dependencies**

- #932 and #953 implementation changes are visible in current code; validate actual existing journey before reconsideration.
- #954 native Lock Screen Control is the calendar-free comparison path.
- #943 foreground ownership, #934 clipboard policy and #945 truthful outcomes remain constraints.
- #958 automation recipes and any idle Start/result-card expansion retain separate scope.

**Verification**

- Capture device, OS, build, provider, permissions and actual wake/unlock/foreground prompts for current Start and Lock Screen Control journeys.
- A future approved prototype must demonstrate foreground scheduling, background/locked pending-to-active transition, real alert behaviour, explicit Start, speech, Stop, persisted History and intended destination on a physical iPhone.
- Before shipping any future feature, verify denial/revocation, changed/cancelled meetings, duplicate refresh, disabled/dismissed cards, activity-cap/request failure, active capture isolation and cold-launch versus force-quit limitations.
- Retain explicit consent and event-title disclosure choices; never auto-start recording.

**Risks and limits**

- No physical-device timing, alert tolerance, demand or microphone evidence was collected; source inspection cannot establish those outcomes.
- Deferral is a product-value/evidence decision, not a blanket Linux limitation.
- Historical API references were supplied in issue context; this triage makes no newly verified Apple API guarantee.
- Beads CLI is reported absent in parent context; this JSON is interim review evidence, not task tracking.

## #961: iOS: defer repeated foreground auto-start pending ownership and activation policy

Reviewer: `/root/issue_review_queue/review_961`.

**Smallest worthwhile scope:** No implementation dispatch now. Re-enter only with an agreed ordinary in-app activation policy covering initial appearance, genuine background return, tab/deep-link intent and keyboard readiness; retain default-off opt-in, explicit command precedence and hands-free explicit re-arm. Close residual proposal if repaired launch capture removes its distinct value.

- `Sources/SpeakiOS/Views/ContentView.swift`: Current autoStartIfEnabled requires BOTH coordinator.state and backgroundService.state to be idle (1385–1393), improving the older isRunning-only evidence. Called from view task and onboarding dismissal; active-phase handler refreshes state and drains imports, without warm-return auto-start.
- `SpeakiOSApp/SpeakiOSApp.swift`: Current source now DOES contain the previously external capture command integration: URL, task and active transition invoke a drain that consumes the command before scheduling CaptureCommandRunner.perform asynchronously (172–179). A nil pending command check still cannot prove no dispatched command is in flight.
- `Sources/SpeakiOS/Views/ContentView.swift`: Scene changes synchronously notify hands-free ownership before foreground refresh (1134–1141), with comment preserving the #942 controlled-stop contract.
- `README.md; .copilot/skills/justspeaktoit-design.md`: Native, fast, privacy-conscious transcription and clear state favour predictable opt-in capture; no demonstrated warm-return benefit justifies weakening explicit recording intent.

**Dependencies**

- #943 ownership/settlement contract: existing dual-idle guard shows progress; do not duplicate repair
- #942 explicit hands-free re-arm remains binding
- #1025 command entry source is now present: stale issue text claiming absent code must be updated
- #935/#936 termination and interruption work remain separate

**Verification**

- Before code: establish concrete warm-return user journey and activation boundaries.
- If approved: orchestration tests for cold/warm entries, inactive flicker, already-dispatched commands, manual cancellation, teardown, onboarding and keyboard readiness; a pure policy test alone is insufficient.
- Apple-native build/lint/tests plus physical iPhone evidence for launch, lock/unlock, prompts, explicit Start/Stop/Toggle and hands-free/keyboard combinations with Apple and one remote provider.

**Risks and limits**

- Read-only source review cannot establish microphone or scene event ordering on devices.
- Do not treat historical speculative timing or dual-engine claims in comments as measured evidence.
- Deferral is due to product intent/ordering gates, not merely Linux execution limits.
- Beads CLI unavailable per supplied context; interim JSON is review evidence only.

## #962: iOS/watchOS: defer a separate wrist Control pending paired-device relay evidence

Reviewer: `/root/issue_review_queue/review_962`.

**Smallest worthwhile scope:** Run the issue's zero-source-change paired iOS 26/watchOS 26 experiment on an integrated build. If the existing control works, close as covered or add verified setup guidance under #954. If not, record whether discovery or phone capture fails, then plan only the demonstrated gap.

- `JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtensionControl.swift`: Existing toggle has a shared stable kind and reads SharedTranscriptionState for requested recording state.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Current intent already adopts LiveActivityIntent alongside AudioRecordingIntent and ForegroundContinuableIntent, checks foreground ownership, and classifies desired state idempotently. Historical prerequisite work is substantially present; protocol conformance alone does not establish actual Watch relay discovery.
- `Sources/SpeakiOS/Services/CaptureSurfaceRefresher.swift`: Phone widget and control refresh already exists. Duplicating it in this issue has no value and would not prove wrist refresh.
- `JustSpeakWatchShared/StartWatchRecordingIntent.swift`: Native Watch capture already uses a WatchRecordingCoordinator with a watchOS 10 foreground fallback, separate from relayed phone capture.
- `JustSpeakWatchWidget/WatchRecordingComplication.swift`: Existing Watch complication offers circular/corner recording actions; no need to recreate native Watch trigger capability here.

**Dependencies**

- #953/#932/#941 phone capture and control repairs must be in the physical test build; static inspection finds key intent and refresh changes present
- #1025 refresh overlap is already represented on current code
- #930 locked cloud-provider claims require credential verification
- #657 existing native Watch implementation must remain a separate scope
- #954 owns phone Control setup guidance
- Latest cached comment proposes a separate intent from presumed foreground filtering, but supplies no paired-device observations; current issue body explicitly rejects that assumption as sufficient evidence

**Verification**

- Record commit/build, OS versions, Watch model, permissions, provider and connectivity
- Verify existing Control discovery in Watch Control Center and Smart Stack; Ultra Action button only with real Ultra hardware
- Observe actual phone microphone capture, stop, activity lifetime, History and configured supported destination with warm/unlocked and cold/locked phone
- Verify phone-originated state changes reach wrist and requested state remains correct
- Check unreachable phone, denied microphone permission and disabled Live Activities produce truthful failure and no unintended capture

**Risks and limits**

- No physical paired-device evidence or native build performed; static code does not prove Watch discovery, microphone behaviour or relay reliability
- Do not remove phone foreground fallback or add a background-only control based solely on protocol conformance
- Do not restore Send to Mac, redesign routes, or duplicate native Watch capture
- Beads CLI unavailable as supplied; analysis JSON is not task tracking

## #963: Pinch to stop: a Double Tap primary action on the Live Activity in the watch Smart Stack

Reviewer: `/root/issue_review_queue/review_963`.

**Smallest worthwhile scope:** Opt existing iOS Live Activity into small family on iOS 18+, retain iOS 17 and medium/unknown fallbacks, and render concise explicit status. Add one visible accessible Stop button with primary-action gesture only in recording/listening, using existing intent. All other states have no enabled Stop/Start gesture. Reuse existing resolved completion wording; avoid copying private transcript text or timing primed-card age as capture duration.

- `JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtensionLiveActivity.swift`: Current ActivityConfiguration has no supplementalActivityFamilies, activityFamily branching or handGestureShortcut. Expanded Island and Lock Screen offer Stop only for recording/listening. Compact presentations lack a Stop control. Result rendering already uses TranscriptionResultRow.outcomeMessage; preserve that truthful completion contract.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Existing iOS 18+ AudioRecordingIntent/LiveActivityIntent is alwaysAllowed, finishes keyboard sessions via their existing path, preserves destination resolution, and explicitly refuses separately owned foreground recordings. Reuse without widening ownership.
- `JustSpeakWatch/WatchContentView.swift`: Native Watch UI already contains availability-guarded primaryAction modifier. This only supplies a local pattern; it does not implement the remote iOS Live Activity.
- `AGENTS.md; README.md; .copilot/skills/justspeaktoit-design.md`: Project prioritises rapid native dictation, privacy and truthful feedback; system controls, sparse semantic colour and accessible targets fit this scope.

**Dependencies**

- Coordinate changes in the shared Live Activity file with #945/#1001; current result rows already expose truthful outcome copy.
- Preserve #932 activity validity/run isolation and existing capture ownership contracts.
- Not dependent on native Watch activation #939, Watch triggers #964/#969, or deferred relayed Control #962.
- No new intent, transport, Watch provisioning, payload timer field or transcript preview.

**Verification**

- Build app plus embedded widget with Apple Xcode, verify iOS 17 compatibility and iOS 18+ guarded APIs; run affected existing tests and strict lint.
- Preview small/medium/fallback views across active and every non-active state, large text and accessible Stop targeting.
- Physical supported Double Tap Watch plus paired iPhone: independently verify tap and gesture while card visible and phone locked; actual microphone capture ends and final transcript reaches configured History/paste path. Record model, OS, build and relevant settings.
- Exercise repeated Stop, rapid restart, inactive card, connectivity loss, unavailable/dismissed activity, and existing foreground-owner refusal; retain phone Stop fallback.

**Risks and limits**

- Physical hardware qualification is mandatory before asserting remote Stop works; no device/build results were produced in this read-only Linux review.
- No guaranteed Smart Stack prominence, sleeping-display/locked-Watch gesture, zero-latency stopping or native Watch recording support.
- Current primary Apple documentation URLs were opened, but browser returned JS shells and Markdown-fetch errors; planner must verify exact API signatures and availability using the supported SDK/primary documentation. Supplied issue evidence is useful context, not new device proof.
- Beads CLI is absent per parent context; this JSON is interim review evidence only.

## #964: Watch-native triggers: App Shortcut (Siri), watchOS 26 Control, Ultra Action button, Double Tap stop

Reviewer: `/root/issue_review_queue/review_964`.

**Smallest worthwhile scope:** No implementation now. After existing native recorder baseline is proven, select one trigger for an explicit native-Watch capture need. A watchOS 26 Control can be the sole later adapter, reusing coordinator, queue and foreground fallback; Siri discovery and Ultra binding each need separate evidence. Exclude already implemented in-app Double Tap and bulk intent redesign.

- `JustSpeakWatchWidget/JustSpeakWatchWidgetBundle.swift`: Registers WatchRecordingComplication and WatchCaptureStatusWidget only; no native Control registration in this bundle.
- `JustSpeakWatchShared/StartWatchRecordingIntent.swift`: Existing watchOS 11 AudioRecordingIntent routes app implementation to WatchRecordingCoordinator.toggleRecording; watchOS 10 fallback opens the app. Extension implementation is intentionally split. These are toggle actions, not start-only actions; source assumptions about system recording indication still require device evidence.
- `JustSpeakWatch/WatchContentView.swift`: Record/stop button already applies watchOS 11+ handGestureShortcut(.primaryAction), so in-app Double Tap should be removed from residual scope.
- `review-input/964.md and comments/964.json`: Current issue explicitly defers new triggers until provisioned paired-device baseline acceptance; no later cached comments supersede that decision. README and AGENTS favour native SwiftUI and reliable capture.

**Dependencies**

- #657/#659: existing app/complication recording, wrist-down survival and durable delivery acceptance; do not reimplement their delivered intents/complication.
- #939: recording-entry connectivity activation; #940: transient import retry and retention.
- #963: separate approved Stop-only mirrored iPhone Live Activity/Double Tap, using phone microphone; do not block it on this proposal.
- #962 phone relay and #969 widget behaviour are separate proposals; #971 distribution enablement is not prerequisite to a valid development-device build.

**Verification**

- Record actual build/commit, Watch model, paired OS versions, permissions and observed process/foreground routing.
- Demonstrate app and complication start/stop, at least 60 seconds wrist-down with spoken markers, one durable capture and exactly one resulting iPhone History item, including reconnection retention/delivery.
- For a later selected trigger, verify Watch microphone capture, visible recording indication, repeat invocation, denied permission, stop and retained audio without silent success or duplicate recordings.
- Preserve watchOS 10 and default disabled Watch build paths; validate native build in Apple CI, and Control discovery or Ultra binding on relevant hardware.

**Risks and limits**

- No runtime, physical-device or Apple-framework build validation was performed; source inspection cannot prove microphone privileges, system recording indication or Siri routing.
- Supplied current issue documents watchOS 26 Controls as supported; this review neither rejects platform feasibility nor freshly revalidates platform documentation.
- Beads CLI is reported absent by parent context; this JSON is interim review evidence, not a tracker replacement.

## #965: watchOS: defer startup reorder and recording cues pending hardware evidence

Reviewer: `/root/issue_review_queue/review_965`.

**Smallest worthwhile scope:** No implementation now. Measure the existing provisioned development build, identify one reproducible latency or feedback problem, then plan only the change supported by those measurements. Close without code if no material problem appears.

- `JustSpeakWatch/WatchAudioRecorder.swift`: Serialises starts with isStarting, awaits finalisation, reconciles the active marker, requests permission, starts runtime and persists capture before record(). The proposed reorder is not already implemented and these waits protect ownership.
- `JustSpeakWatch/WatchAudioRecorder.swift`: Reads currentTime but also awaits inspectAudio before finalising; skipping asset inspection would remove validation.
- `JustSpeakWatch/JustSpeakWatchApp.swift`: Scene task already awaits recoverInterruptedCapture before pending watch-face requests.
- `Docs/watch-provisioning.md`: Native Watch is feature flagged; paired-device capture and complication acceptance remain unchecked.

**Dependencies**

- #657/#659 paired Watch baseline; #939 activation repair and #940 import retries where those entry cases are exercised.
- #964 shares the hardware baseline; #963 mirrored iPhone Stop is separate.
- #993/#1012 own duration/silence policy; do not add an arbitrary cap here.

**Verification**

- Record commit/build, device and OS versions, permissions and foreground/headless entry.
- Repeat cold/warm starts and distinguish permission, session, setup and record-return timing from actual opening speech retained.
- Check wrist-down spoken markers for at least 60 seconds, retained capture, rapid stop/start and eventual single iPhone History result.
- Any accepted change must retain single marker ownership, queue-before-clear, playable validation and interruption/termination recovery; require native builds/tests plus physical verification.

**Risks and limits**

- No native or device run was performed; source inspection cannot establish headless microphone activation or safe haptic readiness.
- Existing issue has no new comments or hardware evidence. Do not infer a 100–400 ms improvement or treat record success as proof of captured speech.
- Beads CLI is unavailable per supplied context; this JSON is read-only review evidence for parent integration.

## #966: iOS: defer background Watch uploads pending post-retry device evidence

Reviewer: `/root/issue_review_queue/review_966`.

**Smallest worthwhile scope:** No code implementation now. Gather post-repair paired Watch/iPhone evidence for repeatable captures that require foreground reopening; if demonstrated, separately qualify one affected supported batch endpoint and review its bounded background-transfer proposal while preserving the current fast path and selected provider.

- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift`: At inspected HEAD 51286c58c5117821fdd303f3aa06515166f97548, owned background expiration and transient network errors call recordTransientFailure; credential unavailability preserves the retry budget. The issue's older assertion that main charges expiration against attempts is stale.
- `Sources/SpeakCore/WatchCaptureImportJournal.swift`: Persists retry eligibility and exponential 30-second to 15-minute backoff without incrementing terminal attempts or resetting retention origin.
- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift`: Stable capture ID upserts History; durable History and journal completion precede audio deletion; failed acknowledgement delivery preserves pending acknowledgement for replay.
- `Sources/SpeakiOS/Services/IOSBatchTranscriptionClient.swift`: Multiple provider routes and provider-specific request building remain; background work cannot be justified as a simple generic session change.

**Dependencies**

- Validate #940 retry repair now present in code on paired physical devices; do not repeat obsolete PR-unmerged claim.
- #939 activation and #930 credential availability must work in provisioned feature-enabled development build.
- Native Watch baseline #964/#965; public release is not required for evidence gathering.
- Separate #967 chunking, #970 direct networking, #999 fallback and retention/duration proposals remain excluded.

**Verification**

- Record device, OS/build, provider/model, non-sensitive recording size/duration, app state, Wi-Fi/cellular, lock/power state, import start/expiration/completion, retry eligibility, eventual History and acknowledgement.
- Distinguish upload/provider processing, credentials, activation and owned expiration; compare short/long recordings and controlled slow network.
- Later implementation must recover task-to-capture association, reconcile tasks before retries, prevent simultaneous fast/background submissions, preserve audio on failure and yield one durable History row plus acknowledgement.
- Native builds and injectable regression checks cover code/state transitions; physical devices must prove suspension, system termination, locked access and relaunch outcomes.

**Risks and limits**

- No physical-device tests or OS-scheduling observations performed; inspected code is not a shipped/device-verified claim.
- Persisted eligibility does not itself arrange future background execution, so residual product value remains possible.
- Avoid fixed background-runtime, immediate completion, never-loss or exactly-once billing promises.
- Beads CLI absent per supplied context; decision file is review evidence only, parent owns tracker reconciliation.

## #967: watchOS: defer chunked capture transfer pending paired-device evidence

Reviewer: `/root/issue_review_queue/review_967`.

**Smallest worthwhile scope:** No implementation now. Measure the existing Watch-to-phone final-file handoff on provisioned paired hardware with short and multi-minute non-sensitive captures. Reopen a bounded design only if repeatable measurements identify a size-sensitive bottleneck and earlier usable text has clear user value.

- `JustSpeakWatch/WatchCaptureStore.swift`: Transport completion retains audio; transient transfer failures retry; only a durably persisted successful transcription acknowledgement permits audio deletion.
- `Sources/SpeakCore/WatchCaptureProtocol.swift`: Schema 1 describes a single capture and rejects future schemas; introducing chunk envelopes without compatible handling risks retained but stalled captures.
- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift`: Existing importer upserts History with capture ID and records success durably before deleting parked audio and replaying acknowledgement.

**Dependencies**

- Paired-device acceptance for #657/#659 and #964/#965 remains necessary.
- Baseline must account for #939 activation, #940 retries and #930 credentials.
- #966 background upload is separately deferred and is not a prerequisite.

**Verification**

- Record build/device/OS, duration/file size, lock and connectivity state, finalisation, transfer receipt, transcription, durable History and acknowledgement timings.
- A later chunk implementation must preserve ordered boundary words, one logical History item, recovery from missing/late/duplicate/out-of-order segments, safe mixed-version handling, and durable completion before audio release.
- Native CI and paired Watch/iPhone verification are required for a later implementation; static inspection is not device evidence.

**Risks and limits**

- No new measurements or physical-device tests were available; old latency/battery/effort estimates are not evidence.
- Do not change recorder engine, protocol schema, release flags, or retention based on this review.
- Beads CLI is absent per supplied session context; this JSON is review evidence only.

## #968: iOS/watchOS: defer Watch completion notifications pending paired-device evidence

Reviewer: `/root/issue_review_queue/review_968`.

**Smallest worthwhile scope:** No feature implementation now. Record the paired-device baseline and observe retrieval using History and the existing keyboard chip. Only if a distinct retrieval problem persists, reassess one opt-in generic notification that opens the matching saved History item for explicit Copy.

- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift`: Uses capture UUID as History identity; requires non-empty transcription and successful durable History persistence before commitSuccessfulImport. Current main now calls offerToKeyboard after committing and publishes via KeyboardDeliveryPublisher with source .watch; this supersedes the issue body implication that keyboard pickup is wholly absent. Optional polish follows.
- `Sources/SpeakiOS/Views/HistoryView.swift`: Saved rows already expose raw, polished and best-text Copy actions.
- `SpeakiOSApp/FeatureFlags.swift`: Watch capture remains disabled unless WATCH_APP_FEATURE is defined.
- `Docs/watch-provisioning.md`: Paired-device acceptance checklist remains unchecked, including eventual offline arrival, process termination, History visibility and Watch state progression.
- `comments/968.json`: Cached comment removes Send to Mac but proposes automatic copy using old retry semantics. Later issue refinement excludes that automatic copy; preserve the refined narrow boundary.

**Dependencies**

- #657/#659 paired-device baseline and wrist-down gate
- #939/#940 activation and retry, #930 credentials, #937 History recovery
- #1003 owns keyboard pickup; current import pipeline already publishes to it
- #934 clipboard semantics and #945 truthful outcome labels
- #952 removal direction excludes Send to Mac; #1017 broader automation is separate

**Verification**

- Record device/OS/build SHA, permission/lock state, capture entry point, durable History, eventual acknowledgement and offline reconnect behaviour.
- Observe current History Copy and keyboard pickup to establish an unmet need.
- If later approved, require capture-ID routing, non-empty durable result, opt-in and authorisation, no transcript preview, idempotence across replay/relaunch, and no import/acknowledgement dependency on notification success.
- Future notification work needs focused persistence/routing/idempotence tests, native builds and actual paired-device foreground/background/locked/unlocked validation.

**Risks and limits**

- Read-only static review; no physical-device or native runtime claims.
- Do not reintroduce automatic clipboard writes, Send to Mac, insertion, global result stores or a shared notification framework.
- Current keyboard publication is a code finding, not proof of reliable end-to-end delivery.
- Beads CLI is absent per task context; parent owns tracker updates and durable decision publication.

## #969: watchOS: defer native widget Double Tap and learned relevance pending evidence

Reviewer: `/root/issue_review_queue/review_969`.

**Smallest worthwhile scope:** No code now. After baseline evidence, independently reconsider only an availability-guarded primary-action gesture on the existing widget button, preserving intents, toggle serialisation, ordinary taps and watchOS 10 fallback. Reconsider learned relevance only after a demonstrated navigation problem and useful observed context; keep idle neutral in the meantime.

- `JustSpeakWatchWidget/WatchRecordingActionButton.swift`: Existing widget button selects StartWatchRecordingIntent on watchOS 11+ and OpenWatchRecordingIntent fallback on watchOS 10, with state-aware accessibility; no handGestureShortcut modifier.
- `JustSpeakWatch/WatchContentView.swift`: Recording control already invokes primaryActionGestureShortcut(), whose availability-guarded implementation applies handGestureShortcut(.primaryAction). The in-app gesture is already present.
- `Docs/watch-provisioning.md: Device checklist`: Watch targets remain feature-flagged; paired-device recording, transcript delivery, app/complication gesture and Smart Stack acceptance remain unchecked. An unchecked checklist provides no physical acceptance evidence.
- `/workspace/scratch/a8be40db3c71/review-input/969.md`: Explicit owner-compatible review separates widget gesture re-entry after #657/#659 baseline from speculative learned relevance; preserves neutral idle relevance. Cached comments contain no subsequent decision.

**Dependencies**

- #657 and #659 native Watch capture hardware baseline
- #939 activation correction; #940 repair for affected offline/import cases
- #963 accepted mirrored iPhone Live Activity Stop/Double Tap is a different surface and proceeds independently
- #964/#965 are not prerequisites for a later gesture-only change

**Verification**

- Record provisioned paired Watch/iPhone build, models, OS, permissions, foreground behaviour, app/complication start-stop, 60-second wrist-down spoken markers, durable capture and one eventual History result.
- If gesture re-enters, build both default and flagged targets with Apple Swift/Xcode; verify ordinary tap and Double Tap independently on supported physical hardware, repeated/cross-surface actions, permissions, stale state, Stop fallback and unavailable-gesture states.
- For learned relevance, demonstrate benefit beyond a pinned card/complication and observe actual placement; do not infer guaranteed rank or automatic presentation from source scores.

**Risks and limits**

- Read-only source review; no Apple-native build, microphone, physical Watch, delivery or usage study performed.
- Do not promise one gesture from the watch face or operation in unavailable gesture states.
- No analytics, new relevance store, location sensing, silence-stop, transport redesign, feature-flag or release change.
- Beads CLI is absent in the supplied environment; this JSON is review evidence, not a replacement task tracker.

## #970: watchOS: defer direct Watch uploads pending phone-absent device evidence

Reviewer: `/root/issue_review_queue/review_970`.

**Smallest worthwhile scope:** No code implementation now. First document one recurring phone-absent task, the destination where its transcript must be usable, and measured existing relay delay. Reconsider a single-provider explicit opt-in route only if this establishes material benefit and a secure credential/delivery design.

- `JustSpeakWatch/WatchCaptureStore.swift`: Transfers queue after activation without isReachable gating, avoid outstanding duplicates, retry failed transport, and retain audio after delivery until successful acknowledgement.
- `Sources/SpeakCore/WatchCaptureProtocol.swift`: Schema 1 transports capture metadata and outcome acknowledgement; transcribed is the only audio-release state. No transcript delivery contract for a direct Watch result exists in this protocol.
- `Sources/SpeakiOS/Services/WatchCaptureImportPipeline.swift`: Phone waits for credentials, selects the configured batch model, transcribes, and persists History under the capture ID before completion. Stable History identity does not establish exclusive provider submission ownership between Watch and phone.

**Dependencies**

- Physical paired Watch baseline #657/#659 with applicable #939 activation, #940 retry and #930 credential fixes.
- #966 phone background uploads, #967 chunking and #968 completion retrieval are separate deferred features, not mandatory implementation dependencies.
- No new release, CloudKit migration or credential-sync architecture is authorised.

**Verification**

- Record physical-device baseline with unavailable phone, relaunch, reconnection, one durable phone History result and eventual acknowledgement.
- Before implementation approval, demonstrate foreground and background Watch upload plus usable result at the chosen independent destination, including suspension, termination, poor connectivity, latency and power observations.
- Any later route must retain recovery audio/results on failure, persist task association across relaunch, prevent deliberately concurrent Watch/phone submissions, reconcile reconnection races, and provide truthful states with old-peer compatibility.
- Native Apple Swift builds/tests and physical Wi-Fi/cellular evidence are required for future acceptance; static review is not runtime verification.

**Risks and limits**

- No physical-device measurements or native builds were performed. Deferral follows missing user-outcome evidence and unresolved design decisions, not Linux availability alone.
- Ambiguous provider completion cannot promise exactly-once billing. A false isReachable value is not evidence of physical phone absence.
- Beads CLI is absent per supplied session context; this JSON is review evidence only. No repository edits or external posts were made.

## #971: watchOS: defer TestFlight rollout pending device baseline and tester need

Reviewer: `/root/issue_review_queue/review_971`.

**Smallest worthwhile scope:** No implementation now. Collect the existing baseline and tester/provisioning evidence. If a concrete TestFlight requirement emerges, separately plan a default-off Watch option through the current frozen release-manifest system and existing iOS worker, preserving coupled bundle/receiver gating.

- `Project.swift`: TUIST_WATCH_APP remains default-off and gates WATCH_APP_FEATURE alongside Watch inclusion. Existing manual profile hooks remain available.
- `.github/workflows/release-ios.yml`: Current worker accepts a frozen manifest only and shares release-ios concurrency. This is newer than the issue recipe describing manual keyboard/version/build inputs. Future Watch opt-in must fit immutable release-train manifest controls, not introduce an independent mutable worker input.
- `Docs/watch-provisioning.md`: Documents existing development-device generation, both Watch bundle ids/App Group, distribution signing hooks, and archive icon validation. Contains physical capture/complication/transfer verification checklist, not completed device evidence.
- `README.md`: Alpha commissioning and separate installation/data/credentials are explicit; main changes do not themselves justify distribution or Stable publication.

**Dependencies**

- #657/#659 paired-device baseline
- #939 activation, #930 credentials and #940 retry fixes need final state checked before hardware run
- Actual tester cohort and reason development-device path is insufficient
- Verified appropriate release-train Watch identifiers, App Group and both distribution profiles

**Verification**

- Record SHA/build, paired models/OS, permissions, lock/app/network state and observed outcomes for 60-second wrist-down capture, complication start/stop, durable iPhone History completion/ack, and reconnect delivery.
- If rollout is approved, validate default-off and explicit-on generated builds plus signed archive/export bundle identities, train-specific entitlements, profiles, versions/build numbers and icon.
- Verify processing, intended tester assignment and physical installation/capture separately; no release dispatch authorised by this review.

**Risks and limits**

- No supplied new baseline/cohort/provisioning evidence satisfies re-entry. Portal absence is not established.
- Cached comment icon/toggle corrections are respected: icon is present; disabling an unactivated phone receiver strands transfers but does not itself consume the import journal retry budget.
- Issue implementation recipe predates current manifest-only worker and must be revised if reopened.
- Static inspection cannot establish microphone/background/Watch behaviour; no native builds or device tests performed.
- Beads CLI absent per parent context; JSON is analysis evidence only.

## #973: iOS: defer mixable-first background activation pending device evidence

Reviewer: `/root/issue_review_queue/review_973`.

**Smallest worthwhile scope:** No implementation or planning dispatch now. Re-review after focused physical-device traces distinguish fresh background activation from retained keyboard handoff and identify a material refused-attempt cost or concrete user-visible failure. Limit any future selection rule to evidenced conditions.

- `Sources/SpeakiOS/Services/AudioSessionManager.swift`: Current code attempts non-mixable activation exactly once, then switches to mixable only for classified setActive cannotInterruptOthers. Cancellation checks remain before and after configuration. The source comment asserting guaranteed background refusal is not device evidence.
- `Sources/SpeakiOS/Services/AudioSessionDiagnostics.swift`: Default fallback has four attempts and 150 ms multiplied by attempt delays. Omitting initial isolated attempt does not remove fallback backoff.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Readiness uses measurement with mixWithOthers and allowBluetoothHFP. Handoff retains session activation while replacing readiness capture with recording. This differs from fresh background activation.
- `comments/973.json`: No newer issue comments provide timing or changed approval.

**Dependencies**

- #972 local startup diagnostics and physical-device baseline; not automatic approval for extra instrumentation
- #974 separate readiness/deactivation qualification; current isolated-first policy must remain intact
- #935/#936/#942/#943 disruption, finalisation, foreground and ownership guards

**Verification**

- Record phone, OS/build, backend, actual app state, readiness ownership, route, playback state and repeated sample counts; include foreground active/inactive controls.
- Verify real speech, final transcript destination/History, playback and capture quality, cancellation/failure cleanup and a successful restart on affected routes.
- If subsequent code is approved, inject tests for eligibility, isolated success, classified fallback, nonretryable failure and cancellation; Apple Swift/Xcode CI remains necessary.

**Risks and limits**

- No device timings, OS activation outcome or Bluetooth behaviour were validated here.
- Neither inactive app state nor a keyboard profile establishes that isolated activation must fail.
- Do not unify category policy, add activation caching or change ownership/deactivation as part of this issue.
- Beads CLI unavailable per intake context; decision JSON is review evidence only.

## #974: One audio-session configuration shared by readiness, detector and transcribers; caller-owned deactivation

Reviewer: `/root/issue_review_queue/review_974`.

**Smallest worthwhile scope:** First collect repeated local physical-iPhone readiness → capture → Stop & Insert → readiness evidence with actual route, category/mode/options, activation results and engine state. If a residual failure or material avoidable delay is demonstrated, plan only the affected transition using existing manager and run ownership. Do not dispatch unification or retention implementation now.

- `Sources/SpeakiOS/Services/AudioSessionManager.swift`: Recording intentionally attempts isolated measurement capture, falling back to mixing after classified activation refusal. Its options include Bluetooth, speaker default and A2DP; equalising these is policy change, not a constant extraction.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Handoff already claims recording and publishes the recording phase before stopping readiness with deactivateAudioSession false. Explicit endSession stops readiness with deactivation true.
- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Stop drains queued buffers and converter tail, finalises the client, then releases the audio session. Disruption routes through owner finalisation. Retention must respect those completion boundaries.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: One lifecycle seam covers batch, Apple, OpenAI and shared-client backends, including cancellation settlement and local startup observations from #972. A flag on only live backends would leave batch and asynchronous cleanup unaddressed.
- `comments/974.json`: No newer comments override the issue's explicit device evidence prerequisite.

**Dependencies**

- #972 baseline instrumentation is present in the session interface; actual device baseline remains required and aggregate startup observations alone do not establish stop-to-ready cost.
- #973 activation policy must be reconciled before editing the same manager.
- #935/#936 disruption and interruption handling and #943 ownership settlement may already explain or resolve candidate failures.
- Do not adopt #980 microphone defaults, #979 shared engine, or #995 readiness-policy changes through this issue.

**Verification**

- Compare repeated built-in and available Bluetooth route cycles with playback on/off; record backend/build/OS, capture samples, successful speech delivery, one insertion, History and return to readiness.
- For any later patch, cover live and batch normal completion, failed startup, cancellation settlement, disable during cleanup, failed readiness restart and stale cleanup versus a newer owner.
- Use Apple Swift/Xcode builds and focused lifecycle tests, then physical-device interruption, route removal, playback and microphone checks. Do not infer latency or Bluetooth behaviour from mocks.

**Risks and limits**

- Read-only review of five targeted excerpts; no native build or physical-device measurements.
- No numeric latency claim is justified.
- isConfigured and equal options do not prove that system activation is usable or owned.
- Preserve explicit consent/reconnect, idle-audio discard and provider-traffic boundaries; a shared policy must not broaden listening.
- Beads CLI absent per supplied context; this JSON is temporary review evidence only.

## #975: iOS: defer credential startup optimisation pending residual-wait evidence

Reviewer: `/root/issue_review_queue/review_975`.

**Smallest worthwhile scope:** No implementation now. Collect repeated cold/warm foreground, headless and keyboard starts with explicit Apple and configured remote routes; isolate residual credential wait if aggregate diagnostics cannot attribute it. Re-review only an evidenced credential-only remedy.

- `Sources/SpeakiOS/Views/SettingsView.swift`: Bootstrap already starts asynchronously; recording callers share keyLoadTask; successful credentials are reused, failed loads remain retryable, and default-provider selection occurs after loading. Local models can run when secure loading is unavailable.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Reload reuses canonical SecureStorage, preserves existing values through syncedAPIKeyValue, and publishes availability only after provider fields load.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Current main waits for credentials before model resolution, logs credentialsReady, then revalidates foreground ownership and run identity before resource allocation. Startup watchdog already covers the credential wait.
- `Sources/SpeakCore/SecureStorage.swift`: Public lookups use ensureCacheLoaded and cached values; keychain accessibility has a real readback diagnostic. Number of provider calls alone is not keychain cost evidence.
- `Docs/ios-startup-diagnostics.md`: Existing diagnostic definition measures entry to credential-wait completion; it does not by itself isolate residual wait.

**Dependencies**

- #972: physical-iPhone timing and attribution prerequisite; instrumentation alone is insufficient.
- #930: current retryable loader and local/unavailable semantics are now present in main; measure this implementation rather than the obsolete pre-PR snapshot.
- #932/#943 and existing run lifecycle: preserve activity-before-audio, foreground ownership, cancellation and provider labels.

**Verification**

- Record build/device/OS, entry surface, selected and actual model, mode/profile, permission and lock state plus individual samples.
- If a remedy is approved, exercise first-launch default selection, explicit local/remote routes, profile and batch overrides, delayed success/failure, retry, key rotation/reload, cancellation and stale bootstrap completion.
- Use native iOS CI/tests plus physical capture, History/destination and restart checks; show before/after latency without invented thresholds.

**Risks and limits**

- No physical-device measurements supplied; this is an evidence-based deferral, not a Linux build deferral.
- Exclude audio-session hoisting/caching, concurrent activity startup, new decoders, permanent migration flags or speculative parallel lookups.
- Beads CLI is absent per supplied context; no tracker changes or external posts performed.

## #976: iOS: defer capture before SpeechAnalyzer setup pending residual-gap evidence

Reviewer: `/root/issue_review_queue/review_976`.

**Smallest worthwhile scope:** Collect repeated cold/warm prepared-asset iPhone baselines by actual backend, route, surface and known opening speech. Re-review an iOS analyzer-only bounded capture/drain change only if a material setup gap or attributable opening-word loss remains. Do not dispatch an implementation planner for capture reordering now.

- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Current startup uses assetPolicy .installedOnly and awaits session creation before tap, recorder, pre-roll conversion and engine start. Cancellation never falls back; analyzer failure tears down the tap and session before permitted legacy startup.
- `Sources/SpeakCore/AppleSpeechAnalyzerLiveSession.swift`: Module creation, compatible-format discovery and analyzer.start are awaited; AsyncStream input buffering has no explicit bound. Initializer cancellation finishes the stream, analyzer cancellation and result task.
- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Actual analyzer backend and engine-return stage are reported; first-input callback is capture-ID guarded. Stop still returns until isRunning; Cancel cancels startup, stops input, drains processing and discards recording. A reorder must explicitly cover pending-start Stop and preserve these ownership guarantees.

**Dependencies**

- #938 installed-only startup is present in main; residual measurements must use this implementation.
- #972 startup diagnostics; engine return and first-input callback do not alone attribute module/format/setup latency.
- #932 required activity before capture; #935/#936 controlled termination; #948/#950 finalisation and loss reporting remain constraints.

**Verification**

- Baseline evidence must include captured/saved opening audio, transcript opening and final words, device/build/OS, route, sample counts and setup timings, with legacy fallback separate.
- If later approved, delayed-analyzer ownership tests must cover ordered bounded drain, supplied pre-roll once, pool ownership, overflow, format mismatch, Stop/Cancel during setup, fallback, interruption and immediate restart.
- Native iOS build and affected tests plus physical installed-assets iPhone comparison required; Bluetooth cases remain unverified when hardware unavailable.

**Risks and limits**

- Static review establishes ordering, not latency or physical microphone behaviour. No device measurements were supplied or performed.
- A finite parking queue alone would not bound downstream AsyncStream retention; unsafe reordering could lose opening speech, exhaust the tap pool or leak the microphone.
- Beads CLI absent per parent context; review JSON is analysis evidence only. No repository edits or external posts.

## #977: iOS: defer warm SpeechAnalyzer sessions pending latency and resource evidence

Reviewer: `/root/issue_review_queue/review_977`.

**Smallest worthwhile scope:** Keep the optimisation candidate deferred. First collect repeated installed-model physical-iPhone startup measurements with build/device/OS, locale, backend, input route, process residency and sample counts. Use existing observations, adding focused local instrumentation only if it is needed to isolate residual analyzer construction/preparation cost. Re-review preparation or retention options only after a material delay and resident repeat-start use case are demonstrated.

- `Sources/SpeakCore/AppleSpeechAnalyzerLiveSession.swift`: Each initializer builds a module and a SpeechAnalyzer, binds a per-run result callback and starts analysis. finish finalizes through end of input; cancellation joins native teardown. This is an active run-bound session, so pooling would require a deliberate lifecycle change.
- `Sources/SpeakCore/AppleSpeechAnalyzerTranscriber.swift`: Asset policy is enforced through AppleSpeechAssets.ensure and a use-time AssetInventory status query; download is isolated behind the installation closure.
- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Current iOS creation explicitly uses installedOnly, awaits session construction before tap/engine startup, guards callbacks with activeCaptureID, reports engine start and first observed input, and tears down on failure. This establishes a possible critical-path cost, not its measured size.
- `comments/977.json`: No later comments provide performance or memory evidence or change the previous disposition.

**Dependencies**

- #938 explicit asset preparation and installed-only startup baseline
- #972 local startup diagnostics; attribute residual cost before choosing a remedy
- #976 capture-before-analyzer is a separate deferred alternative, not a prerequisite
- #978/#979/#984/#986/#987 are related resource/readiness proposals; avoid independently adding retained ownership

**Verification**

- Evidence baseline must separate process-cold starts, resident repeat starts, engine-start return, first input and controlled-speech first partial; verify opening and final words and saved History/audio.
- Any subsequently approved retention design must retain authoritative installed-only checking, capture identity, cancellation and Stop/restart guarantees; never reuse finalized sessions.
- Measure candidate idle memory/resource behaviour, lifecycle transitions, locale/route changes, interruption, cancellation and restart on a physical iPhone. Define improvement/resource criteria from baseline before implementing retention.
- Native iOS destination tests and compile, strict lint, and shared/macOS checks for shared API changes; Linux static review cannot establish microphone or resource behaviour.

**Risks and limits**

- No physical-device benchmark or measured latency/resource budget is available in the supplied evidence.
- No warm pool, automatic re-priming, process-lifetime retention, microphone activation or model download is approved by this review.
- Beads CLI is absent per supplied project context; this JSON is interim review evidence only.

## #978: iOS: defer keyboard readiness pre-roll pending opening-audio evidence

Reviewer: `/root/issue_review_queue/review_978`.

**Smallest worthwhile scope:** Keep implementation deferred. Reproduce opening-word loss on a physical iPhone with the current build and known phrases, then attribute loss to pre-request/pre-stop, engine gap, capture or provider. If existing diagnostics cannot attribute it, separately review a local content-free timing/frame trace. Re-review only a demonstrated affected backend after explicitly agreeing retention and eventual cloud-processing policy.

- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Current handoff stops readiness with deactivateAudioSession:false before recordingService.startRecording. Readiness tap deliberately discards buffers; stop removes the tap. Pre-stop snapshots cannot recover audio during the subsequent gap.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: Only Apple receives supplied pre-roll; batch, OpenAI and shared backends start without it. A generic parameter is not all-backend support.
- `Docs/ios-keyboard-instant-dictation.md`: Documents immediate idle-buffer discard, no transcription/upload/persistence and a return to discard-only readiness. Also explicitly acknowledges insertion is not atomic across extension termination.
- `comments/978.json`: Cached live comments are empty; no later evidence or approval supersedes the issue gate.

**Dependencies**

- #972 local startup diagnostics: timing evidence only, not proof of first usable audio or recovered words.
- #938 current installed-only Apple startup should be included in baseline.
- #976 analyzer startup and #984 hands-free timing are distinct scopes.
- Preserve handoff identity/cancellation/finalisation contracts from #933, #935/#936 and #948–#950.

**Verification**

- Record build, device/OS, backend, preparation state, actual route and repeated sample counts. Compare captured known phrases and transcript without retaining unrelated idle speech.
- If buffering is subsequently justified, require finite frame/time and byte bounds, format handling, exactly-once replay per request, lifecycle clearing, cancellation/stale-callback tests and recording/History consistency.
- Native compilation/tests and physical iPhone comparisons across built-in and available Bluetooth routes must establish opening/final-word preservation and matching-document insertion. Do not claim exactly-once insertion across extension termination without fixing that separate known limitation.

**Risks and limits**

- No device reproduction or audio measurements were supplied or performed; static ordering cannot establish speech loss or recoverability.
- Memory-only retention can still transmit pre-request speech when replayed to a cloud provider. Existing readiness consent does not establish consent for that behaviour.
- Do not import a pre-roll buffer with assumed duration bounds, invent fixed duration/latency gains, or add parallel engines/all-backend queues.
- Beads CLI is absent per parent context; this JSON is review evidence, not task tracking.

## #979: iOS: defer shared capture engine pending residual device evidence

Reviewer: `/root/issue_review_queue/review_979`.

**Smallest worthwhile scope:** No implementation now. Repeated physical-iPhone measurements should isolate one residual keyboard handoff delay/opening-word loss or hands-free concurrent-engine failure, then establish why a smaller manager/backend correction cannot resolve it. Only then plan the affected path; exclude process-wide fan-out, launch microphone startup and all-backend migration.

- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Claims recording before stopping readiness with deactivateAudioSession:false, then starts transcription; this avoids heartbeat misclassification and retains session activation across the existing engine swap.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: Four distinct backend types, including batch, deliberately own recording implementations; migration scope cannot safely assume only streaming providers.
- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Native capture format is converted to the route-specific sample rate; pooled buffers are copied before serial processing and recycled afterward. Writer starts before tap; first usable input and engine return are separate observations.
- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: Hands-free starts capture with a pre-roll snapshot under session identity; detector shutdown and utterance settlement have explicit controlled-stop ownership. This is an investigation target, not evidence of a two-engine defect.

**Dependencies**

- #972 startup diagnostics are an evidence source, not approval for engine sharing.
- #938 Apple preparation and #935/#936 disruption handling should be included in the measured baseline.
- #974 and #976–#978 are separate evidence-gated candidates, not prerequisite implementations.
- #933/#942/#943 keyboard settlement, scene and foreground ownership must remain intact.

**Verification**

- Record build/device/OS, provider and fallback, permission/preparation state, route and playback state, repeat counts, first usable input and provider readiness separately.
- If later approved, behaviour tests must cover ownership handback, supported formats, buffer lifetime, cancellation/Stop races, late callbacks, teardown and immediate restart; Apple toolchain/iOS destination required.
- Physical baseline/candidate checks must verify opening/final words, retained recording, History, keyboard exactly-once insertion where relevant, Bluetooth/interruption changes, terminal microphone release and discarded idle audio.

**Risks and limits**

- No new device benchmark or ownership-attributed failure was supplied; static inspection does not establish latency savings or hardware continuity.
- A prepared engine is not running capture, and retaining resources is not proven free.
- Read-only review; no repository edits, external posts, native tests or device tests. Beads CLI is absent per review context.

## #980: iOS: defer Bluetooth microphone defaults pending device evidence

Reviewer: `/root/issue_review_queue/review_980`.

**Smallest worthwhile scope:** No source changes now. Run a focused physical-device baseline with intended microphone recorded, foreground starts and already-enabled keyboard handoffs, known opening/final speech, playback on/off and actual input/output ports. Re-review a small explicit opt-in only if a meaningful residual problem survives existing lifecycle fixes.

- `Sources/SpeakiOS/Services/AudioSessionManager.swift`: Recording uses playAndRecord and measurement with Bluetooth, defaultToSpeaker and A2DP options; successful setup already logs input route. No evidence here establishes actual Bluetooth startup delay or preferred acoustic input.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Readiness stops with deactivateAudioSession false before capture; cannot assume each keyboard handoff negotiates a fresh Bluetooth session.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Readiness explicitly configures measurement mode with mixWithOthers and allowBluetoothHFP. Changing only capture policy could introduce a route transition.
- `README.md; AGENTS.md; .copilot/skills/justspeaktoit-design.md`: Native reliable transcription, privacy and clear tradeoffs favour preserving deliberate headset choice until an app-specific defect and bounded remedy are demonstrated.
- `comments/980.json`: No later comments override the explicit evidence gate in the current issue body.

**Dependencies**

- #972 startup measurements are qualification evidence, not microphone-policy approval.
- #935 route disruption handling and #938 Apple preparation should be accounted for before attributing residual loss to Bluetooth.
- #974 and #979 remain deferred; neither is an implementation prerequisite.
- #989 silence-triggered fallback is excluded: silence does not establish microphone failure.

**Verification**

- Record build, OS, phone/accessory models, backend, preparation state, sample counts, actual acoustic input and opening/final word preservation.
- Measure session setup separately from engine start, usable speech and provider output. Do not infer acoustic success from route labels or nonzero buffers.
- If a remedy is later approved, preserve headset defaults/choice, unavailable-route behaviour, cancellation and controlled-stop handling; compile and run affected iOS tests on Apple tooling.
- Require physical iPhone comparisons for supported accessory/OS combinations including stowed-phone use, playback, route removal, interruption, release and the next start.

**Risks and limits**

- No physical-device test or Bluetooth latency measurement performed; static inspection cannot verify routing quality.
- No production silence detector, silent reroute, entry-point microphone inference, generic logger or new settings UI justified.
- Beads CLI is absent per parent context; this JSON is interim review evidence, not task tracking.

## #981: iOS: defer cloud socket overlap and endpoint warming pending device evidence

Reviewer: `/root/issue_review_queue/review_981`.

**Smallest worthwhile scope:** First collect repeated current-build iPhone traces separating audio configuration, connect initiation, provider readiness and first partial visible to the user. Reconsider only an after-permission, owned-start overlap if configuration is a material contributor. Assess a bounded credential-free eligible-provider probe independently; no implementation dispatch now.

- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Current startup validates key/client, awaits permission, checks cancellation, acquires audio ownership, awaits configuration, then starts the client and capture. The entire operation has failure cleanup. Reordering would expand asynchronous error exposure across an await; resetState still follows capture start.
- `Sources/SpeakiOS/Services/OpenAIRealtimeLiveTranscriber.swift`: OpenAI uses RecordingStartupOperation failure cleanup and owned audio setup, with injectable capture/client seams. A reorder requires explicit lifecycle tests rather than assuming buffering is universally safe.
- `Sources/SpeakCore/LiveStreamWarmUp.swift`: Shared policy deliberately disallows speculative authenticated preconnection and excludes Apple, AssemblyAI, OpenAI and Azure endpoint probes. Tracker already exists; no new shared architecture is needed.
- `Sources/SpeakApp/StreamingEndpointWarmer.swift`: macOS warmer sends credential-free HEAD / and accepts an HTTP response. This is not evidence of iOS socket readiness, connection reuse or visible latency improvement.
- `comments/981.json`: Latest correction confirms existing cleanup covers configuration throws after audio ownership; permission must remain before authenticated socket start. No new device evidence is present.

**Dependencies**

- #972 startup diagnostics and physical-iPhone cold/warm baseline
- Coordinate startup ownership with #930, #935, #936, #942, #943
- #947 opening-audio investigation, #949 OpenAI overflow and #950 capture-loss reporting remain separate

**Verification**

- Baseline/candidate measurements must include device/build/model, entry surface, permission/network/input route, sample counts and known immediate speech.
- If overlap is justified, test configuration/engine failure, early provider error, cancellation and rapid replacement; started clients must close, resources release, stale callbacks be ignored and errors never reset into false success.
- If warming is justified, demonstrate repeatable iOS benefit with actual sessions, bounded request count, host/redirect checks and network/resource cost.
- Run affected Apple Swift/Xcode tests/builds and strict lint for a future code change; OpenAI authenticated changes also need live API validation.

**Risks and limits**

- No physical-iPhone timing, microphone integrity or transport tests were performed; Linux static inspection cannot establish them.
- No idle authenticated session, background/timer probes, keyboard extension networking, blanket buffer redesign or release is authorised by this issue.
- Beads CLI is reported absent in supplied context; this JSON is analysis evidence only, not a replacement tracker.

## #982: iOS: defer tap and I/O buffer tuning pending device evidence

Reviewer: `/root/issue_review_queue/review_982`.

**Smallest worthwhile scope:** No implementation dispatch now. Collect a bounded physical-iPhone baseline for a specific first-partial delay or reproduced audio gap; only then separately review a single-backend candidate. Do not impose universal 2048 frames, a process-wide 20 ms preference, or a four-to-eight pool increase.

- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: Requests 4096-frame tap; copies actual buffers through recordingLoss, observes first non-empty input, processes off the audio thread and emits engineStarted only after start returns. Safety writer starts before capture. These mechanisms expose readiness/loss but do not establish callback timing or useful transcript gains.
- `Sources/SpeakiOS/Services/PCMBufferPool.swift`: Bounded allocations include in-flight buffers; copy uses actual frameLength and exhaustion is counted. No basis for automatically doubling the pool.
- `Sources/SpeakiOS/Services/AudioSessionManager.swift`: Shared process audio session has foreground/background activation fallback and route update. Adding an unconditional buffer-duration preference would need explicit session ownership/restoration and actual-value measurement.

**Dependencies**

- #972 startup diagnostics: use existing observations to identify a concrete residual question; neither those observations nor the newer first-input signal constitute a physical benchmark.
- #950 capture/persistence-loss reporting and existing pool tests must be reused.
- #983 first-input UX is distinct from tuning; preserve existing capture signal.
- Stop/finalisation/ownership changes #935/#936/#942/#943/#948/#949 must remain intact.

**Verification**

- Record build/device/OS, backend, surface, cold/warm state, route categories, actual frame sizes/sample rates, callback timing, actual post-activation I/O duration, and engine-start boundaries; correlate with first useful visible partial or reproduced loss.
- Compare baseline and one candidate at a time using repeated known spoken phrases, opening/tail audio, saved recording and History; include relevant Bluetooth/readiness/accessibility cases.
- If a candidate earns implementation, require variable-buffer, queue-pressure, stop/drain and restart coverage, affected provider framing checks, strict lint, Apple native compilation and physical-device regression evidence.

**Risks and limits**

- Smaller requested buffers do not prove earlier useful text; provider framing, CPU/energy pressure and lost audio can dominate.
- No physical microphone test or benchmark performed; Linux/static inspection cannot establish latency, battery, Bluetooth or OS workaround claims.
- Keep diagnostics numeric, bounded, run-scoped and off the real-time thread; no audio/transcript/vendor telemetry.
- Beads CLI unavailable per parent context; this JSON is review evidence only, not a replacement tracker.

## #984: iOS: defer hands-free pre-roll handover changes pending audio-coverage evidence

Reviewer: `/root/issue_review_queue/review_984`.

**Smallest worthwhile scope:** Evidence qualification first: controlled physical-iPhone utterances with prepared Apple assets, identifying initial prefix, setup detector frames and first capture frames. If residual opening loss is demonstrated, commission a bounded Apple hands-free handover design with explicit audio ownership, format handling and overflow outcome. Close the candidate if no defect remains.

- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: Still drains preRoll.takeSnapshot() before awaiting startCapture; current session identity guard and captureIsStarting protect ownership but do not transfer subsequent detector buffers.
- `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`: Detector tap still appends to preRoll; its append is independent of the snapshot passed into capture startup.
- `Sources/SpeakCore/HandsFreeAudioPreRollBuffer.swift`: Rolling retention evicts oldest whole buffers; snapshot drains atomically. Moving the only snapshot later can evict the original speech prefix during a long setup.
- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Current baseline now uses installedOnly assets and cancellation check. It converts supplied pre-roll using capture-engine source format and sends it to analyzer before starting the independent engine. Supplied pre-roll is not written to audioRecorder; writer startup alone does not provide recording coverage.
- `/workspace/scratch/a8be40db3c71/comments/984.json`: No comments supersede the issue evidence gate.

**Dependencies**

- Reassess using current #938 installed-only startup, now visible in code, plus #935/#936/#942/#943 lifecycle ownership baseline.
- Use #972 local startup diagnostics where helpful; #983 readiness presentation cannot establish buffer continuity.
- Keep #976/#977/#978/#979 separate; no engine sharing, warm analyzer pool, or provider-wide pre-roll expansion.

**Verification**

- Record actual build, device, OS, locale, input route and repeated baseline observations on built-in and available Bluetooth input.
- Any later fix needs identifiable PCM tests across a startup delay longer than the rolling window, exactly-once in-order delivery, incompatible formats and finite retention overflow.
- Verify cancellation/disarm, scene exit, interruption, route disruption and immediate rearm isolate retired runs.
- Compare transcript and saved recording separately, including opening/final words, duplicate avoidance, History and terminal microphone release; run Apple Swift/iOS compilation and affected tests.

**Risks and limits**

- No physical-device audio coverage evidence was supplied or collected; static inspection cannot measure missing words or latency benefit.
- Deferral is due to the unresolved handover evidence/design gate, not merely Linux compilation limits.
- No source changes, native builds or external posts performed. Beads CLI is absent per supplied context; this JSON is analysis evidence only.

## #985: iOS: defer cold-launch pruning pending attributed device evidence

Reviewer: `/root/issue_review_queue/review_985`.

**Smallest worthwhile scope:** No code change now. Measure repeated comparable cold Action Button and ordinary launches with warm controls; attribute any residual delay to one nonessential operation, then re-review only that operation. Close with evidence if no material removable cost remains.

- `SpeakiOSApp/SpeakiOSApp.swift`: Launch clears stale state before capture, registers push, activates enabled Watch receiver, and schedules asynchronous CloudKit-key work. Push routing now also reconciles History independently under a background task, reinforcing the need to preserve non-recording launches.
- `SpeakiOSApp/WatchCaptureReceiver.swift`: Activation triggers durable pending-import and acknowledgement reconciliation. Delaying activation until capture or foreground could strand background-delivered Watch work.
- `Sources/SpeakCore/SecureStorage.swift`: Secure actor maintains a cache and explicitly coalesces initial Keychain loading. Multiple awaits alone do not demonstrate repeated expensive master-payload reads.
- `Sources/SpeakiOS/Views/SettingsView.swift`: Credential availability affects initial provider choice while explicit remote selection must remain stable; startup optimisation must preserve these correctness rules.

**Dependencies**

- #972 physical-iPhone measurements first; focused attribution beyond its app-entry checkpoints if residual launch cost remains
- #930 credentials and #931/#932/#943 integrated lifecycle readiness
- #975 retains residual credential optimisation; #973/#974 retain activation-policy gates
- #1007 History push reconciliation and Watch durable import/acknowledgement paths must remain independent of recording

**Verification**

- Record build/device/OS, entry surface, lock state, selected and actual backend, permission/model readiness, route, Watch flag, CloudKit configuration and sample counts.
- Any later approved change needs physical before/after latency measurements plus first words, final transcript, single History/destination result, cancellation and restart.
- Verify headless/background and non-recording launches, failed starts, CloudKit credential propagation and History push handling; paired Watch import must reach durable History and acknowledgement.
- Run affected Apple-toolchain iOS build/tests and repository gates for a future change; simulator/static results cannot establish device latency or background delivery.

**Risks and limits**

- No physical device trace or benchmark is available; previous 20–150 ms estimate is unsupported.
- Do not infer hot-path blocking from asynchronous launch-task presence or use missing scenes/application state as an Action Button detector.
- Exclude engine-thread migration, generic scheduling coordinators, pre-roll/warm windows and credential-store rewrites.
- Beads CLI absent per supplied context; this JSON is interim review evidence, not a replacement tracker.

## #986: A warm window after every dictation: prepared engine, preheated analyzer and cached keys

Reviewer: `/root/issue_review_queue/review_986`.

**Smallest worthwhile scope:** First qualify repeated-start phases for ordinary dictation and already-enabled Instant Dictation separately. If preparation is materially costly, retain only the measured non-recording resource with explicit expiry and invalidation. Do not add a universal running-microphone window or pre-roll ring as part of this issue.

- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Readiness is already checked once per second against bounded lifetime and running-engine health; recording handoff is explicitly excluded from idle expiry.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: A retained AVAudioEngine actually runs with an input tap and discards idle audio while readiness is enabled; stop can deactivate AVAudioSession. This differs from merely prepared objects and would expose the microphone indicator.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Current handoff stops readiness without audio-session deactivation and starts the recording owner, with recovery after failure. Blanket warm-window logic risks competing with existing ownership.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Stop preserves startup cancellation, reentrancy protection, transcript draining and background finalisation; resource-retention changes must respect these newer lifecycle guarantees.
- `Sources/SpeakiOS/Services/IOSTranscriptionSession.swift`: Backend objects and key configuration are constructed per resolution; inspection alone does not show which preparation stage dominates repeated-start latency.
- `/workspace/scratch/a8be40db3c71/comments/986.json`: Latest cached direction explicitly requires latency/resource measurements and defined cleanup before implementation, and excludes an incidental recording ring.

**Dependencies**

- #977 warm analyzer, #979 shared engine, #978 readiness overlap; coordinate ownership and qualification rather than implement separately.
- Repeated-start instrumentation and real-device idle battery/memory measurements after approved asset/lifecycle fixes.
- Existing bounded readiness and recovery behavior associated with #995 must remain authoritative.

**Verification**

- Record cold and repeated-start latency distributions by provider and entry surface, with equivalent first-word preservation checks.
- Compare baseline versus candidate idle energy, memory and microphone indicator behavior on real iOS devices, including background suspension.
- Define and verify expiry, user opt-out, interruption, route change, provider/model/key change and memory-pressure cleanup before coding retention.
- Verify final transcript delivery, startup cancellation and existing readiness handoffs do not regress. Prepared resources must never be represented as guaranteed background execution or guaranteed Live Activity readiness.

**Risks and limits**

- No device latency, battery or background-liveness measurements were supplied; claimed sub-200 ms starts and guaranteed activities remain unproven.
- Audio buffering while idle changes privacy behavior even without persistence or network transmission.
- Keeping active audio may affect battery and other playback; retaining only prepared objects does not guarantee process survival.
- Beads CLI is absent in the parent review context; this JSON is interim review evidence, not a replacement tracker.

## #987: Headless triggers reuse the keyboard readiness warm state

Reviewer: `/root/issue_review_queue/review_987`.

**Smallest worthwhile scope:** After prerequisite capture owner and bounded pre-roll are proven, integrate headless starts through the same valid-input acquisition contract. Preserve ordinary start when readiness is absent or invalid. Do not introduce a separate warm-engine implementation for headless triggers.

- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Claims keyboard recording, publishes recording heartbeat, stops readinessAudio without session deactivation, then starts recordingService. Existing keyboard start is an engine swap, not a continuous-input subscription.
- `Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift`: Private AVAudioEngine owns its input tap. Callback deliberately discards idle buffers; no ring snapshot, subscriber interface or ownership transfer exists.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Headless entry has run ownership, credential loading, foreground arbitration, watchdogs and Live Activity policy. These must survive any future warm path; residency alone cannot replace capture acquisition.
- `Tests/SpeakiOSTests/StartupDiagnosticsObservationTests.swift`: Current coverage verifies real configuration-stage reporting and failure omission. It supports measurement but does not prove warm handover.
- `comments/987.json`: Explicitly defers behind #978/#979/#974; requires valid-input ownership, tested transfer/fallback and device evidence before bypassing session setup.

**Dependencies**

- #978 readiness pre-roll mechanism
- #979 shared capture ownership/handover
- #974 relevant readiness/session qualification
- Existing #972 startup observation instrumentation can supply measurements

**Verification**

- First establish device baseline using existing startup stage diagnostics for Action Button with readiness on/off.
- Demonstrate lossless, nonduplicating handover of buffered and subsequent input with deterministic ownership tests.
- Exercise readiness invalidation, route change, call interruption, cancellation and concurrent keyboard/headless acquisition; each must release ownership and retain reliable fallback.
- Verify on physical iPhone while locked/backgrounded that first words are retained, Live Activity policy holds, and idle audio remains bounded in memory and is neither saved nor transmitted.
- Measure latency distribution before claiming under 100 ms; Apple native CI validates compilation and tests.

**Risks and limits**

- Not deferred because Linux cannot compile Apple frameworks; deferred because required capture contract is absent and explicit device gate remains unmet.
- Shared readiness heartbeat is not evidence that the caller owns live microphone input.
- Pre-roll changes idle-audio handling from discard to retention and needs a bounded, opt-in privacy contract.
- No device or microphone results produced during this read-only review.
- Beads CLI is absent per supplied context; JSON is interim review evidence only.

## #988: Dual-path first partial: on-device volatile text while the cloud socket connects

Reviewer: `/root/issue_review_queue/review_988`.

**Smallest worthwhile scope:** Keep implementation deferred. Measure representative selected cloud routes on real iOS hardware using existing diagnostics, including cold/warm starts and weak networks. Reconsider only when material latency remains and the warm/shared capture prerequisites have passed; then qualify a bounded, local-only display preview that relinquishes ownership on the first cloud partial.

- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift`: stop builds the committed result from partialText when non-empty; handleTranscript and finalisation use the same value as the full provider transcript. Local volatile preview cannot safely flow through that state or existing callback without separating display and authoritative transcript ownership.
- `Sources/SpeakCore/AppleSpeechAnalyzerTranscriber.swift`: Dictation progressive presets and asset preparation exist, but these excerpts do not establish a warm, shared cloud-preview session or its latency/thermal behaviour.
- `Sources/SpeakCore/SessionLatency.swift`: Existing latency model records capture-to-first-non-empty-partial separately from capture startup; use actual route measurements before adding a second recogniser.
- `comments/988.json`: Latest comment explicitly defers prerequisite #977/#979, requires selected-cloud-route measurement via #972, and forbids committing local preview to fields or History.

**Dependencies**

- #972 route-specific first-partial diagnostics and device measurements
- #977 warm-analyzer evidence gate
- #979 shared-engine evidence gate

**Verification**

- Record first-partial distributions and perceived benefit with baseline and proposed preview; do not assert the issue latency target without measurement.
- Before implementation approval, establish local asset/locale availability, memory/thermal/battery budget, session cancellation and empty-input behaviour on devices.
- Any later implementation must test divergent preview/cloud text, cloud final arriving without partial, cloud failure, stop before first cloud result, cancel/restart and late callbacks; local text must never enter committed fields, History or provider usage totals.
- Keep selected cloud provider authoritative and maintain its disclosed cost/privacy semantics; no additional cloud requests, silent model downloads or hidden provider fallback.

**Risks and limits**

- Static inspection cannot prove microphone, shared-engine or iOS 26 Speech framework behaviour; no device tests or runtime latency measurements were available for this review.
- A display-only partial requires explicit state separation because the existing partialText is also a final-result fallback.
- Beads CLI is absent per parent context; this JSON is interim review evidence, not a replacement tracker.

## #989: Leading-silence guard: detect dead Bluetooth input and auto-fall-back to the built-in mic

Reviewer: `/root/issue_review_queue/review_989`.

**Smallest worthwhile scope:** Keep this behaviour deferred. First use existing capture diagnostics plus narrowly scoped instrumentation under #972/#950 to qualify whether Bluetooth zero-filled startup is reproducible. Revisit #989 only if there is a distinguishable failure signature and an approved user-controlled fallback policy; no automatic one-second switch now.

- `Sources/SpeakiOS/Services/SharedClientLiveTranscriber.swift:447-488`: Records the first nonempty buffer and forwards capture through a processing queue; frame arrival is distinct from audible speech. Safety writer starts before capture. No demonstrated zero-sample Bluetooth failure is inferred by this code.
- `Sources/SpeakiOS/Services/AudioSessionManager.swift:100-159`: Bluetooth input is enabled with playAndRecord/measurement; existing fallback addresses activation rejection by using a mixable session, not silence or microphone selection.
- `Sources/SpeakiOS/Services/AudioSessionManager.swift:190-210,318-345`: Route diagnostics already use stable port types to avoid leaking device names, and route changes update display and notify observers. New route mutations must account for this lifecycle.
- `comments/989.json`: Explicitly requires physical-device evidence separating absent buffers, zero samples and quiet speech, then an explicit fallback policy; rejects one-second threshold and recovery estimates as unmeasured.

**Dependencies**

- #980 microphone-policy work remains explicitly deferred.
- #972/#950 capture instrumentation should supply route-labelled evidence; avoid a duplicate probe framework.

**Verification**

- Compare physical-device recordings for delayed speech, genuine silence, quiet speech, absent buffers, all-zero buffers and actual headset startup failures across at least two AirPods generations.
- Record port-type route labels and capture timings without raw audio, device names or unnecessary firmware identifiers.
- Before implementation, define a failure signature and demonstrate false-positive behaviour; define microphone-choice and fallback consent semantics.
- Any later route-switch implementation requires Apple-native builds and hardware tests for route reconfiguration, capture continuity, headset reconnection and visible recovery messaging.

**Risks and limits**

- RMS alone cannot distinguish a silent user from dead input; an arbitrary timeout risks switching healthy sessions.
- Switching input can itself interrupt capture or move listening to a phone in a pocket or another room.
- The claimed 1–3 second recovery and approximately 60-line effort are unverified.
- Static Linux inspection cannot validate Bluetooth hardware behaviour. Beads CLI is unavailable according to supplied parent context; no repository changes or external tracker updates performed.

## #994: Clipboard hygiene: expiring, local-only transcripts with an explicit Universal Clipboard opt-in

Reviewer: `/root/issue_review_queue/review_994`.

**Smallest worthwhile scope:** Implement one iOS transcript pasteboard adapter and a testable policy for configurable local expiry and explicit Universal Clipboard eligibility. Route existing automatic delivery and explicit transcript Copy surfaces through it, including History/Content and any notification copy actions. Use native settings controls and concise explanatory text; choose a bounded default such as five minutes/local-only, document effective settings and migration visibly so existing cross-device users can opt in. Keep polished text explicit-copy-only and retain existing write-result reporting. No delayed clear timer or macOS clipboard implementation expansion.

- `Sources/SpeakiOS/Services/AutomaticPolishOperation.swift`: System writer assigns UIPasteboard.general.string with no expiration/local-only options; copyRaw already guards empty strings and isolates automatic delivery from polishing.
- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Automatic delivery writes raw text exactly once and uses read-only polling to confirm delivery. Comments explicitly forbid later rewriting because another app may now own the clipboard.
- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Explicit Copy intents independently assign pasteboard.string; completion Copy retains a write-observation result which must survive helper adoption.
- `comments/994.json`: Cached latest review explicitly calls for a shared policy, zero writes for History Only/empty captures, no delayed timer clearing newer items, documented effective settings/migration, and two-device verification.

**Dependencies**

- Preserve implemented #934/#1031 raw automatic delivery and history-only polishing.
- Do not restore removed Send to Mac (#1024); Universal Clipboard is an OS copy eligibility setting, not that deleted delivery destination.
- Coordinate any simultaneous edits to automatic clipboard writer, Copy intents, History/Content copy actions and iOS settings.

**Verification**

- Test policy option generation, configured expiry, explicit cross-device choice, invalid/missing stored values and migration.
- Test automatic raw delivery writes once, late polish never writes, and History Only plus silent/empty capture write zero times.
- Test all explicit transcript Copy adapters use the same policy while preserving selected raw/polished content and success/failure reporting.
- Native iOS CI build/tests; device checks for local expiry and copying newer unrelated content before expiry without that newer content being cleared.
- Two-device iPhone/Mac verification for opt-in/opt-out behaviour; UI must not promise that remote copies expire or that expiry removes History.

**Risks and limits**

- Changing the default can surprise existing Universal Clipboard users; a silent migration is unacceptable.
- Clipboard expiry does not delete transcript History or guarantee deletion from other devices/apps. Treat remote expiry as unverified, not as a security promise.
- Native clipboard and Universal Clipboard behaviour cannot be proven on this Linux workspace; keep physical verification explicit without blocking useful policy/adapter implementation.
- Beads CLI is absent per parent context; this JSON is interim review evidence only.

## #996: Unified error taxonomy and one CaptureCommandRouter for every entry point

Reviewer: `/root/issue_review_queue/review_996`.

**Smallest worthwhile scope:** Introduce or extend one pure start-failure presentation mapping over existing error types: safe copy, stable local diagnostic code, optional supported recovery action. Wire existing intent catch-all and existing published start-error alert to that mapping. Distinguish missing credentials, denied permission, unavailable local assets, unavailable Live Activity/audio session and declined foreground continuation only when typed evidence exists. Keep a safe unknown fallback. Preserve current recording owners and router boundaries; do not add analytics or rewrite every entry point.

- `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`: Foreground continuation has a dedicated Live Activity retry, and ownership/parameter failures are handled separately, but the final catch still maps other start failures to microphone/speech permission advice.
- `Sources/SpeakiOS/Services/iOSTranscriptionError.swift`: Existing typed permission, recognizer, audio-session, Live Activity and timeout cases provide a useful mapping source. Audio-session and recognition descriptions currently interpolate underlying error text; this is unsuitable as universal spoken/public error copy.
- `Sources/SpeakiOS/Services/CaptureCommandRunner.swift`: URL and quick-action capture already share lifecycle/destination handling and terminal failure policy; cancellation is explicitly distinct from failure. Intent-specific authentication and foreground continuation are deliberately kept outside this runner.
- `SpeakiOSApp/SpeakiOSApp.swift`: Quick action already invokes CaptureCommandRunner.perform(.toggle).

**Dependencies**

- Honour latest issue comment: #1025/#1070 own shared quick-action/URL runner; #944/#1084 own terminal error visibility.
- #934/#935/#946 capture ownership fixes are landed and should be preserved.
- #776/#814 analytics consent and rollout gates remain; local diagnostic codes do not authorise telemetry.

**Verification**

- Unit-test distinct mappings and recovery destinations for known typed errors; unknown errors must not imply permission denial or expose raw provider text.
- Cancellation, declined continuation and superseded starts must not become a misleading terminal permission alert; verify expected intent outcome explicitly.
- Verify existing runner cancellation/destination/ownership tests still pass; add adapter coverage proving mapped failures reach existing user surfaces.
- Use Apple Swift/Xcode CI for native compilation and simulator UI tests; device check foreground continuation and settings navigation before declaring those journeys verified.

**Risks and limits**

- Recoverable failure mapping must follow actual typed evidence rather than guess from arbitrary error strings.
- Not every system failure has a supported deep link; use clear guidance when no supported repair destination exists.
- Do not expose credentials, provider response text or provider identities in spoken dialogs.
- Read-only triage inspected targeted current code; no native/device behaviour was tested. Beads CLI is absent per supplied context; this file is review evidence, not a replacement tracker.

## #998: Regression harness: simulator XCUITests on the transcript hook, seam tests for lifecycle, a device matrix job

Reviewer: `/root/issue_review_queue/review_998`.

**Smallest worthwhile scope:** Reconcile #998 as delivered harness infrastructure and link residual behavioural defects to their owning issues. Do not launch a second implementation agent for this umbrella. Require each accepted production fix to supply a regression for its actual user-visible failure. A true Toggle-intent-to-final-output gap should be handled only if its owning review establishes a missing seam.

- `Tests/SpeakiOSUITests/CaptureFlowUITests.swift`: Exercises real record controls and final text through deterministic simulator transcript injection; explicitly excludes microphone and Live Activity claims.
- `Tests/SpeakCoreTests/StreamingAudioPrerollTests.swift`: Existing shared-client order, cap and stop coverage; explicitly routes missing Modulate buffering to production defect #947.
- `.github/workflows/ci.yml`: Runs SpeakiOSTests and SpeakiOSUITests and labels limits in summary.
- `.github/workflows/ios-device-matrix.yml`: Nightly/manual workflow requires IOS_DEVICE_MATRIX_ENABLED and self-hosted macOS ios-device runner.
- `.github/ISSUE_TEMPLATE/action_button_device_matrix.md`: Physical locked-device, model selection and Live Activity scenario recording template already exists.
- `Tests/SpeakiOSTests/TranscriptionActivityLifecycleTests.swift`: Dedicated lifecycle seam coverage also exists; avoid adding copies under this umbrella.

**Dependencies**

- #947 owns Modulate first-word buffering and associated regression coverage.
- #1029 and #1047 are referenced by the shipped harness as lifecycle seam owners; reconcile their current reviews before assigning more coverage.
- #793 owns the earlier flaky UI harness concern.
- Physical device runner, provisioning and manual matrix remain separate operational gates.

**Verification**

- Confirm current native CI exercises the existing capture class and retains xcresult/logs before closure; static review here is not a run result.
- Retain physical-device matrix for hardware Action Button, locked starts, audio interruptions, routing and Live Activity rendering.
- Future preroll fixes must demonstrate ordered audio reaches transport; inspecting only a buffer is not full end-to-end assurance.
- Do not describe recopy availability as proof of clipboard contents: the current test explicitly cannot assert the actual pasteboard write.

**Risks and limits**

- Read-only bounded review on Linux; no Apple-framework, microphone, ActivityKit or device execution performed.
- The original Toggle-intent simulator test is not present in CaptureFlowUITests; existing app-button flows are a deliberate narrower delivery, not proof of intent invocation.
- The device job stays opt-in; do not enable infrastructure or claim nightly coverage from workflow existence.
- Beads CLI is absent according to supplied task context; this JSON is review evidence only.

## #999: Offline-first routing: record with no signal on-device, re-transcribe with the cloud model when online

Reviewer: `/root/issue_review_queue/review_999`.

**Smallest worthwhile scope:** Introduce an injectable network-path snapshot and local capability decision for ordinary live sessions; confirmed unsatisfied path plus available local language assets can select strict local recognition before opening a cloud connection.; Treat unknown path as unknown and satisfied path as no guarantee of provider availability; preserve existing provider error recovery.; Use the existing visible fallback notice and capture/history identity; retain audio and offer the existing manual retry flow where local recognition is unavailable. Preserve explicit per-run model contracts.; Do not introduce pending cloud queues, BGProcessingTask, automatic History replacement, or implicit batch-model substitution in this first change.

- `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`: Current live resolution makes credential fallback visible; explicitly named unavailable models must not be silently replaced. Offline routing must preserve these per-run contracts.
- `Sources/SpeakiOS/Services/iOSLiveTranscriber.swift`: Apple recognition only requires on-device processing if preferOnDevice and recognizer.supportsOnDeviceRecognition are true; otherwise it uses server recognition. Selecting Apple alone is not proof of an offline route.
- `Sources/SpeakiOS/Services/CaptureRecoveryCoordinator.swift`: Existing interrupted-capture recovery preserves files, bounds its operation, keys History by capture run, and exposes manual batch retranscription. A streaming-only selection falls back to a supported batch model; that manual policy must not silently become automatic paid upload consent.
- `Sources/SpeakiOS/Views/iOSHistoryManager.swift`: History already supports durable upsert by identity with updatedAt conflict selection. Automatic upgrades would need to protect user edits and durable completion in addition to reusing the UUID.

**Dependencies**

- Coordinate with #992/#1083 existing capture recovery ownership; do not add a second file-recovery coordinator.
- Honour issue comment 5622113485: separate fallback and upload; require local capability, consent, supported batch route, bounded retry and idempotent replacement.

**Verification**

- Deterministic route-policy tests: offline/local ready, offline/local unavailable, unknown path, online-but-provider-fails, missing credentials, and explicitly named model.
- Prove strict offline route cannot fall back to Apple server recognition; verify locale/asset capability handling and audio preservation on failure.
- Native CI compilation plus device flight-mode and reconnect checks covering first words, complete persisted audio, stable History identity and truthful fallback text.
- No automatic provider upload or additional provider cost on reconnect.

**Risks and limits**

- Network path does not establish provider reachability; no background-completion or latency guarantee from static inspection.
- Apple capability and asset availability vary by locale/device; unavailable local support needs explicit recoverable UX.
- Any future cloud-upgrade stage needs explicit opt-in, supported saved-file route, a single recovery owner, cancellation/deletion handling, bounded retry and protection against overwriting user edits.
- Apple Swift/Xcode and device checks unavailable on Linux; Beads CLI absent as reported in supplied context.
