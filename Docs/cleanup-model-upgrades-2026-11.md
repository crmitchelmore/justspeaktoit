# Cleanup model refresh: November 2026

Routes verified 4 November 2026 against the public [OpenRouter model API](https://openrouter.ai/api/v1/models);
IDs, standard short-context rates and context windows re-verified 5 November 2026 against
OpenAI's [pricing page](https://developers.openai.com/api/docs/pricing) and model pages.
These are optional entries in `SpeakCore.ModelCatalog.postProcessing`, shared by
macOS, iOS and the portable desktop hosts. Existing entries, saved selections,
`defaultPostProcessingModel` (GPT-5 Mini) and `defaultFastTextModel` remain unchanged.

| Route | Role in this refresh | Base input / output USD per million tokens | Context tokens |
| --- | --- | --- | --- |
| `openai/gpt-6-luna` | Cost-efficient option | $0.10 / $0.50 | 1,050,000 |
| `openai/gpt-6.1-sol` | Middle tier below Astra | $2 / $10 | 1,050,000 |
| `openai/gpt-6-astra` | Optional flagship | $10 / $50 | 1,050,000 |

Model pages: [Luna](https://openrouter.ai/openai/gpt-6-luna),
[Sol](https://openrouter.ai/openai/gpt-6.1-sol),
[Astra](https://openrouter.ai/openai/gpt-6-astra).
OpenAI model pages: [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[Astra](https://developers.openai.com/api/docs/models/gpt-6-astra).
The API records list text input/output and a maximum completion of 128,000 tokens
for all three. The catalogue stores base `pricing.prompt` and `pricing.completion`
multiplied by one million, not cached-input, Flex or Priority rates.

For prompts at the API's `min_prompt_tokens: 272000` override, input/output
rates become $0.20/$0.75 for Luna, $4/$15 for Sol and $20/$75 for Astra.
Provider, region and service tier may change the actual price. Picker descriptions
flag the base-rate limitation; the existing two-rate metadata is not a complete
billing estimator. Reasoning usage can also affect the bill.

The optional discovery layer added alongside this refresh is documented in
[cleanup model discovery](cleanup-model-discovery.md). The evidence below describes
the bundled entries; discovery preserves their metadata and defaults.

## Native routes and picker grouping

Since #1382, `NativeTextModels` adds curated `native/<provider>/<model>` entries for
Anthropic, OpenAI, Google Gemini, Groq and Mistral. They call the provider's own
OpenAI-compatible `chat/completions` endpoint with that provider's key (`anthropic.apiKey`,
`openai.apiKey`, `google.apiKey`, `groq.apiKey`, `mistral.apiKey`). OpenAI requests omit
`temperature` and send `max_completion_tokens`; Anthropic requests omit `temperature`,
which Claude 4.7 and later reject below 1. `anthropic.apiKey` is a cleanup-only credential:
it transfers between devices but is not in the CloudKit-synced set. iOS lists only
providers it stores keys for (not Groq). Android mirrors the same catalogue and picker rule
in `CloudCatalog.cleanupModels` and `CleanupModelPicker`, checked by `CloudParityTest`.

`ModelPickerGrouping` puts native and on-device models first and shows OpenRouter as
one entry that opens its own searchable list; grouping follows the credential each model
resolves to. Each group is alphabetical by provider (OpenRouter: vendor prefix), then by
model name, case-insensitive and numeric-aware; tags remain badges, not ordering. The unprefixed entries below remain OpenRouter routes, so saved selections
keep their route. The section that follows describes those OpenRouter routes.

## Runtime compatibility

Cleanup uses the existing OpenRouter `/api/v1/chat/completions` route and
`openrouter.apiKey`, including for `openai/` model IDs. It does not use a direct
OpenAI credential. `OpenRouterChatClient` forwards the model ID unchanged;
`OpenRouterAPIClient` delegates remote chat to it. iOS and portable desktop cleanup
also use this shared client. No provider adapter or audio discovery change is needed.

The public API lists `max_tokens`, `max_completion_tokens` and reasoning controls
for these models. It does not list `temperature`. The current client sends temperature
without `require_parameters`; OpenRouter's [documented default routing](https://openrouter.ai/docs/guides/routing/provider-selection#requiring-providers-to-support-all-parameters)
permits unsupported parameters to be ignored. Temperature control is therefore not
promised for these entries. This refresh does not alter shared request semantics.

No billable inference was run. Catalogue/request compatibility is based on source
inspection and provider metadata, not an end-to-end provider qualification.
No cleanup quality or latency improvement is claimed. New entries have no numeric
latency estimate and no Fast or Quality tag. `Option` requires a latency tier, so
they inherit its existing Medium fallback; that label is not a measurement.
The Leading tag on Astra denotes the provider's flagship positioning only.

## Regression coverage

`ModelCatalogRefreshTests` checks unique new entries, exact names/rates/context,
cloud projection membership, OpenRouter credential resolution, cleanup routing,
absence from speech catalogues, no invented latency estimate, stable defaults,
and normalization preserving both new and existing selections. Existing GPT-5.6
metadata assertions in `ModelCatalogTests` remain intact. The exact cloud projection test continues to
protect a single shared catalogue. No scheduler, release-notes generation model,
transcription model or runtime audio-discovery catalogue is changed.

## Update: 11 November 2026

`defaultPostProcessingModel` is now GPT-5.6 Luna, because OpenAI shuts down GPT-5
Mini on 11 December 2026. Saved GPT-5 Mini and GPT-5.4 Nano selections move on
their shutdown days through `ModelRetirements` (`.postProcessing`). Full details,
including the GPT-5.6 repricing and the new Claude 5.5 entries, are in
[speech model upgrades](speech-model-upgrades-2026-11.md#weekly-check-11-november-2026).

## Update: 12 November 2026 — lean list

The cleanup list now keeps one model per price/quality tier per provider. A model is
removed when a newer model from the same provider is cheaper on both input and output
and at least as capable, or when its provider has announced a replacement.
`CleanupModelRemovals` (SpeakCore) moves saved selections, profile overrides and
in-flight requests to the successor straight away, always on the same route: native
selections keep their provider key, OpenRouter slugs stay on OpenRouter. Android receives
the same table as `cleanupModelSuccessors` in `cloud_catalog.json`. History keeps the
removed model's name.

The default is now **GPT-6 Luna** (`openai/gpt-6-luna`, $0.10/$0.50 per M tokens) on every
platform, the paid-access worker (policy `2026-11-12`) and the release-notes generator.

| Removed | Rate (in/out per M) | Moves to | Rate | Why |
| --- | --- | --- | --- | --- |
| GPT-5.6 Luna | $0.20 / $1.20 | GPT-6 Luna | $0.10 / $0.50 | Newer, half the price |
| GPT-5 Mini (OpenRouter and direct) | $0.25 / $2 | GPT-6 Luna | $0.10 / $0.50 | Shuts down 11 Dec 2026 |
| GPT-5.4 Nano | $0.20 / $1.25 | GPT-6 Luna | $0.10 / $0.50 | OpenAI's named replacement; shuts down 1 Apr 2027 |
| GPT-5.4 Mini (OpenRouter and direct) | $0.75 / $4.50 | GPT-6 Luna | $0.10 / $0.50 | Newer generation, far cheaper |
| GPT-5.6 Terra | $2 / $12 | GPT-6.1 Terra (new) | $1 / $5 | Newer, cheaper |
| GPT-5.6 Sol | $4 / $20 | GPT-6.1 Sol | $2 / $10 | Newer, cheaper |
| GPT-5.5 | $5 / $30 | GPT-6.1 Sol | $2 / $10 | Newer, cheaper |
| GPT-5.4 | $2.50 / $15 | GPT-6.1 Sol | $2 / $10 | Newer, cheaper |
| Claude Haiku 4.5 (OpenRouter and direct) | $1 / $5 | Claude Haiku 5.5 | $0.10 / $0.50 | Newer, a tenth of the price |
| Claude Sonnet 4.6 (OpenRouter and direct) | $3 / $15 | Claude Sonnet 5.5 | $2 / $10 | Newer, cheaper |
| Gemini 2.5 Flash (OpenRouter and direct) | $0.30 / $2.50 | Gemini 3.5 Flash Lite (new) | $0.30 / $2.50 | Google routes it there from 1 Dec 2026 |
| Qwen3.6 Flash | $0.19 / $1.13 | Qwen3.8 Flash (new) | $0.15 / $0.47 | Newer, cheaper |
| Qwen3.6 35B A3B | $0.10 / $0.90 | Qwen3.8 Flash | $0.15 / $0.47 | Newer; cheaper for output-heavy cleanup |
| Llama 4 Scout | $0.10 / $0.30 | Qwen3.8 Flash | $0.15 / $0.47 | April 2025 model with no Meta successor |
| Llama 3.1 8B Instant (Groq) | — | GPT-OSS 20B (Groq) | $0.075 / $0.30 | Groq shut it down 16 Aug 2026 |

Kept: GPT-6 Luna, GPT-6.1 Terra, GPT-6.1 Sol, GPT-6 Astra, Claude Haiku 5.5 and Sonnet 5.5
(OpenRouter and direct), Gemini 3.1 Flash Lite (fast-text default; shuts down 7 May 2027),
Gemini 3.5 Flash Lite, Gemini 2.5 Flash Lite ($0.10/$0.40, no shutdown announced),
Qwen3.8 Flash, Mistral Small 4 / Mistral Small (direct), GPT-OSS 120B and 20B on Groq.

Sources (checked 12 November 2026): [OpenRouter models API](https://openrouter.ai/api/v1/models),
[OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[GPT-6.1 Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra),
[OpenAI deprecations](https://developers.openai.com/api/docs/deprecations),
[Claude models overview](https://platform.claude.com/docs/en/models/overview),
[Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[Gemini deprecations](https://ai.google.dev/gemini-api/docs/deprecations),
[Groq models](https://console.groq.com/docs/models).
OpenAI does not formally name GPT-6 Luna/6.1 Terra/6.1 Sol as successors of the GPT-5.6
tiers; the mapping follows tier and price. No billable inference was run, so no cleanup
quality or latency is claimed beyond the providers' positioning. Claude Haiku 5.5 is
$0.50/$2.50 above 100K-token prompts, which cleanup prompts do not reach.
