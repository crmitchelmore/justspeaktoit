# Reliability Principles

1. **Rollback = previous mac-v* tag**: macOS distribution uses Sparkle appcast; re-tagging restores the prior build.
2. **Deployment gate**: Auto-release triggers on any `feat:`, `fix:`, `perf:` commit to main — no staging environment sits between code merge and production release.
3. **No canary**: macOS releases go immediately to all Sparkle update subscribers; blast radius is entire macOS user base on every release.
4. **iOS safe zone**: App Store review acts as a natural delay gate; TestFlight provides staged rollout.
5. **Monitoring**: Sentry EU (de.sentry.io, org: tally-lz, project: justspeaktoit) is the error-monitoring layer.
6. **Audio/transcription failure modes**: Any new transcription provider must handle: audio engine stop, mic permission denial, network disconnection mid-session.
7. **API key failure**: Keychain-backed secrets (SpeakCore `SecureStorage`) should have graceful degradation when key is missing — don't crash, surface an error state.
8. **CI reproducibility**: macOS builds run on `macos-15`, Xcode `latest-stable` — floating Xcode version is an environment drift risk.
