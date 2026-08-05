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
- Automatic session tracking: enabled by the Sentry SDK default
- Automatic breadcrumbs: enabled
- Failed HTTP-request capture: enabled
- Default PII collection: disabled

Debug builds and XCTest runs initialise the SDK in disabled mode and do not send
events.

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
