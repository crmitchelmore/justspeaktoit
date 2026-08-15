# Sentry Configuration

Just Speak to It uses Sentry for anonymous macOS reliability diagnostics. The
iOS app does not currently initialise Sentry.

## Runtime configuration

`Sources/SpeakApp/SentryManager.swift` owns the runtime configuration and starts
Sentry when the macOS app launches. The production DSN points to the project's
EU Sentry ingest endpoint and is intentionally safe to embed in the client; it
permits event ingestion, not authenticated access to Sentry data.

Production macOS builds currently configure:

- Environment: `production`
- Release: `justspeaktoit-mac@<version>+<build>`
- Performance trace sample rate: 20%
- Automatic session tracking: enabled, 30-second background interval
- Automatic breadcrumbs: enabled, network breadcrumbs included, 100 kept
- Network performance tracking: enabled
- Failed HTTP-request capture: enabled for `justspeaktoit.com` only
- Credential redaction: `beforeSend` and `beforeBreadcrumb` scrub every event
- Default PII collection: disabled

Every value above is set explicitly in `SentryManager.configure`, even where it
matches the current SDK default, so a Sentry update cannot widen collection
through a changed default. `SentryManagerTests` asserts each one.

Debug builds and XCTest runs initialise the SDK in disabled mode and do not send
events.

## Credential redaction

The app authenticates to transcription and speech providers with header names the
SDK sanitiser does not know (`xi-api-key`, `x-gladia-key`,
`Ocp-Apim-Subscription-Key`), and two providers carry the key in the URL query
(`token`, `api_key`). Two controls keep those credentials on the device:

1. `failedRequestTargets` restricts automatic HTTP-error capture to the app's own
   update domain, so no provider response is captured.
2. `SentryEventScrubber`, installed as `beforeSend` and `beforeBreadcrumb`,
   redacts request headers, URL query items, query strings, cookies, breadcrumb
   data, contexts, tags and extra data of every event.

Both use `SpeakCore`'s `SensitiveHeaderRedactor`, which is the single registry of
credential-carrying names. A new provider header or query item belongs there and
nowhere else.

## Privacy requirements

Sentry events must never contain transcript text, microphone audio, clipboard
contents, API keys, authorization headers, email addresses, names, or other
free-form user content. Prefer bounded error codes, counts, durations, and
provider/model identifiers when adding diagnostic context.

The SDK creates a persistent random installation ID for session health. The app
does not currently call `SentryManager.setUser`, so it does not attach a known
user identity.

Any change to Sentry collection must also update:

- `Docs/PRIVACY.md`
- `SECURITY.md`
- The relevant Apple privacy manifest and App Store privacy answers

## Release integration

The macOS release workflow optionally uses authenticated Sentry CI secrets to
create a release and upload debug symbols. These server-side credentials are
separate from the client DSN and must remain in GitHub Actions secrets.

## Validation

Before shipping a telemetry change:

1. Confirm debug and test builds remain disabled.
2. Inspect a production-format event and verify that user-generated content and
   credentials are absent.
3. Confirm `sendDefaultPii` remains disabled.
4. Confirm the privacy documentation, manifest, and App Store answers match the
   actual platform behaviour.
