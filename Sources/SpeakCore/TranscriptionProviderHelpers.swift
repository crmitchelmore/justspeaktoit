import AVFoundation
import Foundation

// Small helpers that every transcription provider needs. They live here so the
// per-provider files stay focused on what is actually provider-specific.

extension String {
    /// The language portion of a locale identifier, lowercased.
    ///
    /// Transcription APIs expect ISO-639-1 (`"en"`), not a full locale, so
    /// `"en_GB"`, `"en-US"` and `"en"` all map to `"en"`.
    public var localeLanguageCode: String {
        let components = self.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? self.lowercased()
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
}
