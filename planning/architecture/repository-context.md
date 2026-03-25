# Repository Context

## Durable facts for this role
- The architecture is split between shared core logic and platform-specific app layers.
- MainManager orchestrates recording, transcription, post-processing, output, and history, so architectural changes should respect that flow.
- Provider registries and injected managers are the intended extension points for new capabilities.
- Global state is intentionally limited; new work should avoid ad hoc cross-module coupling.
- Platform capabilities differ, so cross-platform logic should stay shared while platform integrations remain local to each app target.
- Release and update flows span Sparkle, Homebrew, App Store, and TestFlight, so lifecycle implications matter during planning.
