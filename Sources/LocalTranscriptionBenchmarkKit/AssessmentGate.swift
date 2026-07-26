import Foundation

public struct LocalTranscriptionAssessmentPolicy: Codable, Equatable, Sendable {
    public let maximumRelativeWordErrorRegression: Double
    public let minimumPerformanceImprovement: Double
    public let requiredCorpusTags: [String]

    public init(
        maximumRelativeWordErrorRegression: Double = 0.05,
        minimumPerformanceImprovement: Double = 0.20,
        requiredCorpusTags: [String] = ["accent", "long", "multilingual", "noise", "silence"]
    ) {
        self.maximumRelativeWordErrorRegression = maximumRelativeWordErrorRegression
        self.minimumPerformanceImprovement = minimumPerformanceImprovement
        self.requiredCorpusTags = requiredCorpusTags
    }
}

public struct LocalTranscriptionAssessmentEvidence: Codable, Equatable, Sendable {
    public let directBuildPassed: Bool
    public let appStoreBuildPassed: Bool
    public let cancellationPassed: Bool
    public let longRecordingPassed: Bool
    public let silencePassed: Bool
    public let capabilityGain: String?
    public let modelArtifacts: [LocalTranscriptionModelArtifactEvidence]

    public init(
        directBuildPassed: Bool,
        appStoreBuildPassed: Bool,
        cancellationPassed: Bool,
        longRecordingPassed: Bool,
        silencePassed: Bool,
        capabilityGain: String? = nil,
        modelArtifacts: [LocalTranscriptionModelArtifactEvidence]
    ) {
        self.directBuildPassed = directBuildPassed
        self.appStoreBuildPassed = appStoreBuildPassed
        self.cancellationPassed = cancellationPassed
        self.longRecordingPassed = longRecordingPassed
        self.silencePassed = silencePassed
        self.capabilityGain = capabilityGain
        self.modelArtifacts = modelArtifacts
    }
}

public struct LocalTranscriptionModelArtifactEvidence: Codable, Equatable, Sendable {
    public let identifier: String
    public let url: String
    public let sha256: String
    public let sizeBytes: UInt64
    public let license: String

    public init(identifier: String, url: String, sha256: String, sizeBytes: UInt64, license: String) {
        self.identifier = identifier
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.license = license
    }

    public var isComplete: Bool {
        guard let artifactURL = URL(string: url) else { return false }
        return !identifier.isEmpty
            && artifactURL.scheme == "https"
            && artifactURL.host != nil
            && sha256.count == 64
            && sha256.allSatisfy(\.isHexDigit)
            && sizeBytes > 0
            && !license.isEmpty
    }
}

public struct LocalTranscriptionAssessmentDecision: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case proceed
        case reject
        case insufficientEvidence = "insufficient-evidence"
    }

    public let status: Status
    public let baseline: LocalTranscriptionBenchmarkSummary
    public let candidate: LocalTranscriptionBenchmarkSummary
    public let relativeWordErrorRegression: Double
    public let latencyImprovement: Double
    public let memoryImprovement: Double
    public let reasons: [String]
}

public enum LocalTranscriptionAssessmentGate {
    public static func evaluate(
        baseline: LocalTranscriptionBenchmarkReport,
        candidate: LocalTranscriptionBenchmarkReport,
        evidence: LocalTranscriptionAssessmentEvidence,
        policy: LocalTranscriptionAssessmentPolicy = .init()
    ) -> LocalTranscriptionAssessmentDecision {
        let baselineSummary = baseline.summary
        let candidateSummary = candidate.summary
        let wordErrorRegression = relativeRegression(
            baseline: baselineSummary.wordErrorRate,
            candidate: candidateSummary.wordErrorRate
        )
        let latencyImprovement = relativeImprovement(
            baseline: baselineSummary.medianWallSeconds,
            candidate: candidateSummary.medianWallSeconds
        )
        let memoryImprovement = relativeImprovement(
            baseline: baselineSummary.peakResidentMemoryMB,
            candidate: candidateSummary.peakResidentMemoryMB
        )

        var rejectionReasons: [String] = []
        var missingEvidence: [String] = []

        if wordErrorRegression > policy.maximumRelativeWordErrorRegression {
            rejectionReasons.append("Candidate WER exceeds the allowed 5% relative regression.")
        }
        if baselineSummary.failureCount > 0 || candidateSummary.failureCount > 0 {
            rejectionReasons.append("One or more benchmark cases failed.")
        }

        let hasPerformanceGain = latencyImprovement >= policy.minimumPerformanceImprovement
            || memoryImprovement >= policy.minimumPerformanceImprovement
        let hasCapabilityGain = !(
            evidence.capabilityGain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        )
        if !hasPerformanceGain && !hasCapabilityGain {
            rejectionReasons.append("Candidate has neither a 20% performance gain nor a documented capability gain.")
        }

        let candidateTags = Set(candidateSummary.tagCoverage)
        let missingTags = policy.requiredCorpusTags.filter { !candidateTags.contains($0) }
        if !missingTags.isEmpty {
            missingEvidence.append("Corpus is missing required tags: \(missingTags.joined(separator: ", ")).")
        }
        if Set(baseline.measurements.map(\.caseID)) != Set(candidate.measurements.map(\.caseID)) {
            missingEvidence.append("Baseline and candidate did not run the same cases.")
        }
        if baseline.engine != .whisperKit {
            missingEvidence.append("Baseline report must use WhisperKit.")
        }
        if candidate.engine != .transcribeCpp {
            missingEvidence.append("Candidate report must use transcribe.cpp.")
        }
        if !evidence.directBuildPassed { missingEvidence.append("Direct macOS build is not verified.") }
        if !evidence.appStoreBuildPassed { missingEvidence.append("Mac App Store build is not verified.") }
        if !evidence.cancellationPassed { missingEvidence.append("Cancellation is not verified.") }
        if !evidence.longRecordingPassed { missingEvidence.append("Long recordings are not verified.") }
        if !evidence.silencePassed { missingEvidence.append("Silence handling is not verified.") }
        if evidence.modelArtifacts.isEmpty || !evidence.modelArtifacts.allSatisfy(\.isComplete) {
            missingEvidence.append("Every candidate model needs URL, SHA-256, size, and license evidence.")
        }

        let status: LocalTranscriptionAssessmentDecision.Status
        let reasons: [String]
        if !missingEvidence.isEmpty {
            status = .insufficientEvidence
            reasons = rejectionReasons + missingEvidence
        } else if !rejectionReasons.isEmpty {
            status = .reject
            reasons = rejectionReasons
        } else {
            status = .proceed
            reasons = ["Accuracy, performance or capability, reliability, distribution, and artifact gates passed."]
        }

        return LocalTranscriptionAssessmentDecision(
            status: status,
            baseline: baselineSummary,
            candidate: candidateSummary,
            relativeWordErrorRegression: wordErrorRegression,
            latencyImprovement: latencyImprovement,
            memoryImprovement: memoryImprovement,
            reasons: reasons
        )
    }

    private static func relativeRegression(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return candidate > 0 ? 1 : 0 }
        return (candidate - baseline) / baseline
    }

    private static func relativeImprovement(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (baseline - candidate) / baseline
    }
}
