# Provider credit balances and allowances

Settings shows what each provider account currently holds, beside the API key
that unlocks it, on both macOS and iOS. This page records what is shown, what
is deliberately not shown, and why.

## The model

`ProviderBalanceState` (SpeakCore) is a typed state, never an optional number:

| State | Meaning |
| --- | --- |
| `cash` | Prepaid money the account can spend. |
| `allowance` | A metered entitlement that depletes, with an optional total. |
| `usage` | Consumption the provider reports with no wallet meaning. |
| `freeQuota` | A free tier's remaining allowance. |
| `payAsYouGo` | Metered post-paid billing; nothing to deplete. |
| `unavailable` | The provider publishes no balance contract we can read. |
| `unknown` | Auth failure, quota failure, cancellation, malformed body, or a field the provider omitted. |

Every fetch produces a `ProviderBalanceSnapshot` carrying `refreshedAt`, plus
`resetsAt` / `expiresAt` where the API reports them, and the plan name where the
provider names one.

**A missing limit is `unknown`, never unlimited credit.** `ProviderBalanceFormatter`
renders an allowance with no reported total as `"… left (limit unknown)"` and
adds "The provider did not report a limit, so the total is unknown." Only `cash`
and `allowance` are `isSpendableCredit`; usage, quota, pay-as-you-go, unavailable
and unknown are not, and the views style them accordingly.

## What is read live

| Provider | Endpoint | Shown as |
| --- | --- | --- |
| Deepgram | `GET /v1/projects` then `GET /v1/projects/{id}/balances` | `cash` when `units` is `usd`; a unit-labelled `allowance` otherwise |
| Rev.ai | `GET /speechtotext/v1/account` | `allowance` of `balance_seconds`, total unknown |
| ElevenLabs | `GET /v1/user/subscription` | `allowance` (or `freeQuota` on the free tier) of characters, with the reset date |
| OpenRouter | `GET /api/v1/credits` | `cash` of `total_credits - total_usage` |

All four reuse the Keychain credential the account already stores; none needs an
extra key. No balance credential is ever written to defaults or plaintext —
`ProviderBalanceStore` reads through `SecureStorage` and holds nothing.

## What is deliberately a billing link only

- **OpenAI** — the admin API reports costs already incurred, not a wallet, and
  needs an admin key the app does not hold. Showing it as a balance would be a
  lie about what the account can spend.
- **Cartesia** — the credits endpoint reports admin usage rather than a
  spendable wallet.
- **Soniox** — reports consumed usage, not a wallet.
- **Azure** — a balance needs a separate billing sign-in and an offer
  eligibility check that a Speech resource key cannot perform.
- **xAI** — the management billing API needs a separate management key that an
  inference key does not provide.
- **Everything else** — AssemblyAI, Gladia, Groq, Gemini, Mistral, Speechmatics,
  Meta, Modulate: no documented balance contract we can read, so the card links
  to the provider's billing page with the reason stated.

Adding a provider to the first-class list means citing its documented balance
endpoint in `ProviderBalanceDirectory` and giving it a transport; the default
for a new credential is a billing link.

## Deduplication

Balances belong to an *account*, not to a card. `ProviderBalanceDirectory` maps
every Keychain identifier to an account and names one
`primaryCredentialIdentifier`; only that card renders the figure. So Deepgram's
separate transcription and voice-output cards, and OpenAI's `openai.apiKey` /
`openai.tts.apiKey` pair, each show one account once. Providers whose single key
serves both speech-to-text and text-to-speech already render one combined card,
and that card is the primary.

## Failure behaviour

`ProviderBalanceSource.fetchBalance` cannot throw. Auth failures, quota
failures, cancellation and malformed responses all resolve to `unknown` with the
reason shown to the user. Nothing in this subsystem is on a transcription or
voice-output path, and the settings screen renders identically whether or not a
billing endpoint answers. A refresh is only issued for an account whose key is
actually stored — presence of a key is never itself reported as entitlement.

## Verification status

The transports are covered by tests for success, auth failure, quota failure,
cancellation and malformed responses against stubbed endpoints. Live responses
from Deepgram, Rev.ai, ElevenLabs and OpenRouter billing endpoints have not been
observed on a funded account; that remains a human check.
