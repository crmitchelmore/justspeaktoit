# Paid Access: what it does and what data it uses

This document covers the optional paid access subscription only. General app data handling is in [`PRIVACY.md`](PRIVACY.md). Operators should also read [`paid-access.md`](paid-access.md).

## You do not need to subscribe

On-device local models and your own API keys are the default in Just Speak to It, and they remain fully supported. They are not a trial, a reduced tier, or a legacy path.

- **Local models** run on your Mac or iPhone. Audio never leaves the device, and there is nothing to pay.
- **Your own API keys** (bring your own, or BYO) talk directly from your device to the provider you chose. Your keys stay in the Keychain and are never sent to us.
- **Paid access** is a convenience. It exists so that you can use cloud transcription without creating accounts with vendors, holding API keys, or managing your own billing.

Paid access does not unlock any feature, model, or quality of output that you cannot reach by supplying your own key or using a local model. Depending on how much you dictate, using your own key is often cheaper, and local models are free. If you already have a provider account, you probably do not need this.

## What paid access actually does

When paid access is switched on, your audio or text is sent to our server, which forwards it to a named provider using **our** credentials, and returns the result to you. That is the whole mechanism: we stand between you and the provider so that you do not have to hold an API key.

We choose the model. Paid requests name an operation — live transcription, batch transcription, or post-processing — and our server decides which provider and model runs it. The app shows you the current choice; it cannot change it. That keeps costs predictable and means we can move a route if a provider degrades.

| What you are doing | Who processes it | Measured in |
| --- | --- | --- |
| Live (streaming) transcription | Deepgram, model `nova-3` | Audio seconds |
| Recorded (batch) transcription | OpenRouter, model `google/gemini-2.0-flash-001` | Audio seconds |
| Post-processing of transcript text | OpenRouter, model `openai/gpt-5-mini` | Tokens |

If an operation has no supported paid route, the request fails with a clear error. It is never quietly redirected to a different model or charged to your own key.

## What we process and what we keep

| Data | Processed | Retained by us |
| --- | --- | --- |
| Microphone audio | In memory, while proxying to the provider | No |
| Transcript text | In memory, while proxying to or from the provider | No |
| Post-processing prompts | In memory, while proxying to the provider | No |
| Your Apple user identifier (from Sign in with Apple) | Yes | Yes |
| Your email address, if Apple shares it | Yes | Yes, if provided |
| Subscription state and its history | Yes | Yes, append-only |
| Metered usage counts (audio seconds, token counts) | Yes | Yes, append-only |
| Sign-in session records | Yes | Yes; refresh tokens are stored only as a SHA-256 hash |

Audio and transcript text pass through our server in memory and are not written to any database, object store, or log. What reaches our usage records is a count — how many seconds of audio, how many tokens — never the content those numbers describe.

Your subscription history and usage records are append-only: they can be added to but not edited or deleted, including by us. That makes billing auditable. It also means a correction is recorded as a new entry rather than by rewriting the past.

### How long we keep it

| Record | Retention |
| --- | --- |
| Microphone audio, transcript text, post-processing prompts | Not retained at all — in memory only, for the duration of the request |
| Sign-in session records | Until the session is revoked or expires, then 90 days |
| Metered usage records | 24 months from the end of the billing period they belong to |
| Subscription state and its history | 7 years from the end of the subscription, to satisfy tax and accounting obligations |
| Audit records | 24 months |
| Your Apple user identifier and email address | For the life of the account, then 30 days after deletion |

Ask us to delete your account by emailing **privacy@justspeaktoit.com** from the address linked to it, or by quoting a recent `x-correlation-id`. We remove your Apple identifier, email address, and sign-in sessions within 30 days. Subscription and usage history is retained for the periods above because it is append-only and legally required for billing records; it is disassociated from your identifiers at deletion so it can no longer be traced back to you. The same address handles access requests, which we answer within 30 days.

## What is never logged

Our server logs are deliberately narrow. They never contain:

- microphone audio;
- transcript text;
- post-processing prompts or their results;
- API keys, session tokens, or refresh tokens;
- request or response bodies of any kind.

Log fields whose names look credential-shaped are redacted automatically before a line is written, so a mistake in new code fails safe. Every response carries a correlation identifier; that identifier alone is enough for us to investigate a failure, which is why support will only ever ask you for it.

## Who receives your data on the paid path

| Third party | When | What they receive |
| --- | --- | --- |
| Deepgram | Live transcription | The audio stream |
| OpenRouter | Recorded transcription | The audio you recorded |
| OpenRouter | Post-processing | The transcript text and your post-processing prompt |
| Stripe | Direct-download macOS subscriptions | Your payment details, handled by Stripe; we never see a card number |
| Apple | App Store and iOS subscriptions | Your payment details, handled by Apple; we never see a card number |
| Cloudflare | All paid requests | Hosts our server and transports the request |

If you use local models or your own API keys, **none of this applies**. Your data does not touch our servers at all: the app talks to your provider directly, or to nothing at all when the model runs on your device. Choosing paid access is the only thing that routes your dictation through us.

## Sign in with Apple

Paid access requires signing in with Apple. We use it for one thing: to know which subscription belongs to you.

- We store the Apple user identifier for your account, and your email address if Apple shares it with us. Apple's Hide My Email relay address works normally.
- One Apple account is one subscription. The same account signed in on a direct-download Mac, a Mac App Store Mac, and an iPhone resolves to the same person and the same entitlement — you do not pay twice for a second device.
- Signing in does not create a profile of what you dictate. Your account record holds identity, subscription state and usage counts, and nothing about the content of your transcriptions.
- Signing out revokes that device's session. It does not cancel your subscription, and it does not affect local models or your own keys.

## How to cancel

How you cancel depends on where you subscribed, because that determines who takes the payment.

| Where you subscribed | How to cancel |
| --- | --- |
| Direct-download macOS build | Open the Stripe customer portal from the app's paid access settings, and cancel there |
| Mac App Store, iOS App Store, or TestFlight | Cancel in Apple's subscription settings: **Settings → your name → Subscriptions** on iPhone, or **App Store → Account → Settings** on Mac |

We cannot cancel an App Store subscription for you; only Apple can. Equally, cancelling in Apple's settings has no effect on a Stripe subscription, and vice versa.

When you cancel, paid access continues until the end of the period you have already paid for, then stops. Nothing is deleted from the app: your history, settings, local models and API keys are unaffected, and the app keeps working with local models or your own keys.

## Going back to your own keys or local models

At any time, in the app's transcription and post-processing settings, choose a local model or a provider you hold a key for. That is the whole procedure.

Switching away from paid access requires no contact with our server, no permission, and no waiting period. It works while your subscription is still active, after it lapses, while you are offline, and if our server is unavailable. If paid access is ever degraded or switched off for operational reasons, the app is expected to fall back to exactly this path — the feature does not disappear with it.

## FAQ

**Do you keep my recordings or transcripts?**
No. Audio and transcript text are proxied in memory to the provider and are not stored by us. We keep counts of usage, not content.

**Do you train models on my dictation?**
No. We do not train models, and we do not supply your data to anyone for training. The providers listed above handle your data under their own terms; if that matters to you, use a local model, where nothing leaves your device.

**Can I use paid access without signing in?**
No. A subscription has to belong to an account, and Sign in with Apple is the only identity we accept.

**I subscribed on my Mac. Do I have to pay again on my iPhone?**
No. Sign in with the same Apple account and the entitlement is already there.

**Is paid access better quality than my own key?**
Not inherently. It runs a fixed, current set of models chosen for good general results. If you have a key for a model you prefer, use it.

**Is paid access cheaper?**
It depends on how much you dictate. It is a flat monthly or yearly cost with a monthly allowance; your own key is metered by the provider. Heavy users of a cheap model may pay less with their own key, and local models cost nothing.

**What happens if I run out of my monthly allowance?**
Paid requests stop until the next period, with an explicit error rather than a silent charge. Local models and your own keys keep working.

**What happens if your server is down?**
Paid requests fail. Local models and your own keys are unaffected, because they never involve our server.

**Can you delete my account data?**
Subscription and usage history is append-only and kept for billing integrity, so it is not removed on request. It contains no audio or transcript text. Cancel your subscription, sign out, and nothing further is recorded about you.

**Who do I contact about this?**
See the contact address in [`PRIVACY.md`](PRIVACY.md).

> **TODO:** the paid access contact address is inherited from `PRIVACY.md`, which still carries a placeholder. Set a real address in both before publishing.

---

*Last updated: August 2026*
