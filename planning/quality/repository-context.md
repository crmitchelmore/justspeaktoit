# Repository Context

## Durable facts for this role
- Build, lint, and test flows run through Make, SwiftPM, SwiftLint, SwiftFormat, UI tests, and snapshot tests.
- The codebase uses manager and service abstractions with protocol-driven injection for testability.
- Some views and managers are large, so quality reviews should resist adding more incidental complexity there.
- Sensitive logging, entitlements, and live-transcription reuse already have tests that should be extended when those areas move.
- Platform-specific behaviour should be verified with the right macOS or iOS tests instead of vague manual assurances.
- Quality improvements should fit the existing Swift package structure and naming patterns.
