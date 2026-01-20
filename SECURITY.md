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
- **No telemetry**: The app does not collect or transmit user data
- **Local processing**: Transcription can be performed entirely on-device
- **Minimal permissions**: Only requests necessary permissions (microphone, accessibility)

## Scope

This policy covers:
- The Just Speak to It macOS and iOS applications
- Build scripts and configuration files in this repository

Out of scope:
- Third-party dependencies (report to their maintainers)
- User-configured API endpoints
