# Cleanup model refresh: November 2026

Verified 4 November 2026 against the public [OpenRouter model API](https://openrouter.ai/api/v1/models).
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
[OpenAI's Luna page](https://developers.openai.com/api/docs/models/gpt-6-luna)
also confirms the model, context and standard token rates.
The API records list text input/output and a maximum completion of 128,000 tokens
for all three. The catalogue stores base `pricing.prompt` and `pricing.completion`
multiplied by one million, not cached-input, Flex or Priority rates.

For prompts at the API's `min_prompt_tokens: 272000` override, input/output
rates become $0.20/$0.75 for Luna, $4/$15 for Sol and $20/$75 for Astra.
Provider, region and service tier may change the actual price. Picker descriptions
flag the base-rate limitation; the existing two-rate metadata is not a complete
billing estimator. Reasoning usage can also affect the bill.

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

## Local validation (4 November 2026)

- Strict repository lint (`make lint`): 0 violations across 2,641 Swift files.
- `python3 scripts/verify-portable-core-boundary.py`: passed.
- `git diff --check`: passed.
- Compared all three new entries against the fetched API JSON: exact IDs, base
  rates and context matched. Removing the single added catalogue block reproduces
  the original file byte-for-byte.
- `xcrun swift test --filter ModelCatalogTests`: blocked before compilation by
  MacStorageGuard (internal free space below its 25 GiB minimum, exit 75). No
  XCTest passed or failed. The new `ModelCatalogRefreshTests`, full `make test`,
  Apple/iOS builds and portable compiled tests remain unrun locally. CI must
  qualify them; no storage guard was bypassed.
