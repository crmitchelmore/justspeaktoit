# Repository Context

## Project
**justspeaktoit** — cross-platform (macOS + iOS) voice transcription app built in Swift. macOS releases are automated via conventional commits (`feat:`, `fix:`, `perf:`). iOS releases are manual via workflow dispatch.

## Planning cadence
- Planning triggered by `planning:` labels or `/doit` commands on issues.
- Seven technical reviewer roles: Product (Alex), Security (Priya), Performance (Theo), Code Quality (Casey), Architecture (Morgan), Reliability (Jordan), Design (Riley).
- EM (Sam) facilitates; does not approve or block.

## Key architectural facts
- `SpeakCore` — shared cross-platform library.
- `SpeakApp` — macOS executable.
- `SpeakiOSLib` — iOS library (must be `public` for Xcode access).
- Keychain via `SecureStorage` / `SecureAppStorage`.
- AssemblyAI for streaming transcription (v3 WebSocket).
- Sentry EU region for error monitoring.

## Recurring themes (to populate)
- (To be filled as issues close)
