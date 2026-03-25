# Repository Context

## Durable facts for this role
- API keys are stored in keychain-backed storage and should not move into plaintext preferences or repository files.
- Permissions such as microphone, speech recognition, accessibility, local network, and optional iCloud keychain are central security boundaries.
- Transcript content and API keys are intentionally redacted from logs and Sentry output.
- Multiple cloud providers mean any off-device audio or text flow must be explicit and user-controllable.
- Build-time secrets such as the Sentry DSN come from local env or CI configuration, not from the repository.
- Workflow and automation changes on this private repo should avoid leaking private issue or user content.
