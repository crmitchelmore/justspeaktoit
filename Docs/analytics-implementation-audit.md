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
patch. No production capture event was sent during this work.

## GeoIP boundary

The 25 October 2026 read-only Production audit verified IP discard, autocapture
opt-out and replay opt-out, with no events in the last seven days. All seven
events in the last 30 days nevertheless had nonempty city, latitude and postcode
enrichment. Only aggregate counts were read; no location values or user IDs were
retrieved. Current settings do not prove the settings at those historical
ingestion times. IP discard is not proof of no GeoIP: PostHog's
[storage documentation](https://posthog.com/docs/privacy/data-storage#discarding-ip-addresses-at-project-level)
explicitly permits transformations to use the IP before discarding it.

The final envelope now unconditionally adds the native Boolean
`properties.$geoip_disable = true`, matching the
[documented per-capture control](https://posthog.com/docs/libraries/python#geoip-properties)
and [official SDK serialization](https://github.com/PostHog/posthog-python/blob/3f6c80eb4df1ddffd9e5b9d1d8aae8facf9f83b2/posthog/client.py#L2432).
Fresh, legacy-queued and retried events share this serializer with inspection;
an older queued false/missing control cannot bypass it. No location or content
property is added. This establishes the client request, not server enforcement,
historical erasure or a clean inspection week. Server/history cleanup, retention,
policy publication and production qualification remain owner gates. No existing
event or project setting was changed.

## #776: what the repository establishes

| Area | Evidence and remaining gap |
| --- | --- |
| Transport | `PostHogAnalytics.swift` contains a minimal `/capture` client, excluded by `APP_STORE`. Missing configuration is no-op. The approved narrowed scope retains this client rather than replacing it with an SDK; full-process release network capture remains required. |
| Consent | `AppSettings.analyticsEnabled` defaults false. `WireUp` synchronizes consent into `ProductAnalyticsController`; macOS onboarding and Settings expose an explicit choice. Core tests cover unknown/opted-out silence, cleanup errors, rapid consent changes, and suspended opt-in/capture after withdrawal. Transition revisions prevent stale resumptions and new opt-ins await withdrawal cleanup. Real UI withdrawal and release-build zero-traffic evidence still need validation. |
| Queue | Durable queue has 1,000-entry/seven-day limits. This change serializes flushes, cancels active requests on purge/close, rejects stale responses after reopening, removes acknowledged entries by local queue ID, and persists pruning before replay. Legacy queue files remain readable. |
| Identity | `FileProductAnalyticsStateStore` stores a random install UUID in app data; core tests cover deletion and anonymous counters without that UUID. Backend separation from Sentry still needs evidence. |
| Kill switches | `AnalyticsLocalPolicy` supplies one synchronized gate to controller and sink. A persisted device-local override, build plist flag and controlled-launch environment flag can force collection off. The inspector’s in-process control immediately cancels controlled requests/retries and purges local queue, inspection history and identity while preserving consent. An external `defaults write` takes effect after restarting the relevant app; the running policy does not reload UserDefaults. Production release-network and server key-rotation qualification remain pending. |
| Inspector | Direct macOS Settings exposes a native inspector using the same event-envelope builder as transport, with ingestion credentials omitted. It shows consent/effective policy, endpoint origin (userinfo/path/query/fragment omitted), existing identity, queue depth and at most 100 recent records, including valid persisted queued records from earlier launches. Reset preserves consent, clears local identity/queue/history and creates no event. Export writes only after a native destination choice. Native Debug/Release privacy tests and an isolated native visual fixture pass; full-process release-network qualification remains open. iOS/store expansion is excluded. |
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

The controller follow-up adds five deterministic suspended-sink tests for
consent transitions, identity ownership, restored consent, and kill-switch
rechecks. Native Debug CI passed all 2,446 tests at PR head `d1f3fe5`, including
these consent and delivery regressions; this does not replace release-network
qualification.

The direct-macOS inspector and local controls now have source coverage and privacy
regressions for credential-free envelope equality, scalar/anonymous identity
semantics, retention, retry identity, local persistence failures, policy/reset
races, read-only inspection and export feedback. On 25 October 2026, Apple
Swift 6.2.3 / macOS SDK 26.2 passed all 59 relevant tests in both Debug and
Release. An isolated native window rendered the inspector and selected event
JSON using temporary state and intercepted requests. This proves native UI
rendering, not a full-process Release network audit. No production backend
request, key rotation or rollout was performed to implement it.

An unsigned SwiftPM Release executable compiled with `-DAPP_STORE` also built
successfully. Its strings and symbol tables contain none of the PostHog sink,
inspector, privacy-controls or local-policy type names, the PostHog endpoint,
or the local override key. This is compile/exclusion evidence, not a signed
App Store archive, binary privacy report or runtime traffic audit.

Before enabling or widening production, retain the release network capture,
12-month retention/aggregate-or-delete verification, server privacy settings,
policy publication, approved ingestion-key rotation/revoke drill, Sentry identity
separation and clean phase-one inspection week. Daily-active date correctness
and typed-catalogue-to-Markdown drift coverage remain separately scoped gaps.
