// The retired SpeechDetector-only hands-free session. Hands-free arming now
// uses HandsFreeVoiceActivitySession, an on-device energy gate (#1553).
import AVFoundation
import Foundation

/// Formerly a `SpeechAnalyzer` running only `SpeechDetector`.
///
/// macOS 27 reports an empty audio format for a detector-only analyzer and
/// traps the process when one starts ("Cannot create SpeechDetector-only
/// worker"), so this type never starts one. It is kept only for source
/// compatibility of SpeakCore's public API and always fails to initialise.
@available(macOS 26.0, iOS 26.0, *)
@available(*, deprecated, message: "Use HandsFreeVoiceActivitySession; detector-only analyzers trap on macOS 27.")
public final class AppleSpeechDetectorSession: @unchecked Sendable {
    public let audioFormat: AVAudioFormat

    /// Always throws ``AppleLocalModelError/speechDetectorUnavailable``
    /// without starting a `SpeechAnalyzer`.
    public init(
        sensitivity: AppleSpeechDetectorSensitivity = HandsFreeDictationPolicy.sensitivity,
        onActivity: @escaping @Sendable (AppleSpeechActivityUpdate) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        throw AppleLocalModelError.speechDetectorUnavailable
    }

    public func send(_ buffer: AVAudioPCMBuffer) {}

    public func cancel() async {}
}
