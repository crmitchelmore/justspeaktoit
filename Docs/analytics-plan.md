# Product Analytics Plan

**Status:** Accepted; foundation implementation in progress
**Scope:** The typed, vendor-neutral foundation implements the consent and payload boundary first. Vendor transport,
production credentials, UI consent surfaces, disclosures, and event call sites remain gated by the go/no-go checklist.
**Last updated:** August 2026

This plan builds on the research already captured in issue #591 (Apple ATT rules,
PostHog SDK defaults, shipping-app patterns, keyboard-extension constraints) and
turns it into a decision document: what we measure, what we never measure, which
vendor, which consent model, and how we roll it out.

---

## 1. Goals

### Product questions analytics must answer

| Area | Question | Why it matters |
| --- | --- | --- |
| Activation | What fraction of installs reach a first successful transcription, and where does the onboarding funnel leak? | Onboarding is the highest-leverage surface we currently fly blind on |
| Retention | Do people who activate come back (D1/D7/D30, WAU/MAU)? Does retention differ by platform or provider type? | Tells us whether the core loop works, not just whether downloads happen |
| Feature usage | Which capabilities are actually used: providers (on-device vs cloud, by provider *type*), polish/post-processing, corrections, profiles, insights, history, voice output, keyboard, Send to Mac? | Decides where engineering time goes and what we can deprecate |
| Reliability | What are transcription success/failure rates, coarse latency and duration distributions, by version and pipeline stage? | Catches regressions Sentry crash data cannot see (a failed transcription is not a crash) |
| Release health | Are counts by version/OS/distribution channel sane after a release? | Spots migration problems across direct, Homebrew, MAS, and App Store builds |

Every event in the catalogue below must map to one of these questions. An event
that does not drive a concrete product decision gets removed in the review phase.

### Explicitly out of scope — never collected

- **No transcript content** — not full text, not partial text, not prefixes, not
  "sanitised" excerpts, not prompts, not correction phrases, not clipboard or
  selected text.
- **No audio**, ever, in any form, at any sample length.
- **No per-keystroke or per-utterance telemetry** — no keylogging-shaped data,
  no typing cadence, no keyboard-extension traffic of any kind.
- **No API-key metadata** — not key length, prefix, hash, validity, creation
  time, or error bodies that echo a key. Provider *type* (e.g. "deepgram") is
  the only allowed dimension.
- **No screen capture, session replay, heatmaps, or UI autocapture.**
- **No identity** — no email, Apple ID, IDFA, IDFV, hardware IDs, device names,
  IP-based identity, fingerprinting, or cross-app tracking.
- **No free-form strings** — every property is an enum, boolean, count, or
  bucket, enforced in code and tests.

**The cautionary tale.** Wispr Flow — a competing dictation product — shipped a
"Context Awareness" feature that periodically screenshotted the user's active
window and sent the images to cloud AI servers, disclosed only in a subprocessor
document. When a Reddit user discovered and reported it in 2025 the company's
first reaction was to ban him; the CTO later apologised and made the feature
opt-in. That incident is exactly the failure mode this plan is designed to make
structurally impossible: default-on collection, content-derived data, disclosure
buried in docs, and hostility to the user who checked. Just Speak to It's
positioning is the opposite — transcript content never leaves the device except
to the provider the user chose — and analytics must be built so that an outside
auditor reading our source and watching our network traffic confirms it.

---

## 2. Event taxonomy (draft v1)

### Privacy classes

- **A — anonymous counter**: sent with global context properties only, *not*
  associated with the install ID. Usable for aggregate counts, not funnels.
- **P — pseudonymous**: associated with the random install ID (see §3) so that
  funnels, retention, and dedup work. Never linked to a person.
- **N — never**: listed here to make the boundary explicit; these are not
  events and must fail review if proposed.

### Global context properties (attached to every event)

`platform`, `app_version`, `build`, `os_major_minor`, `distribution_channel`
(direct | homebrew | mac_app_store | testflight | app_store | development),
`locale_language_code`,
`architecture`, `analytics_schema_version`. Nothing else. No device model, no
device name, no timezone beyond what ingestion infers coarsely (IP capture
disabled at the project level).

### Bucket definitions (shared, versioned with the schema)

- `duration_bucket`: `<5s`, `5-15s`, `15-60s`, `1-5m`, `>5m`
- `word_count_bucket`: `1-10`, `11-50`, `51-200`, `201-1000`, `>1000`
- `latency_bucket`: `<250ms`, `250ms-1s`, `1-3s`, `3-10s`, `>10s`
- `count_bucket` (rules/profiles/etc.): `0`, `1`, `2-5`, `6-20`, `>20`
- `days_since_install_bucket`: `0`, `1`, `2-7`, `8-30`, `>30`
- `size_bucket` (downloaded model size): `<100mb`, `100-500mb`, `500mb-1gb`,
  `1-5gb`, `>5gb`

Raw durations, word counts, and latencies are computed locally, bucketed
locally, and the raw values are never serialised into an event.

### Catalogue

| # | Event | Properties (beyond global context) | Class | Question served |
| --- | --- | --- | --- | --- |
| 1 | `app_active_daily` | *(none — deduplicated one-per-calendar-day ping, cmux pattern; replaces SDK lifecycle autocapture)* | P | DAU/WAU/MAU, retention, release health |
| 2 | `onboarding_started` | `entry_point` (fresh_install \| reset) | P | Activation funnel top |
| 3 | `onboarding_step_completed` | `step` (bounded enum: welcome, microphone_permission, provider_choice, hotkey_setup, analytics_choice) | P | Funnel leak location |
| 4 | `onboarding_permission_result` | `permission` (microphone \| speech \| accessibility \| local_network \| notifications), `state` (granted \| denied \| restricted) | P | Funnel leaks caused by permission denials |
| 5 | `onboarding_completed` | `steps_skipped_bucket` | P | Funnel bottom |
| 6 | `first_transcription_succeeded` | `provider_type`, `engine_type` (on_device \| cloud), `days_since_install_bucket` | P | **Activation** (the north-star event) |
| 7 | `transcription_started` | `mode` (live \| batch), `engine_type`, `provider_type` (apple \| deepgram \| openai \| … — type, never key or account info), `model_family` (bounded enum of shipped families: apple \| whisper \| parakeet \| nova \| scribe \| … \| other — never a raw model id), `language_code`, `trigger` (hotkey \| menu_bar \| action_button \| keyboard \| widget \| url_scheme) | P | Feature usage, reliability denominator |
| 8 | `transcription_completed` | same as #7 + `duration_bucket`, `word_count_bucket`, `latency_bucket`, `output_method` (paste \| clipboard \| send_to_mac \| keyboard) | P | Reliability, usage depth |
| 9 | `transcription_failed` | same as #7 + `error_category` (bounded enum), `pipeline_stage` (capture \| stream \| provider \| output) | P | Reliability |
| 10 | `transcription_cancelled` | same as #7 + `duration_bucket` | P | Reliability (user-abandonment signal) |
| 11 | `polish_completed` | `engine_type`, `provider_type`, `latency_bucket`, `preset` (bounded enum of built-in preset ids; custom presets report `custom`, never their content) | P | Polish adoption |
| 12 | `polish_failed` | as #11 + `error_category` | P | Polish reliability |
| 13 | `correction_applied` | `rules_matched_bucket` *(counts only — rule text is user content and never leaves the device)* | A | Corrections adoption |
| 14 | `correction_rule_created` | `total_rules_bucket` | P | Corrections adoption |
| 15 | `profile_activated` | `profile_count_bucket`, `is_default` *(no profile names/ids)* | P | Profiles adoption |
| 16 | `insights_viewed` | `surface` (bounded enum) | P | Insights adoption |
| 17 | `history_action` | `action` (search \| copy \| delete \| export \| clear_all) | P | History adoption |
| 18 | `voice_output_used` | `engine_type`, `provider_type` | P | Voice output adoption |
| 19 | `send_to_mac_completed` | `success`, `latency_bucket` | P | Send to Mac adoption/reliability |
| 20 | `model_download_completed` | `model_family` (same bounded enum as #7), `size_bucket`, `success` | P | Local-model adoption |
| 21 | `keyboard_enabled_state` | `enabled` *(reported by the consented main iOS app only; the keyboard extension itself is permanently analytics-free — see issue #591's Full Access constraint)* | P | Keyboard adoption |
| 22 | `provider_configured` | `provider_type`, `method` (manual \| icloud_sync) *(the event says a provider became usable; nothing about the key itself)* | P | Provider adoption |
| 23 | `settings_changed` | `setting_id` (bounded enum), `category` *(never the value)* | P | Feature discovery |
| 24 | `error_displayed` | `error_category`, `surface` *(typed enums; no messages, no payloads)* | A | Reliability UX |
| 25 | `analytics_opt_in` | `surface` (onboarding \| settings) *(opt-**out** sends nothing — the last event a user's device ever sends must not be "I left")* | P | Consent-rate honesty check |

**Class N (never events):** transcript submitted, text-content anything,
keystroke anything, screenshot anything, api_key anything, session replay,
per-app/per-window context of where dictation was inserted, contact/email
capture, `identify`/`alias`/`group` calls of any kind.

Before implementation this table becomes typed Swift enums/structs in
`SpeakCore` (single shared catalogue for both platforms), with a
`beforeSend`-style allowlist as the second line of defence and unit tests that
fail on any non-enum string property, exactly as issue #591 specifies.

---

## 3. Architecture

### Vendor and hosting: PostHog EU Cloud (see §6 for the honest comparison)

- **PostHog Cloud EU** (Frankfurt, AWS eu-central-1). EU Cloud disables IP data
  capture for new projects by default; we additionally verify IP/geo handling,
  retention, and access controls in project settings before first event.
- **Not self-hosted** for v1: the hobby deployment is fine technically at our
  volume but adds an ops burden (patching, backups, uptime) that a two-platform
  indie app should not carry, and the free tier (1M events/month) comfortably
  covers projected volume. Revisit if governance requires it.
- Two projects: `dev` and `production`. Debug builds use `dev` or the no-op
  client, never `production`.
- The SDK ships **locked down** using the exact configuration baseline
  enumerated in issue #591 (all autocapture, swizzling, screen views, lifecycle
  events, surveys, replay, feature-flag preloading, person profiles, and error
  autocapture off; `personProfiles = .never`). The unavoidable remote-config
  request is a known cost — see the go/no-go checklist: if a network audit shows
  traffic we cannot justify to a user reading our source, we switch vendors
  (§6) rather than ship.

### Consent: opt-IN, three states, with a real preview

- Persisted consent state: `unknown` | `optedIn` | `optedOut` (Element X
  pattern). **`unknown` and `optedOut` both send nothing.** The SDK is not
  initialised until the state is `optedIn`.
- The opt-in prompt appears once, late in onboarding (after first value is
  demonstrated, never as a gate), and:
  - shows a **live preview of the actual JSON** that would be sent for a sample
    event — the same renderer as the inspector in §4, not marketing copy;
  - states what is collected, what is never collected, purpose, retention, and
    how to withdraw; links `Docs/PRIVACY.md`;
  - is visibly *our* UI — it must not imitate an Apple permission prompt.
- Settings on both platforms carry a permanent **"Share anonymous analytics"**
  toggle. Turning it off: stops capture synchronously, purges the on-disk queue,
  deletes the install ID, closes the SDK, and sends nothing — covered by an
  integration test, since (per #591's research) the SDK's `optOut()` alone does
  not clearly guarantee queue deletion.

### Identity: random install ID, nothing else

- A `UUID()` generated on first opt-in, stored in Application Support (not the
  Keychain — it must die with the app data, not survive reinstall).
- **Not** synced across devices via iCloud in v1 (per #591's recommendation);
  macOS and iOS installs are independent pseudonyms.
- Never passed to `identify`/`alias`/`group`; never reused as the Sentry user
  ID or any backend identity. Deleted and regenerated on opt-out/opt-in cycles
  ("reset my analytics identity" for free).
- No IDFA, no IDFV, no fingerprinting; `NSPrivacyTracking` stays `false` and no
  `NSUserTrackingUsageDescription` is added.

### Offline behaviour and kill switches

- Events queue on disk while offline, capped (e.g. 1,000 events / 7 days,
  oldest-first eviction); the queue is purged immediately on opt-out.
- **Local kill switch:** a build-level flag and a hidden `defaults`/plist
  override that force the no-op client regardless of consent state.
- **Remote kill switch without remote config:** v1 deliberately has no feature
  flags (per #591), so the emergency stop is server-side — revoking/rotating
  the project API key at PostHog stops ingestion for all shipped builds
  immediately, and ingestion-side filtering can drop a bad event name. This
  satisfies "analytics can be disabled without an app release" with zero
  additional client surface.

### Coexistence with Sentry

| Concern | Owner | Notes |
| --- | --- | --- |
| Crashes, hangs, HTTP client errors, performance traces | **Sentry** (macOS production only, as today — `Sources/SpeakApp/SentryManager.swift`) | PostHog crash capture stays disabled |
| Deliberate product events | **PostHog** | Typed catalogue only |
| Shared identity between the two | **None** | Different IDs, never joined; `SentryManager.setUser` must not receive the analytics install ID |

Sanity cross-checks (PostHog `app_active_daily` vs Sentry sessions vs App Store
Connect vs GitHub release downloads) are an explicit rollout task, not a data
join.

### Disclosure updates required before first production event

- **`Docs/PRIVACY.md`**: replace the "Analytics & Telemetry" section (which
  currently says no usage analytics are collected) with the opt-in analytics
  description: what, why, where (EU), retention, off-switch, and a link to the
  event catalogue. `SECURITY.md` gets the same alignment PR #590 established
  for Sentry.
- **Privacy manifests** (`PrivacyInfo.xcprivacy`, both apps): keep
  `NSPrivacyTracking = false` and zero tracking domains; declare **Usage Data →
  Product Interaction** (not linked to identity, not used for tracking); assess
  with the final payload whether the random install ID triggers **Identifiers →
  Device ID** under Apple's then-current definitions. Validate the *merged
  archive* manifest (app + PostHog SDK's bundled manifest), not just source.
- **App Store Connect** privacy answers for both apps, plus App Review notes
  stating the analytics are anonymous, first-party, non-advertising,
  non-tracking, and user-controllable.
- **Homebrew/direct builds** ship identical behaviour and the same disclosure —
  distribution channels must not diverge in schema, prohibited data, or consent
  semantics (tested).

---

## 4. Verifiability: analytics as a trust feature

The app is open source and its users are exactly the demographic that reads
source and runs proxies. Lean into that:

1. **In-app Analytics Inspector** (both platforms, shipped in *release* builds,
   reachable from Settings → Privacy → Analytics, no secret gesture):
   - a live, scrollable feed of every event as the **exact JSON payload**
     queued/sent — same bytes as the wire, pretty-printed;
   - current consent state, install ID (with a "reset" button), queue depth,
     and endpoint hostname;
   - an "export last 100 events" action so users can diff against the docs;
   - works in `unknown`/`optedOut` states too — it then shows "nothing is
     collected" backed by an empty queue, which is itself the proof.
2. **Public event catalogue**: §2's table lives in this repo and is linked from
   the opt-in prompt, the inspector, and `PRIVACY.md`. A CI test asserts the
   typed Swift catalogue and the documented table stay in sync (names,
   properties, classes), so the docs cannot silently drift from the binary.
3. **Auditable pipeline**: the typed event API + allowlist means a reviewer can
   read one file in `SpeakCore` and enumerate everything the app can possibly
   send. PRs adding events must update catalogue + docs + tests together.
4. **Reproducible network audit**: a documented `mitmproxy` recipe in the
   release checklist so anyone can watch a store-signed build's traffic and
   confirm it matches the inspector. This is the exact audit that exposed
   Wispr Flow — we publish the instructions for running it against us.

---

## 5. Rollout

### Phases

| Phase | Scope | Gate to next phase |
| --- | --- | --- |
| **0. Design & governance** | Finalise this catalogue as typed code; consent copy; retention (proposal: 12 months, then aggregate-only); create dev/prod PostHog projects with replay/surveys/flags disabled server-side; land disclosure PRs | Catalogue + consent model reviewed and merged; go/no-go checklist items 1–4 pass |
| **1. macOS Developer ID + Homebrew (internal)** | Ship behind opt-in to direct-download builds first — no store review latency, fastest fix loop; events: `app_active_daily`, onboarding funnel, `first_transcription_succeeded` only | One week of payload inspection shows zero prohibited data; counts sane vs Sentry sessions |
| **2. iOS TestFlight** | Same minimal event set; store-signed build tested with analytics disabled and enabled; App Store Connect privacy answers updated *before* external TestFlight | Archive privacy report matches declarations; keyboard extension confirmed traffic-free |
| **3. Full event set, both stores** | Add transcription lifecycle, feature adoption, error events; MAS + App Store submissions with review notes | Dashboards answer the §1 questions; no schema divergence across the five channels |
| **4. Review (T+2 months)** | Audit properties, retention, access, cost, usefulness; delete events that drove no decision; publish a short "what we learned / what we removed" note | — |

### Success criteria

- Activation funnel (install → first successful transcription) measurable with
  step-level drop-off, per platform.
- D1/D7/D30 retention cohorts and DAU/WAU/MAU per platform/version/channel.
- Transcription success rate and latency distribution per provider type and
  version, sensitive enough to flag a regression between releases.
- Opt-in rate itself is tracked and reported honestly; if fewer than ~10% of
  active users opt in, treat the data as directional only and say so in any
  decision that cites it.
- Zero privacy incidents: no prohibited field ever observed in payload audits.

### Go/no-go checklist (all must pass before any production event)

1. [ ] Typed catalogue merged; tests fail on non-allowlisted keys/values and on
       catalogue↔docs drift.
2. [ ] Network-spy tests prove nothing is sent in `unknown`/`optedOut`; queue
       purge on opt-out proven by integration test.
3. [ ] Full `mitmproxy` capture of a release-configuration build reviewed: every
       request justified, including the SDK's remote-config call. **If that
       call cannot be disabled or justified, this checklist fails and we
       execute the §6 fallback (TelemetryDeck) instead of shipping.**
4. [ ] `PRIVACY.md`, `SECURITY.md`, both privacy manifests, and App Store
       Connect answers updated and consistent with observed payloads.
5. [ ] Analytics Inspector functional on both platforms in release builds.
6. [ ] Keyboard extension binary confirmed to contain no analytics symbols and
       produce no analytics traffic.
7. [ ] Server-side kill switch drill performed (rotate key, confirm clients fail
       silently and queue-cap correctly).
8. [ ] Sentry and analytics identities confirmed unlinked in both backends.

---

## 6. Alternatives considered

Volume assumption for costing: a successful year-one outcome of ~2,000 opted-in
actives × ~10 events/day ≈ **600k events/month**; near-term reality is far
lower.

| Criterion | PostHog EU Cloud | PostHog self-hosted | **TelemetryDeck** | Aptabase (cloud or self-host) | Roll-your-own counters |
| --- | --- | --- | --- | --- | --- |
| Privacy defaults out of the box | **Weak** — SDK defaults-on for lifecycle, screens, swizzling, replay, surveys, flags; needs ~15 explicit overrides + `beforeSend` allowlist; remote-config request cannot be disabled | Same SDK caveats; data never leaves our infra | **Strong by design** — anonymized at ingestion, salted-hash identifiers, no PII stored, no replay/autocapture to disable | Strong — session-based, no unique user identifiers | Perfect (we define everything) |
| Funnels | Yes, best-in-class | Yes | Yes | Limited | No (build it) |
| Retention cohorts / DAU-WAU-MAU | Yes, best-in-class | Yes | Yes | Sessions-based, coarser | No (build it) |
| Slicing by version/OS/channel, ad-hoc queries (SQL) | Yes | Yes | Query editor + TQL, less flexible than SQL | Basic dashboards | No |
| EU hosting | Frankfurt; IP capture off by default on EU Cloud | Wherever we run it | German company, EU-hosted (Augsburg/Hamburg) | EU or US region choice | Ours |
| Open source | Backend open source (auditable), SDK open source | Fully | SDKs open source; backend proprietary | Fully open source (self-hostable) | Fully |
| Swift SDK weight/fit | Full-featured, heavier, must be caged | Same | **Swift-native, tiny, purpose-built for Apple platforms** | Lightweight Swift SDK | None |
| Cost at 600k events/mo (2026 pricing) | **$0** (1M free/mo, then ~$0.00005/event) | Infra + ops time | ~50k free (new accounts since Jul 2026), paid plan required at our target volume; auto-upgrade pricing | ~$14/mo cloud; free self-host + ops | Infra + significant build time |
| Ops burden | None | Real (upgrades, backups, uptime) | None | Low (cloud) / real (self-host) | Highest |
| App Store label complexity | Moderate — must audit merged SDK manifest each update | Same | **Lowest** — designed for clean labels/ATT posture | Low | Lowest |
| Ecosystem risk | Large, well-funded, but product surface keeps growing (more defaults to audit each SDK update) | Same code, our pace | Small sustainable German company; pricing tightened Jul 2026 | Small project | Bus-factor: us |

### Recommendation

**PostHog EU Cloud, conditionally — with TelemetryDeck as the named,
pre-approved fallback, and the abstraction built so the swap is a one-file
change.**

Reasoning, honestly weighed:

- **TelemetryDeck wins on privacy defaults, SDK fit, and ethos.** It is the
  vendor this app's brand would pick: privacy-by-design at ingestion, EU-based,
  Swift-native, clean App Store posture, nothing to cage. If our requirements
  were "counts, funnels, retention, and nothing exotic," it is sufficient —
  it now offers funnels and retention insights.
- **PostHog wins on the actual analysis requirements and cost.** Issue #591's
  outcomes lean on flexible slicing (regressions by version × provider ×
  channel, ad-hoc SQL) where PostHog is materially stronger, and its 1M free
  events/month covers our realistic ceiling at $0, versus a paid TelemetryDeck
  plan at target volume under its post-July-2026 pricing. Its backend being
  open source also fits our verifiability story.
- **PostHog's real cost is trust-surface, not dollars**: a defaults-maximal SDK
  we must lock down and re-audit every update, plus an unavoidable
  remote-config request. This plan prices that in: the go/no-go checklist makes
  a clean network audit a *shipping condition*, not an aspiration. If the audit
  fails — or if maintaining the caged configuration proves error-prone across
  SDK updates — we switch to TelemetryDeck, and because all call sites go
  through the typed `ProductAnalyticsClient` in `SpeakCore` with our own queue,
  consent, and install-ID handling, the vendor is an implementation detail.
- Self-hosted PostHog and self-hosted Aptabase trade our scarcest resource
  (maintainer time) for control we can get more cheaply via the opt-in model
  and the allowlist. Roll-your-own is the most honest option and the least
  likely to ever answer a retention question; rejected on build cost.

The consent model (opt-in, preview, inspector) does more for user trust than
the vendor choice does — which is why this plan spends more words on §3–§4
than on the logo at the bottom of the dashboard.

---

## References

- Issue [#591](https://github.com/crmitchelmore/justspeaktoit/issues/591) — research base: Apple ATT rules, PostHog SDK configuration baseline, Element X / OpenUsage / Quotio / cmux patterns, keyboard-extension constraint
- PR #590 — `docs: align telemetry privacy disclosures` (Sentry disclosure baseline this plan extends)
- `Docs/PRIVACY.md`, `Docs/SECURITY_TRANSCRIPT_LOGGING.md`, `Docs/SENTRY_CONFIGURATION.md`, `Sources/SpeakApp/SentryManager.swift`
- [PostHog pricing](https://posthog.com/pricing) — 1M free events/month, EU Cloud (Frankfurt)
- [TelemetryDeck pricing update, July 2026](https://telemetrydeck.com/blog/pricing-update-2026/) — free tier now 50k events/month for new accounts
- [TelemetryDeck Swift platform overview](https://telemetrydeck.com/platforms/swift/) — funnels, retention, TQL
- [Aptabase](https://aptabase.com/) — open-source, session-based, ~$14/mo cloud or self-host
- Wispr Flow "Context Awareness" screenshot incident (2025) — e.g. [contemporary coverage](https://www.getvoibe.com/resources/is-wispr-flow-safe/) of the Reddit disclosure, ban, and CTO apology
