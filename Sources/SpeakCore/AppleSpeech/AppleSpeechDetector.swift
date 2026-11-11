// SpeechDetector (OS 26+) voice-activity detection: the availability-free
// sensitivity type, the activity update it reports, and a SpeechAnalyzer
// session that runs the detector module on its own. The arming state machine
// these feed lives in HandsFreeDictation.swift.
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// How eagerly the hands-free voice-activity detector reports speech.
///
/// Mirrors `SpeechDetector.SensitivityLevel` so settings, policy and tests stay
/// availability-free; the gated extension below is the only bridge.
public enum AppleSpeechDetectorSensitivity: String, CaseIterable, Sendable, Equatable {
    case low
    case medium
    case high
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleSpeechDetectorSensitivity {
    var detectionOptions: SpeechDetector.DetectionOptions {
        SpeechDetector.DetectionOptions(sensitivityLevel: sensitivityLevel)
    }

    private var sensitivityLevel: SpeechDetector.SensitivityLevel {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

/// One voice-activity report from the detector.
public struct AppleSpeechActivityUpdate: Sendable, Equatable {
    public let speechDetected: Bool
    /// End of the analysed range, on the session's audio timeline.
    public let seconds: Double

    public init(speechDetected: Bool, seconds: Double) {
        self.speechDetected = speechDetected
        self.seconds = seconds
    }
}

/// A SpeechAnalyzer session running only `SpeechDetector`.
///
/// Hands-free arming keeps this running while the session is armed and starts a
/// separate transcription session once speech is detected, so nothing is
/// transcribed — and no transcript ever exists — while the user is silent.
@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechDetectorSession: @unchecked Sendable {
    public let audioFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let activityTask: Task<Void, Never>

    /// - Parameter onActivity: called for every detector report, on the
    ///   detector's task. Callers debounce with `HandsFreeVoiceActivityTracker`.
    public init(
        sensitivity: AppleSpeechDetectorSensitivity = HandsFreeDictationPolicy.sensitivity,
        onActivity: @escaping @Sendable (AppleSpeechActivityUpdate) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        let detector = SpeechDetector(
            detectionOptions: sensitivity.detectionOptions,
            reportResults: true
        )
        try await AppleSpeechAnalyzerTranscriber.ensureAssets(for: [detector])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [detector]
        ) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [detector])
        self.audioFormat = format
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.activityTask = Task {
            do {
                for try await result in detector.results {
                    onActivity(
                        AppleSpeechActivityUpdate(
                            speechDetected: result.speechDetected,
                            seconds: result.range.end.seconds
                        )
                    )
                }
                guard !Task.isCancelled else { return }
                onFailure(AppleLocalModelError.speechDetectorFailed)
            } catch {
                guard !Task.isCancelled else { return }
                onFailure(error)
            }
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            self.activityTask.cancel()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    public func send(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func cancel() async {
        activityTask.cancel()
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
    }
}
