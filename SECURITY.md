# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email the maintainers directly or use GitHub's private vulnerability reporting
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 7 days
- **Resolution target**: Within 30 days for critical issues

## Security Best Practices

This app follows these security practices:

- **Keychain storage**: All API keys and secrets are stored in the macOS/iOS Keychain
- **Privacy-scoped diagnostics**: Production macOS builds send anonymous crash,
  performance, and app-session diagnostics to Sentry EU. Default PII collection
  is disabled, automatic HTTP-error capture is limited to the app's own update
  domain, and every event is scrubbed of credentials before transmission, so
  transcript content and API keys are not included.
  The iOS app does not currently initialise Sentry or another developer-operated
  analytics SDK.
- **Consent-gated product analytics**: The direct-download macOS build can send a
  small typed event catalogue to PostHog EU only after explicit opt-in. Opt-out
  purges the random analytics identity and bounded local queue. The transport is
  compiled out of Mac App Store, iOS and keyboard builds.
- **Local processing**: Transcription can be performed entirely on-device
- **Minimal permissions**: Only requests necessary permissions (microphone, accessibility)
- **Debug UI redaction**: API keys and sensitive headers are automatically redacted in debug displays to prevent accidental exposure in screenshots or screen sharing

## Scope

This policy covers:
- The Just Speak to It macOS and iOS applications
- Build scripts and configuration files in this repository

Out of scope:
- Third-party dependencies (report to their maintainers)
- User-configured API endpoints
