import Foundation

/// Actionable reason a reference voice clip was rejected by `VoiceProfileQualityGate`.
public enum VoiceProfileQualityIssue: Codable, Equatable, Hashable, Sendable {
    case tooShort(actualSeconds: Double, minimumSeconds: Double)
    case tooLong(actualSeconds: Double, maximumSeconds: Double)
    case excessiveClipping(clippingRatio: Double, maximumRatio: Double)
    case insufficientSpeech(speechSeconds: Double, minimumSeconds: Double)
    case lowSignalToNoise(estimatedSNRDB: Double, minimumSNRDB: Double)
    case multipleSpeakersDetected

    public var userMessage: String {
        switch self {
        case .tooShort(let actual, let minimum):
            return String(
                format: "Clip is too short (%.1f s). Speak for at least %.0f seconds.",
                actual, minimum
            )
        case .tooLong(let actual, let maximum):
            return String(
                format: "Clip is too long (%.1f s). Keep each clip at or under %.0f seconds.",
                actual, maximum
            )
        case .excessiveClipping(let ratio, _):
            return String(
                format: "Audio is clipping (%.1f%% of samples peaked). Move slightly back from the mic or lower gain.",
                ratio * 100
            )
        case .insufficientSpeech(let speech, let minimum):
            return String(
                format: "Not enough clear speech detected (%.1f s active; need at least %.1f s).",
                speech, minimum
            )
        case .lowSignalToNoise(let snr, let minimum):
            return String(
                format: "Background noise is too high (estimated SNR %.0f dB; need at least %.0f dB).",
                snr, minimum
            )
        case .multipleSpeakersDetected:
            return "Multiple distinct voices appear to be in this clip. Record a single speaker."
        }
    }
}

/// Summary metrics and pass/fail issues produced by `VoiceProfileQualityGate`.
public struct VoiceProfileQualityReport: Codable, Equatable, Hashable, Sendable {
    public let passed: Bool
    public let durationSeconds: Double
    public let peakAmplitude: Double
    public let clippingRatio: Double
    public let estimatedSNRDB: Double
    public let activeSpeechSeconds: Double
    public let speechActivityRatio: Double
    public let issues: [VoiceProfileQualityIssue]

    public init(
        passed: Bool,
        durationSeconds: Double,
        peakAmplitude: Double,
        clippingRatio: Double,
        estimatedSNRDB: Double,
        activeSpeechSeconds: Double,
        speechActivityRatio: Double,
        issues: [VoiceProfileQualityIssue]
    ) {
        self.passed = passed
        self.durationSeconds = durationSeconds
        self.peakAmplitude = peakAmplitude
        self.clippingRatio = clippingRatio
        self.estimatedSNRDB = estimatedSNRDB
        self.activeSpeechSeconds = activeSpeechSeconds
        self.speechActivityRatio = speechActivityRatio
        self.issues = issues
    }

    public var rejectionReasons: [String] {
        issues.map(\.userMessage)
    }
}

/// Portable PCM quality gate checking duration, clipping, speech activity, SNR and single-speaker consistency.
public struct VoiceProfileQualityGate: Sendable {
    public let minimumDurationSeconds: Double
    public let maximumDurationSeconds: Double
    public let minimumActiveSpeechSeconds: Double
    public let minimumSpeechActivityRatio: Double
    public let clippingSampleThreshold: Float
    public let maximumClippingRatio: Double
    public let maximumConsecutiveClippedSamples: Int
    public let minimumSNRDB: Double
    public let minimumSpeakerSeparationSemitones: Double
    public let minimumSecondarySpeakerRatio: Double
    public let minimumSecondarySpeakerSeconds: Double
    public let minimumBimodalFisherRatio: Double

    public init(
        minimumDurationSeconds: Double = VoiceProfile.minimumClipDuration,
        maximumDurationSeconds: Double = VoiceProfile.maximumClipDuration,
        minimumActiveSpeechSeconds: Double = 2.5,
        minimumSpeechActivityRatio: Double = 0.25,
        clippingSampleThreshold: Float = 0.985,
        maximumClippingRatio: Double = 0.005,
        maximumConsecutiveClippedSamples: Int = 20,
        minimumSNRDB: Double = 12.0,
        minimumSpeakerSeparationSemitones: Double = 8.0,
        minimumSecondarySpeakerRatio: Double = 0.25,
        minimumSecondarySpeakerSeconds: Double = 1.2,
        minimumBimodalFisherRatio: Double = 3.0
    ) {
        self.minimumDurationSeconds = minimumDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.minimumActiveSpeechSeconds = minimumActiveSpeechSeconds
        self.minimumSpeechActivityRatio = minimumSpeechActivityRatio
        self.clippingSampleThreshold = clippingSampleThreshold
        self.maximumClippingRatio = maximumClippingRatio
        self.maximumConsecutiveClippedSamples = maximumConsecutiveClippedSamples
        self.minimumSNRDB = minimumSNRDB
        self.minimumSpeakerSeparationSemitones = minimumSpeakerSeparationSemitones
        self.minimumSecondarySpeakerRatio = minimumSecondarySpeakerRatio
        self.minimumSecondarySpeakerSeconds = minimumSecondarySpeakerSeconds
        self.minimumBimodalFisherRatio = minimumBimodalFisherRatio
    }

    public func evaluate(_ buffer: VoiceProfilePCMBuffer) -> VoiceProfileQualityReport {
        let duration = buffer.durationSeconds
        var issues: [VoiceProfileQualityIssue] = []

        if duration < minimumDurationSeconds {
            issues.append(.tooShort(actualSeconds: duration, minimumSeconds: minimumDurationSeconds))
        } else if duration > maximumDurationSeconds {
            issues.append(.tooLong(actualSeconds: duration, maximumSeconds: maximumDurationSeconds))
        }

        let clipping = measureClipping(in: buffer.samples)
        if clipping.ratio > maximumClippingRatio
            || clipping.maxConsecutive >= maximumConsecutiveClippedSamples {
            issues.append(.excessiveClipping(clippingRatio: clipping.ratio, maximumRatio: maximumClippingRatio))
        }

        let analysis = analyzeFrames(in: buffer.samples, sampleRate: buffer.sampleRate)
        if analysis.activeSeconds < minimumActiveSpeechSeconds
            || analysis.activityRatio < minimumSpeechActivityRatio
            || analysis.peakFrameDB < -38.0 {
            issues.append(
                .insufficientSpeech(speechSeconds: analysis.activeSeconds, minimumSeconds: minimumActiveSpeechSeconds)
            )
        } else {
            if analysis.estimatedSNRDB < minimumSNRDB {
                issues.append(.lowSignalToNoise(estimatedSNRDB: analysis.estimatedSNRDB, minimumSNRDB: minimumSNRDB))
            }
            if detectsMultipleSpeakers(pitchSemitones: analysis.voicedPitchSemitones, hopSeconds: analysis.hopSeconds) {
                issues.append(.multipleSpeakersDetected)
            }
        }

        return VoiceProfileQualityReport(
            passed: issues.isEmpty,
            durationSeconds: duration,
            peakAmplitude: clipping.peakAmplitude,
            clippingRatio: clipping.ratio,
            estimatedSNRDB: analysis.estimatedSNRDB,
            activeSpeechSeconds: analysis.activeSeconds,
            speechActivityRatio: analysis.activityRatio,
            issues: issues
        )
    }

    private struct ClippingStats {
        let peakAmplitude: Double
        let ratio: Double
        let maxConsecutive: Int
    }

    struct FrameAnalysis {
        let hopSeconds: Double
        let activeSeconds: Double
        let activityRatio: Double
        let peakFrameDB: Double
        let estimatedSNRDB: Double
        let voicedPitchSemitones: [Double]
    }

    private func measureClipping(in samples: [Float]) -> ClippingStats {
        guard !samples.isEmpty else {
            return ClippingStats(peakAmplitude: 0, ratio: 0, maxConsecutive: 0)
        }
        var peak: Float = 0
        var clippedCount = 0
        var consecutive = 0
        var maxConsecutive = 0

        for sample in samples {
            let magnitude = abs(sample.isFinite ? sample : 0)
            if magnitude > peak { peak = magnitude }
            if magnitude >= clippingSampleThreshold {
                clippedCount += 1
                consecutive += 1
                if consecutive > maxConsecutive { maxConsecutive = consecutive }
            } else {
                consecutive = 0
            }
        }
        let ratio = Double(clippedCount) / Double(samples.count)
        return ClippingStats(peakAmplitude: Double(peak), ratio: ratio, maxConsecutive: maxConsecutive)
    }
}
