#if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
import AVFoundation
#endif
import Foundation

// Small helpers that every transcription provider needs. They live here so the
// per-provider files stay focused on what is actually provider-specific.

extension String {
    /// The language portion of a locale identifier, lowercased.
    ///
    /// Transcription APIs expect ISO-639-1 (`"en"`), not a full locale, so
    /// `"en_GB"`, `"en-US"` and `"en"` all map to `"en"`.
    public var localeLanguageCode: String {
        // Trim first: `" en-US "` must yield `"en"`, not `" en"` — the value goes
        // straight into provider query parameters.
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? normalized.lowercased()
    }
}

/// Turns the speaker identifiers providers return (`"speaker_0"`, `"Speaker 1"`, `"Alice"`)
/// into display labels.
public enum SpeakerLabelNormalizer {
    /// - Parameters:
    ///   - value: Raw speaker identifier from the provider; `nil`/blank yields `nil`.
    ///   - spacedFormIsIndexed: Whether the space-separated form (`"speaker 0"`) is a
    ///     zero-based index like the underscore form, or is already a display label
    ///     that only needs capitalising. Providers disagree, so each one says which.
    public static func displayLabel(for value: String?, spacedFormIsIndexed: Bool) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let uppercased = raw.uppercased()
        if uppercased.hasPrefix("SPEAKER_") || (spacedFormIsIndexed && uppercased.hasPrefix("SPEAKER ")) {
            let digits = raw.filter(\.isNumber)
            if let index = Int(digits) {
                return "Speaker \(index + 1)"
            }
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if uppercased.hasPrefix("SPEAKER ") {
            return raw.capitalized
        }
        return raw
    }
}

#if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
/// Resolves the duration to report for a transcription, preferring what the provider
/// said, then the last timestamp it emitted, and finally the audio file itself.
public func resolvedTranscriptionDuration(
    reported: TimeInterval?,
    lastSegmentEnd: TimeInterval?,
    audioURL: URL
) async -> TimeInterval {
    if let reported, reported > 0 {
        return reported
    }
    if let lastSegmentEnd, lastSegmentEnd > 0 {
        return lastSegmentEnd
    }
    let asset = AVURLAsset(url: audioURL)
    guard let durationTime = try? await asset.load(.duration), durationTime.seconds.isFinite else {
        return 0
    }
    return durationTime.seconds
}

#endif

/// WebSocket teardown races surface as ENOTCONN ("socket is not connected"); every
/// live transcriber ignores them rather than surfacing a spurious error to the user.
public enum WebSocketErrorFilter {
    public static func shouldIgnore(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { // ENOTCONN
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected")
    }

    /// An ignorable failure that carries no peer close frame. A receive that
    /// reports the server's close code is the stream's real end, never noise,
    /// even when the transport describes it as a lost socket.
    public static func isSpuriousDisconnect(_ error: Error) -> Bool {
        guard (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode == nil else { return false }
        return shouldIgnore(error)
    }
}

/// ENOTCONN can be reported spuriously around a WebSocket handshake, so a
/// shared client re-arms its receive after one instead of ending the session.
/// Only a bounded run of consecutive ignorable failures is tolerated: a socket
/// that keeps failing is lost, and the client then reaches a terminal outcome
/// rather than spinning on it. The count bound keeps the window finite under a
/// test scheduler that never advances the clock.
struct IgnoredReceiveFailureWindow: Sendable {
    /// Delay before the receive is re-armed after an ignorable failure.
    static let retryDelay: TimeInterval = 0.01
    static let defaultWindow: TimeInterval = 1.5

    let window: TimeInterval
    private var firstFailure: TimeInterval?
    private var retries = 0

    init(window: TimeInterval = IgnoredReceiveFailureWindow.defaultWindow) {
        self.window = window.isFinite ? max(0, window) : Self.defaultWindow
    }

    /// Records one ignorable failure and answers whether the receive may be
    /// re-armed once more.
    mutating func allowsRetry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let first = firstFailure ?? now
        firstFailure = first
        retries += 1
        let maximumRetries = max(1, Int((window / Self.retryDelay).rounded(.up)))
        return now - first < window && retries <= maximumRetries
    }

    /// A delivered frame ends the run of failures.
    mutating func reset() {
        firstFailure = nil
        retries = 0
    }
}
