# 02 — Extract SpeakCore (shared SwiftPM library)

## Goal
Create a shared `SpeakCore` SwiftPM target and move reusable code out of the macOS app target.

## Scope
- Add `SpeakCore` as a library target in `Package.swift`.
- Move platform-agnostic code into `Sources/SpeakCore/`.
- Keep macOS app building with minimal diffs.

## Steps
1. Update `Package.swift`:
   - platforms should include `.iOS(...)` in addition to `.macOS(...)`.
   - add `library` product for `SpeakCore`.
   - add new target `SpeakCore`.
   - make `SpeakApp` depend on `SpeakCore`.
2. Move (or duplicate-then-move) candidate files into `Sources/SpeakCore/`:
   - `TranscriptionManager` + provider registry + providers
   - `OpenRouterAPIClient`
   - shared models (`TranscriptionResult`, etc.)
   - *exclude* mac-only UI and output insertion.
3. Fix imports/visibility to keep API internal where possible.
4. Run `make build && make test`.

## Deliverables
- `SpeakCore` library target compiling.
- macOS app still compiles and tests run.

## Acceptance criteria
- `make build` succeeds.
- `make test` succeeds (or only pre-existing failures remain).
- `SpeakApp` depends on `SpeakCore` for shared logic.

---

## ✅ Complete (2026-01-08)

### Changes made
1. Updated `Package.swift`:
   - Added `.iOS(.v17)` platform
   - Added `SpeakCore` library target
   - Made `SpeakApp` depend on `SpeakCore`

2. Created `Sources/SpeakCore/` with shared types:
   - `LLMProtocols.swift` — `ChatMessage`, `TranscriptionResult`, `LiveTranscriptionController`, etc.
   - `APIKeyValidationResult.swift` — API key validation types
   - `DataExtensions.swift` — `Data` helpers for multipart form encoding
   - `ModelCatalog.swift` — model definitions and pricing
   - `TranscriptionProviderRegistry.swift` — protocol + metadata (registry actor stays in SpeakApp)
   - `SpeakCore.swift` — module marker

3. Updated ~20 files in SpeakApp to `import SpeakCore`

4. All types in SpeakCore are now `public` with `Sendable` conformance

### Build/Test
- `make build` — **PASS**
- `make test` — **PASS** (4 tests, 0 failures)
