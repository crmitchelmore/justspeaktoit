# Recent Decisions

## 2026-04-08 — Issue #270 (Apple live transcription clears text)
Approved. Scoped to `iOSLiveTranscriber.swift`. Existing `committedText` pattern is right seam; close error-path gap and short-utterance threshold. No cross-module changes.

## 2026-04-08 — Issue #246 (Incremental transcript append)
Approved. Scoped to `TranscriptionManager.swift`. Deepgram path append-only; AssemblyAI replace/append branches — rebuild on replace, append otherwise. No module boundary changes.

## 2026-04-08 — PR #277 / PR #284 / PR #271 (inaccessible PRs)
PRs #277, #284, #271 not accessible via GitHub API. Same pattern as #209, #252. No action per protocol.

## 2026-04-09 — Issue #263 (O(1) HistoryManager stats/WAL)
Approved. Single file, single module. WAL fix uses `pendingWrites`; stats wires existing unused methods. New `effectiveDuration(for:)` helper aligns incremental/full behavior. No new seams.

## 2026-04-09 — Issue #283 (fix(ios): add missing SpeakCore import)
Approved. One-line fix: `import SpeakCore` in `SpeakiOSApp/SpeakiOSApp.swift`. `OpenClawClient.Conversation` (line 93) is defined in `SpeakCore`. Direct import is correct; rejected `@_exported import` in SpeakiOSLib (widens library surface). PR #282 was closed without merge — fix still outstanding.

## Recurring pattern: inaccessible PRs
PRs #209, #252, #256, #277, #282, #284, #271 all return empty from GitHub API (merged/deleted/converted). Cannot verify; no action. Do-nothing is correct response per protocol.
