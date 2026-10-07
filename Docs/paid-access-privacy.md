# Paid Access: what it does and what data it uses

This document describes the authored, disabled paid-access implementation. External identity, billing products, privacy operations and staging qualification remain open; this is not a launch or commissioning claim.

This document covers the optional paid access subscription only. General app data handling is in [`PRIVACY.md`](PRIVACY.md). Operators should also read [`paid-access.md`](paid-access.md).

## You do not need to subscribe

On-device local models and your own API keys are the default in Just Speak to It, and they remain fully supported. They are not a trial, a reduced tier, or a legacy path.

- **Local models** run on your Mac or iPhone. Audio never leaves the device, and there is nothing to pay.
- **Your own API keys** (bring your own, or BYO) talk directly from your device to the provider you chose. Your keys stay in the Keychain and are never sent to us.
- **Paid access** is a convenience. It exists so that you can use cloud transcription without creating accounts with vendors, holding API keys, or managing your own billing.

Paid access does not unlock any feature, model, or quality of output that you cannot reach by supplying your own key or using a local model. Depending on how much you dictate, using your own key is often cheaper, and local models are free. If you already have a provider account, you probably do not need this.

## What paid access actually does

When paid access is switched on, your audio or text is sent to our server, which forwards it to a named provider using **our** credentials, and returns the result to you. That is the whole mechanism: we stand between you and the provider so that you do not have to hold an API key.

We choose the model. Paid requests name an operation — recorded transcription, or post-processing — and our server decides which provider and model runs it. The app shows you the current choice; it cannot change it. That keeps costs predictable and means we can move a route if a provider degrades.

| What you are doing | Who processes it | Measured in |
| --- | --- | --- |
| Recorded (batch) transcription | OpenRouter, model `google/gemini-2.0-flash-001` | Audio seconds |
| Post-processing of transcript text | OpenRouter, model `openai/gpt-5-mini` | Tokens |

**Live (streaming) dictation does not use paid access.** As you speak, the app transcribes with an on-device model or with your own API key exactly as it does without a subscription. Only a completed recording, or transcript text being cleaned up, is sent to us.

To be precise about that rather than merely reassuring: our server does implement a live transcription route, and it is metered and documented like the others, but no released version of the app opens it. Nothing you say is streamed to us today. If we ever wire it up, this page changes first.

**Paid access is a macOS feature today.** The iPhone app does not offer a subscription and does not route anything through our servers; it transcribes on device or with your own key.

If an operation has no supported paid route, the request is completed through your own key or local model instead. It is never quietly redirected to a different paid model.

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
| Operation and settlement metadata | Yes | Yes; opaque request/reservation identifiers, route, billing period, allowance hold, measured counts when known, status and timestamps |
| Sign-in session records | Yes | Yes; refresh tokens are stored only as a SHA-256 hash |

Audio and transcript text pass through our server in memory and are not written to any database, object store, or log. What reaches our usage records is a count — how many seconds of audio, how many tokens — never the content those numbers describe.

The per-account quota service retains metadata-only settlement receipts. A receipt may be waiting for the usage ledger, or may hold allowance because a provider started and its measured outcome is unknown. A hold is not reported as measured usage. Explicit zero usage releases the hold and records zero; missing usage does neither. No receipt stores audio, prompts, transcript text or provider response content.

Your subscription history and usage records are append-only: they can be added to but not edited or deleted, including by us. That makes billing auditable. It also means a correction is recorded as a new entry rather than by rewriting the past.

### How long we keep it

Audio, transcript text, and post-processing prompts are never written down at all, so there is nothing to keep: they exist only in memory for the duration of the request.

Identity and settlement metadata have no automatic deletion schedule and remain until manual intervention. Append-only subscription and usage history cannot be deleted through the service. Short-lived request claims are pruned automatically; retained settlement receipts and usage history continue to prevent the same logical operation being dispatched or charged again after those claims expire. There is no delete or manual settlement endpoint. Unknown provider outcomes require an operator decision before commissioning; the service does not invent a charge, release the hold or retry the provider automatically.

Two consequences worth being explicit about:

- **Subscription history, usage counts, and audit records cannot be deleted, by you or by us.** The database physically rejects updates and deletions on those tables, which is what makes billing auditable. They contain counts and state transitions — never audio or transcript text.
- **A supported account anonymisation/deletion procedure is not implemented or qualified.** Required identity fields and relationships mean we cannot describe clearing ordinary rows as a supported removal process. This remains a gate before commissioning.

To ask for that, email **privacy@justspeaktoit.com** from the address linked to your account, or quote a recent `x-correlation-id`. The same address handles questions about what we hold. A supported handling procedure must be qualified before commissioning; this source does not establish a deletion timetable.

If none of this appeals, the alternative is complete and always available: use a local model or your own API key, and no record of any kind is created on our side.

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
| OpenRouter | Recorded transcription | The audio you recorded |
| OpenRouter | Post-processing | The transcript text and your post-processing prompt |
| Stripe | Direct-download macOS subscriptions | Your payment details, handled by Stripe; we never see a card number |
| Apple | Mac App Store subscriptions | Your payment details, handled by Apple; we never see a card number |
| Cloudflare | All paid requests | Hosts our server and transports the request |

If you use local models or your own API keys, **none of this applies**. Your data does not touch our servers at all: the app talks to your provider directly, or to nothing at all when the model runs on your device. Choosing paid access is the only thing that routes your dictation through us.

## Sign in with Apple

Paid access requires signing in with Apple. We use it for one thing: to know which subscription belongs to you.

- We store the Apple user identifier for your account, and your email address if Apple shares it with us. Apple's Hide My Email relay address works normally.
- One Apple account is one subscription. The same account signed in on a direct-download Mac and on a Mac App Store Mac resolves to the same person and the same entitlement — you do not pay twice for a second Mac.
- Signing in does not create a profile of what you dictate. Your account record holds identity, subscription state and usage counts, and nothing about the content of your transcriptions.
- Signing out revokes that device's session. It does not cancel your subscription, and it does not affect local models or your own keys.

## How to cancel

How you cancel depends on where you subscribed, because that determines who takes the payment.

| Where you subscribed | How to cancel |
| --- | --- |
| Direct-download macOS build | Open the Stripe customer portal from the app's paid access settings, and cancel there |
| Mac App Store or TestFlight | Cancel in Apple's subscription settings: **App Store → Account → Settings** on Mac, or **Settings → your name → Subscriptions** on iPhone |

We cannot cancel an App Store subscription for you; only Apple can. Equally, cancelling in Apple's settings has no effect on a Stripe subscription, and vice versa.

When you cancel, paid access continues until the end of the period you have already paid for, then stops. Nothing is deleted from the app: your history, settings, local models and API keys are unaffected, and the app keeps working with local models or your own keys.

## Going back to your own keys or local models

At any time, in the app's transcription and post-processing settings, choose a local model or a provider you hold a key for. That is the whole procedure.

Switching away from paid access requires no contact with our server, no permission, and no waiting period. It works while your subscription is still active, after it lapses, while you are offline, and if our server is unavailable. A confirmed refusal before provider dispatch can fall back to your configured path. Once a submitted request may have reached a provider, an uncertain response stops that operation and retains its request identity rather than silently sending it to another provider. Choosing a different route for a genuinely new operation remains available.

## FAQ

**Do you keep my recordings or transcripts?**
No. Audio and transcript text are proxied in memory to the provider and are not stored by us. We keep counts of usage, not content.

**Do you train models on my dictation?**
No. We do not train models, and we do not supply your data to anyone for training. The providers listed above handle your data under their own terms; if that matters to you, use a local model, where nothing leaves your device.

**Can I use paid access without signing in?**
No. A subscription has to belong to an account, and Sign in with Apple is the only identity we accept.

**I subscribed on my Mac. Does it work on my iPhone?**
Not yet. The iPhone app does not use paid access at all: it transcribes on device or with your own API key. Your subscription is not charged twice and nothing changes for it — there is simply nothing on iPhone that routes through us.

**Is paid access better quality than my own key?**
Not inherently. It runs a fixed, current set of models chosen for good general results. If you have a key for a model you prefer, use it.

**Is paid access cheaper?**
It depends on how much you dictate. It is a flat monthly or yearly cost with a monthly allowance; your own key is metered by the provider. Heavy users of a cheap model may pay less with their own key, and local models cost nothing.

**What happens if I run out of my monthly allowance?**
A new operation refused before provider dispatch can use your configured model — your own key, or an on-device model. Existing in-progress or uncertain operations retain their identity and do not dispatch again. Settings distinguish occupied allowance from measured usage and outstanding holds; an older service may not supply that breakdown.

**What happens if your server is down?**
If a submitted operation loses its response, the app reports an uncertain outcome and does not silently spend again through your own key. A confirmed pre-dispatch refusal may fall back. Local models and your own keys remain available for new operations without involving our server.

**Can you delete my account data?**
A supported account anonymisation/deletion procedure is not implemented or qualified and remains a commissioning gate. Subscription and usage history reject deletion and contain counts and state transitions, never audio or transcript text. New paid requests require a valid session; cancelling or signing out does not erase prior records, and previously admitted work or settlement reconciliation may still complete.

**Who do I contact about this?**
Email **privacy@justspeaktoit.com**.

---

*Last updated: 2 October 2026 (authored, disabled source)*
