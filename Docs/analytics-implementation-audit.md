# Analytics implementation audit

Source baseline: `b65588f` (5 September 2026), with the queue corrections
described below. This is a source audit, not evidence that production rollout
has passed. Issues [#776](https://github.com/crmitchelmore/justspeaktoit/issues/776)
and [#814](https://github.com/crmitchelmore/justspeaktoit/issues/814) remain open.
The [analytics plan](analytics-plan.md) still supplies the production go/no-go gates.

## Decisions already recorded

The comments on #776 supersede several unchecked items in its original body:

- On 21 August, Chris confirmed himself as data controller,
  `hello@justspeaktoit.com` as the contact, and
  `https://justspeaktoit.com/privacy` as the public policy URL. App Store
  analytics/disclosure work was explicitly deferred to a separate review.
- On 28 August, the account audit reported that Production and its protected
  ingestion key already exist. IP discard and several automatic capture/replay
  settings were verified disabled. The later comment records Chris as the sole
  organization owner, no pending invitations, and third-party AI disabled.
- Chris then approved **Production only**: do not create or fund Development;
  development builds must remain unconfigured/no-op. A second project is no
  longer a prerequisite. These are recorded decisions, not a fresh backend audit.

No project, credential, collection setting, or rollout gate is changed by this
audit. No request was made to an analytics endpoint during this work.

## #776: what the repository establishes

| Area | Evidence and remaining gap |
| --- | --- |
| Transport | `PostHogAnalytics.swift` contains a minimal `/capture` client, excluded by `APP_STORE`. Missing configuration is no-op. The source comment explains avoiding SDK remote config; it is not the required current-SDK spike or release network capture. |
| Consent | `AppSettings.analyticsEnabled` defaults false. `WireUp` synchronizes consent into `ProductAnalyticsController`; macOS onboarding and Settings expose an explicit choice. Core tests cover unknown/opted-out silence and cleanup errors. End-to-end withdrawal, rapid consent changes, and release-build zero-traffic evidence still need validation. |
| Queue | Durable queue has 1,000-entry/seven-day limits. This change serializes flushes, cancels active requests on purge/close, rejects stale responses after reopening, removes acknowledged entries by local queue ID, and persists pruning before replay. Legacy queue files remain readable. |
| Identity | `FileProductAnalyticsStateStore` stores a random install UUID in app data; core tests cover deletion and anonymous counters without that UUID. Backend separation from Sentry still needs evidence. |
| Kill switches | Core exposes a tested `forceDisabled` closure, but the production factory does not supply an override. The build/defaults kill switch and server key-rotation drill are not established by source tests. |
| Inspector | Core `preview` produces a sample payload. There is no release inspector with actual queued/sent wire JSON, endpoint, queue depth, reset, last-100 export, or activity feedback. Sample preview is not wire parity: the transport adds envelope properties. |
| Phase-one events | macOS has daily activity, onboarding call sites, and first-transcription success. Daily deduplication occurs at app startup and records the date after a best-effort capture; this does not establish multi-day-running-app coverage or successful durable delivery. |
| Typed catalogue | Closed event/dimension types, scalar encoding, language/context bounding, and catalogue tests exist. The catalogue test checks Swift cases/properties; it does not read the Markdown table, so automatic catalogue-to-docs drift coverage remains missing. |
| Disclosures | `Docs/PRIVACY.md`, `SECURITY.md`, and `landing-page/privacy.html` describe initial direct-macOS collection. A checked-in web page does not prove publication or server retention enforcement. Store disclosures/archive manifests remain separate gated work. |
| Distribution | Factory allows direct macOS; iOS does not initialize this transport. `release-appstore.yml` checks that PostHog keys and transport symbols are absent. Release inspector parity, keyboard binary/network audits, and store rollout are not complete. |

Cancellation stops queued work and requests still controlled by the client. It
cannot recall bytes a server already received before withdrawal. The new tests
must not be interpreted as that guarantee or as an exactly-once delivery
guarantee across network failures/process crashes.

## #814: expansion remains gated

| Acceptance area | Current implementation |
| --- | --- |
| Numeric distributions and segmentation | `AnalyticsPropertyValue` already encodes native Boolean, integer and double values, with round-trip and transport tests. Lifecycle metrics still use coarse buckets/model families; exact model IDs, timings and settings state are not wired. Native scalar support alone does not satisfy the dashboard requirement. |
| Exactly one terminal event per transcription | Typed lifecycle cases exist, but production lifecycle capture is not installed. No terminal-event accounting or representative lifecycle test establishes this criterion. |
| Settings emit only for user changes | The catalogue contains `settingsChanged(setting:category:)`, without a typed setting value. Comprehensive user-action-only settings instrumentation and startup-hydration tests are absent. |
| Store isolation | PostHog transport is compile-guarded and the store workflow checks keys/symbols. Actual submitted archive validation remains required. |

Post-processing exact timing/model/state capture is likewise absent. Extending
these production call sites must wait for #776's clean phase-one inspection
week. Do not replace the current bucketed privacy contract with exact metrics
or mark #814 shipped based on the scalar foundation.

## Validation and bounded next action

`PostHogAnalyticsTests` adds offline `URLProtocol` scenarios for concurrent
captures, withdrawal with an active request followed by renewed consent,
expiry while the process remains alive, and oldest-first legacy queue-cap
enforcement. Existing typed/scalar tests remain applicable. Apple Swift CI must
run these tests; they were not executed in the Linux audit environment.

The follow-up delivery audit adds a 15-second total request deadline and a
16 KiB response limit. Transient network failures, HTTP 408/429 and HTTP 5xx
schedule at most three automatic retries (after 1, 5 and 30 seconds), including
events accepted during a failed in-flight flush. Permanent rejections and
oversized responses do not automatically retry. Exhaustion keeps the bounded
queue on disk; close and withdrawal cancel scheduled retries. New delivery
tests exercise recovery, stalled/oversized responses, exhaustion, revoked-key
responses and withdrawal during backoff. These safeguards do not establish the
outstanding production network or kill-switch audit evidence.

The next engineering step is to validate the consent lifecycle and local kill
switch, then implement the exact-payload release inspector without expanding
the collected catalogue. Before enabling or widening production, record the
remaining retention verification, release network capture, inspector checks,
server kill-switch drill, and identity-separation evidence. Existing project,
key, contact, and membership decisions do not need to be requested again.
