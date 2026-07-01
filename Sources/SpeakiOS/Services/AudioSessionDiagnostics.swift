import Foundation

/// Immutable snapshot of the audio session state captured at the moment audio
/// configuration fails.
///
/// Deliberately free of AVFoundation so it compiles and is unit-testable on
/// every platform; `AudioSessionManager` populates it from the live
/// `AVAudioSession` on iOS. Modelled as a Data Transfer Object: a plain carrier
/// of already-resolved primitive values, not a live view onto the session.
public struct AudioSessionDiagnostics: Sendable, Equatable {
    public let category: String
    public let mode: String
    public let options: String
    public let isOtherAudioPlaying: Bool
    public let inputRoute: String
    public let outputRoute: String

    public init(
        category: String,
        mode: String,
        options: String,
        isOtherAudioPlaying: Bool,
        inputRoute: String,
        outputRoute: String
    ) {
        self.category = category
        self.mode = mode
        self.options = options
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.inputRoute = inputRoute
        self.outputRoute = outputRoute
    }

    /// One-line, log-friendly description of the captured session state.
    public var summary: String {
        "category=\(category) mode=\(mode) options=[\(options)] "
            + "otherAudioPlaying=\(isOtherAudioPlaying) "
            + "input=\(inputRoute) output=\(outputRoute)"
    }
}

/// Rich diagnostic error thrown when the audio session cannot be configured for
/// recording.
///
/// The previous behaviour wrapped the raw `NSError` and only surfaced its
/// generic `localizedDescription`, which discarded the useful `OSStatus` code
/// that `AVAudioSession` reports. This type preserves the underlying error and
/// renders it as a decoded FourCC (e.g. `561145187` → `'!rec'` →
/// `cannotStartRecording`) alongside a snapshot of the session state, so
/// hard-to-reproduce "why did recording fail" reports are diagnosable from
/// logs alone.
public struct AudioSessionConfigurationError: LocalizedError {
    /// The `AVAudioSession` call that threw.
    public enum Operation: String, Sendable {
        case setCategory
        case setActive
    }

    public let operation: Operation
    public let underlying: NSError
    public let diagnostics: AudioSessionDiagnostics

    public init(operation: Operation, underlying: NSError, diagnostics: AudioSessionDiagnostics) {
        self.operation = operation
        self.underlying = underlying
        self.diagnostics = diagnostics
    }

    /// Decoded description of the underlying error code, including its FourCC
    /// interpretation and a known `AVAudioSession.ErrorCode` name where one is
    /// recognised.
    public var codeSummary: String {
        var parts: [String] = []
        if let fourCC = Self.fourCharCode(from: underlying.code) {
            if let name = Self.knownErrorName(forFourCC: fourCC) {
                parts.append(name)
            }
            parts.append("'\(fourCC)'")
        }
        parts.append("code \(underlying.code)")
        parts.append("domain \(underlying.domain)")
        return parts.joined(separator: ", ")
    }

    public var errorDescription: String? {
        "Audio session \(operation.rawValue) failed [\(codeSummary)]. "
            + "State: \(diagnostics.summary). "
            + "Underlying: \(underlying.localizedDescription)"
    }

    public var recoverySuggestion: String? {
        "Another app may own the microphone. Close music, podcast, call or "
            + "voice apps, disconnect Bluetooth audio, then try again."
    }

    // MARK: - OSStatus decoding

    /// Decodes an `OSStatus`/`NSError` code as a four-character code when its
    /// bytes are printable ASCII. `AVAudioSession` reports errors this way
    /// (e.g. `'!rec'`), whereas plain numeric codes such as `-50` are not
    /// FourCCs and return `nil`.
    public static func fourCharCode(from code: Int) -> String? {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        // Require every byte to be printable ASCII (space…tilde); otherwise the
        // code is a plain integer, not a FourCC.
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Human-readable name for the well-known `AVAudioSession.ErrorCode` FourCCs
    /// most relevant to a failed recording start.
    public static func knownErrorName(forFourCC fourCC: String) -> String? {
        knownErrorNames[fourCC]
    }

    private static let knownErrorNames: [String: String] = [
        "!int": "cannotInterruptOthers",
        "!pla": "cannotStartPlaying",
        "!rec": "cannotStartRecording",
        "!pri": "insufficientPriority",
        "siri": "siriIsRecording",
        "msrv": "mediaServicesFailed",
        "what": "unspecified"
    ]
}
