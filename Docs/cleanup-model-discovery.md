# Optional cleanup model discovery

The bundled `ModelCatalog.postProcessing` remains the canonical baseline shipped
and refreshed through normal app updates. Discovery supplements it; it never
updates the app, replaces bundled metadata, changes a default, or selects a model.

## Configuration and selection

Discovery defaults **off**. The first version admits OpenAI-authored models only,
through the existing OpenRouter cleanup route.

- **Mac/iOS:** in remote Post-processing settings, enable **Discover OpenAI cleanup
  models via OpenRouter**. Opening that setting while enabled refreshes metadata
  if older than six hours. **Refresh models** requests an earlier refresh, subject
  to a one-minute retry floor. Expand the discovered list and explicitly choose
  a model. The native control is shared in SpeakCore.
- **Windows/Linux:** the same off-by-default toggle appears in the existing native
  Preferences form, under Post-processing. **Apply** refreshes stale metadata
  before the existing cleanup picker is repopulated. Startup only restores the
  bounded cache. There is no background timer or mid-edit picker replacement.
- Disabling discovery cancels an active fetch and hides additional choices.
  An already selected discovery remains selected and usable through the existing
  cleanup flow. It does not grant new inference consent or enable post-processing.
- Saved discoveries use `openrouter/cleanup/<OpenRouter model ID>`. This namespace
  preserves an explicit choice across restart, disabled discovery, cache loss,
  upstream removal, and a later app update bundling the same raw route. The chat
  request encoder unwraps it for both streaming and completed responses. Malformed
  or untrusted author namespaces fail validation. Provider unavailability is a
  normal request failure; no model is silently substituted.

## Trusted source and scope

Verified 4 November 2026:

- OpenRouter's public [model metadata API](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
  exposes architecture modalities, supported endpoints, context length, pricing
  and expiration. An unauthenticated GET to `https://openrouter.ai/api/v1/models`
  succeeded and returned the routed GPT-6 entries documented in the
  [bundled refresh evidence](cleanup-model-upgrades-2026-11.md).
- OpenAI's [List models API](https://developers.openai.com/api/reference/resources/models/methods/list)
  provides identifiers, creation and ownership metadata, not the routed context,
  price and chat capability evidence required here. A bare model list is never
  converted into a cleanup option. Direct OpenAI discovery would also need a
  separate credential despite cleanup using OpenRouter; this implementation makes
  no request to OpenAI and reads no credentials.

The allowlist means model authorship (`openai/`), not upstream provider pinning.
Existing OpenRouter routing/account policy still determines the serving provider.
Admitting another author is a reviewed app change. Entries must advertise text
input, text-only output and `/api/v1/chat/completions`; entries with an expiration
field are conservatively excluded. Metadata does not prove cleanup quality.
Provider prose and unknown fields are discarded. There are no inferred speed,
quality or latency values. Unknown prices/context stay unknown; valid base token
prices are labelled as such and are not a complete billing quote. The existing
Option type still requires the unmeasured Medium tier fallback.

## Request and cache boundaries

`CleanupModelDiscoveryStore` reuses `OpenRouterBoundedResponseTransport`, the same
bounded transport used by audio discovery. Audio discovery itself is unchanged.

- Fixed HTTPS OpenRouter destination; GET only, no body, API key, transcript,
  prompt, inference, cookies, credential storage, HTTP cache or redirects.
- 20-second total deadline, 4 MiB streaming response/cache cap, at most 4,096 input
  records and 256 validated discoveries. One active request; one-minute retry
  floor also applies after failure and manual refresh.
- Six-hour freshness; caches older than seven days or dated in the future are
  ignored for discovery. Bundled choices always remain available. Saved choices
  remain visible even without metadata.
- Versioned cache contains only validated display/price/context metadata and date.
  Atomic writes, bounded reads and cache revalidation protect restart. An older
  request cannot overwrite a newer saved snapshot. Disabling fences late results.
  Failed refresh keeps previous valid metadata and gives generic feedback, never
  a provider response body. Persistence failure leaves in-memory metadata usable.

## Qualification

Shared Apple/portable tests in `Tests/SpeakDesktopTests/CleanupModelDiscovery*`
cover trust filtering, metadata-only requests, price uncertainty, bundled
precedence, retry bounds, cancellation/deadline/size failures, cache retention and
expiry, native preference serialization, ID migration and chat request encoding.
Mac/iOS settings tests cover saved selections across restart without a cache.

Final local static gates pass: strict pinned SwiftLint with the repository baseline
reported 0 violations in 2,647 Swift files; the portable boundary checker and
`git diff --check` also passed.

Local compiled tests/builds remain blocked by MacStorageGuard's 25 GiB internal
free-space floor. CI must qualify Apple, iOS and portable graphs, and native UI
interaction has not been exercised. No billable inference or account/credential
changes were performed. Review the exact final PR head rather than the earlier
static-catalogue-only CI run.
