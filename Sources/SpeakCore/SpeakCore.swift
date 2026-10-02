// SpeakCore — Shared library for macOS and iOS Speak apps
// This module contains cross-platform transcription, API clients, and secure storage.

import Foundation
// SpeakWatchCore holds the Foundation-only watch and release-train types that
// the watchOS targets link directly (issue #1123). Re-exporting it keeps every
// existing `import SpeakCore` consumer compiling unchanged.
@_exported import SpeakWatchCore

/// Version marker for SpeakCore module
public enum SpeakCore {
    public static let version = "1.0.0"
}
