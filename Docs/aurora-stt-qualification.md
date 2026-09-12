# Blue Machines Aurora STT qualification

Status on 12 September 2026: **contract unavailable**. Public primary sources do
not establish a supported Aurora inference interface, and no authorised account
or inference access was exercised. This record is a qualification boundary, not
an integration plan or a conclusion that a private API does not exist.

No endpoint was guessed or probed, no credentials or console account were used,
no audio was uploaded, and no signup, payment, vendor contact, model download,
catalogue entry, runtime change, or automated recheck was performed.

## Current primary-source pass

This finite pass inspected public vendor-owned surfaces and links they published.
JavaScript shells limit static visibility; missing public content is recorded as
not established rather than as a vendor rejection or technical incompatibility.

| Primary surface | 12 September 2026 observation | Missing requirement | Next owner action |
| --- | --- | --- | --- |
| [Blue Machines](https://bluemachines.ai/) | Public enterprise agentic customer-experience page. It describes a multi-model voice platform, not an Aurora inference contract. | Canonical product/model identity, supported direct inference access, and developer documentation. | Recheck only if the vendor publishes a documented developer surface or the owner supplies authorised existing access. |
| [Platform](https://bluemachines.ai/platform) | Public platform page rendered as a JavaScript shell during static inspection. Targeted vendor-domain search yielded no Aurora request/response documentation. | All callable API details. Absence in static output does not prove a private contract is absent. | Follow a future public documentation link; do not reverse-engineer application routes. |
| [Blue Machines blog](https://blog.bluemachines.ai/) | Public index returned HTTP 200 and described enterprise deployments. The inspected index and targeted vendor-domain search exposed no Aurora API documentation. | Versioned model, endpoint, authentication, schemas, limits, pricing, and data handling. | Inspect a future vendor-published Aurora/developer article if one appears. |
| `https://api.bluemachines.ai/` | The source pass recorded unauthenticated HTTP 200 with `{"status":"ok"}`. This proves only that a health surface responded. | No model list, entitlement, inference endpoint, authentication, request, response, error, or lifecycle contract. | Treat as health evidence only; do not enumerate guessed paths. |
| `https://console.bluemachines.ai/` | The source pass recorded HTTP 200 with an HTML application shell. No authenticated console or developer documentation was inspected. | Account entitlement, available quota, API keys, documented contract, and inference success. | Owner may inspect only with existing authorised access after a contract is available; do not sign up or enable billing for this issue. |
| [Blue Machines on Hugging Face](https://huggingface.co/blue-machines) | Public organisation metadata listed classification/feature-extraction assets during this pass, not an authoritative Aurora STT contract. | Aurora model identity, inference rights, serving API, audio contract, and licence/weight provenance for any local route. | Do not download or infer service availability from unrelated model repositories. |
| [Privacy policy](https://bluemachines.ai/privacy-policy) | General platform privacy terms were public. | Aurora-specific retention, training use, processing region, deletion, subprocessors, and enterprise terms. | Obtain provider-specific terms through an authorised owner review before sending audio. |
| [Terms](https://bluemachines.ai/terms) | General platform terms were public. | Aurora-specific service rights, SLA, usage limits, pricing, and compatibility commitment. | Legal/owner review remains required for the intended use; this dossier gives no legal clearance. |

The public health response does not prove an inference API. The console HTML shell
does not prove account entitlement or authentication. General marketing, an
enterprise voice demo, or a third-party provider named in a Blue Machines
tutorial is not an Aurora API contract.

## Historical evidence kept separate

Issue evidence dated 8 September 2026 reported reachable health, console, sales,
and announcement surfaces but no callable inference contract. That evidence is
retained as historical context only. In particular, its authentication-redirect
observation is not claimed as newly reproduced by the 12 September pass.

The new pass did not convert the historical observation into access evidence.
Neither pass performed an Aurora transcription.

## Required contract and access fields

Every field below needs an authoritative vendor source or an authorised observed
result. Do not fill gaps by assuming OpenAI compatibility or by extrapolating
from the platform's other providers.

| Field | Current result | Evidence required before integration |
| --- | --- | --- |
| Canonical Aurora product/model ID and version policy | NOT ESTABLISHED | Versioned vendor documentation and deprecation policy |
| Supported transport | NOT ESTABLISHED | Explicit file/batch, live, or both; batch documentation does not establish live support |
| Inference endpoint | NOT ESTABLISHED | Published base URL and exact documented route |
| Authentication format | NOT ESTABLISHED | Documented key/token type and header or handshake format, without recording a secret |
| Account entitlement | NOT ESTABLISHED | Existing authorised account showing Aurora access separately from console login |
| Free quota/access | NOT ESTABLISHED | Account-visible allowance and restrictions; no paid activation |
| Audio request body | NOT ESTABLISHED | Multipart/binary/WebSocket schema and required fields |
| Audio formats | NOT ESTABLISHED | Encodings, containers, sample rates, bit depths, and channel limits |
| Language coverage | NOT ESTABLISHED | Exact supported language list and language-hint/detection syntax |
| Input limits | NOT ESTABLISHED | Maximum duration, file/frame size, concurrency, and session limits |
| Result lifecycle | NOT ESTABLISHED | Synchronous response, asynchronous job/polling, or streaming event sequence |
| Transcript schema | NOT ESTABLISHED | Final text and segment structure, timestamps, confidence, language, and metadata semantics |
| Live admission | NOT ESTABLISHED | Start/ready contract, ordered audio acceptance, backpressure, and reconnect behavior |
| Stop/finalisation | NOT ESTABLISHED | Explicit input completion, drain, terminal result, timeout, and late-event behavior |
| Cancellation | NOT ESTABLISHED | Documented request/session cancellation and resulting terminal state |
| Errors | NOT ESTABLISHED | HTTP/protocol errors, stable codes, retryability, and sanitized body schema |
| Rate limits | NOT ESTABLISHED | Published limits, headers/events, and retry guidance |
| Pricing | NOT ESTABLISHED | Unit, currency, minimums, rounding, free tier, and overage behavior |
| Data handling | NOT ESTABLISHED | Audio/transcript retention, training use, region, deletion, subprocessors, and contractual controls |
| Service availability | NOT ESTABLISHED | Supported countries/accounts and production/SLA status |

The exact blocker is the missing authoritative model, entitlement,
authentication, request/audio, response/error, lifecycle, limits, pricing, and
data-handling contract. This is not evidence that Blue Machines rejected access
or that Aurora is technically incompatible with the app.

## Access and contract outcome

| Qualification dimension | Result | Meaning |
| --- | --- | --- |
| Public contract | UNAVAILABLE | No authoritative inference contract was found in the bounded pass |
| Account/console access | NOT RUN | No login, signup, settings, key, or entitlement inspection was authorised |
| API health | HEALTH ONLY | HTTP 200 `{"status":"ok"}` is not inference availability |
| Inference access | NOT RUN | No supported route and no authorised credential |
| Real-audio result | NOT RUN | No audio left the workspace |
| Implementation readiness | NO | Do not add an adapter, key field, model, picker entry, route, or test fixture |
| Issue outcome | KEEP OPEN | Revisit only when the missing contract and access evidence become available |

A complete contract could still leave access unavailable. Conversely, a logged-in
console or healthy host without a contract would still not justify an adapter.

## Conditional real-audio gate

Only after the contract is authoritative and the owner confirms existing
authorised free access, use the smallest supported non-sensitive spoken fixture:

- approximately 5–10 seconds with an exact reference sentence and explicit
  first and last words;
- existing local or otherwise authorised generation, never a private recording
  or newly purchased synthesis;
- recorded SHA-256, duration, encoding, sample rate, bit depth, channels, and
  container;
- documented model and non-secret parameter shape;
- request start, first accepted input, first result where applicable, input end,
  and final result timestamps;
- protocol status, sanitized error code, parsed transcript, and first/last-word
  preservation.

First prove one actual transcription and one bounded failure/cancellation path
appropriate to the published transport. For live transport, require ordered
audio acceptance and explicit stop, drain, and final transcript; an interim alone
is not completion. Do not persist credentials, signed URLs, request headers,
account identifiers, provider bodies containing private data, or full logs. Do
not deliberately exhaust quota.

One successful fixture would establish access and that fixture only. It would not
prove production latency, multilingual accuracy, financial-domain quality,
reliability, microphone behavior, or device integration.

## Integration boundary after qualification

If contract and real-audio gates later pass, prepare a separate implementation
plan for only the verified transport. Reuse the shared
`TranscriptionProvider` contract for batch support, or the existing streaming
session architecture only when the vendor publishes a live lifecycle. Do not add
a second generic provider framework or claim multipart compatibility before the
body contract matches.

Production work would still require shared catalogue/capability registration,
secure credential coordination, supported-platform routing, friendly History
names, sanitized errors, request/error/cancellation fixtures, catalogue and
routing invariants, native builds, and platform UI verification. It must preserve
explicit local/remote selection and strict-offline behavior.

This dossier authorises none of those changes, no release, no Stable promotion,
and no recurring discovery automation.
