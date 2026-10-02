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
        let metrics = AssessmentMetrics(baseline: baselineSummary, candidate: candidateSummary)
        let rejectionReasons = rejectionReasons(
            baseline: baselineSummary,
            candidate: candidateSummary,
            evidence: evidence,
            policy: policy,
            metrics: metrics
        )
        let missingEvidence = corpusEvidenceReasons(
            baseline: baseline,
            candidate: candidate,
            requiredTags: policy.requiredCorpusTags
        ) + operationalEvidenceReasons(evidence, candidateModel: candidate.model)
        let outcome = outcome(rejections: rejectionReasons, missingEvidence: missingEvidence)

        return LocalTranscriptionAssessmentDecision(
            status: outcome.status,
            baseline: baselineSummary,
            candidate: candidateSummary,
            relativeWordErrorRegression: metrics.wordErrorRegression,
            latencyImprovement: metrics.latencyImprovement,
            memoryImprovement: metrics.memoryImprovement,
            reasons: outcome.reasons
        )
    }

    private static func rejectionReasons(
        baseline: LocalTranscriptionBenchmarkSummary,
        candidate: LocalTranscriptionBenchmarkSummary,
        evidence: LocalTranscriptionAssessmentEvidence,
        policy: LocalTranscriptionAssessmentPolicy,
        metrics: AssessmentMetrics
    ) -> [String] {
        var reasons: [String] = []
        if metrics.wordErrorRegression > policy.maximumRelativeWordErrorRegression {
            reasons.append(
                "Candidate WER exceeds the allowed "
                    + "\(policy.maximumRelativeWordErrorRegression * 100)% relative regression."
            )
        }
        if baseline.failureCount > 0 || candidate.failureCount > 0 {
            reasons.append("One or more benchmark cases failed.")
        }
        let performanceGain = max(metrics.latencyImprovement, metrics.memoryImprovement)
        let capabilityGain = evidence.capabilityGain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if performanceGain < policy.minimumPerformanceImprovement && capabilityGain.isEmpty {
            reasons.append(
                "Candidate has neither a \(policy.minimumPerformanceImprovement * 100)% "
                    + "performance gain nor a documented capability gain."
            )
        }
        return reasons
    }

    private static func corpusEvidenceReasons(
        baseline: LocalTranscriptionBenchmarkReport,
        candidate: LocalTranscriptionBenchmarkReport,
        requiredTags: [String]
    ) -> [String] {
        var reasons: [String] = []
        let candidateTags = Set(candidate.summary.tagCoverage)
        let missingTags = requiredTags.filter { !candidateTags.contains($0) }
        if !missingTags.isEmpty {
            reasons.append("Corpus is missing required tags: \(missingTags.joined(separator: ", ")).")
        }
        if corpusIdentity(baseline.measurements) != corpusIdentity(candidate.measurements) {
            reasons.append("Baseline and candidate did not run the same cases.")
        }
        if baseline.engine != .whisperKit { reasons.append("Baseline report must use WhisperKit.") }
        if candidate.engine != .transcribeCpp { reasons.append("Candidate report must use transcribe.cpp.") }
        return reasons
    }

    private static func operationalEvidenceReasons(
        _ evidence: LocalTranscriptionAssessmentEvidence,
        candidateModel: String
    ) -> [String] {
        var reasons: [String] = []
        if !evidence.directBuildPassed { reasons.append("Direct macOS build is not verified.") }
        if !evidence.appStoreBuildPassed { reasons.append("Mac App Store build is not verified.") }
        if !evidence.cancellationPassed { reasons.append("Cancellation is not verified.") }
        if !evidence.longRecordingPassed { reasons.append("Long recordings are not verified.") }
        if !evidence.silencePassed { reasons.append("Silence handling is not verified.") }
        let matchingArtifact = evidence.modelArtifacts.first { $0.identifier == candidateModel }
        if matchingArtifact?.isComplete != true {
            reasons.append("The candidate model needs matching URL, SHA-256, size, and license evidence.")
        }
        return reasons
    }

    private static func corpusIdentity(
        _ measurements: [LocalTranscriptionBenchmarkMeasurement]
    ) -> [CorpusMeasurementIdentity] {
        measurements.map(CorpusMeasurementIdentity.init).sorted {
            ($0.caseID, $0.iteration) < ($1.caseID, $1.iteration)
        }
    }

    private static func outcome(
        rejections: [String],
        missingEvidence: [String]
    ) -> AssessmentOutcome {
        if !missingEvidence.isEmpty {
            return AssessmentOutcome(status: .insufficientEvidence, reasons: rejections + missingEvidence)
        }
        if !rejections.isEmpty {
            return AssessmentOutcome(status: .reject, reasons: rejections)
        }
        return AssessmentOutcome(
            status: .proceed,
            reasons: ["Accuracy, performance or capability, reliability, distribution, and artifact gates passed."]
        )
    }

    fileprivate static func relativeRegression(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return candidate > 0 ? 1 : 0 }
        return (candidate - baseline) / baseline
    }

    fileprivate static func relativeImprovement(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (baseline - candidate) / baseline
    }
}

private struct CorpusMeasurementIdentity: Equatable {
    let caseID: String
    let iteration: Int
    let tags: [String]
    let language: String?
    let referenceTranscript: String
    let audioSeconds: Double

    init(_ measurement: LocalTranscriptionBenchmarkMeasurement) {
        caseID = measurement.caseID
        iteration = measurement.iteration
        tags = measurement.tags.sorted()
        language = measurement.language
        referenceTranscript = measurement.referenceTranscript
        audioSeconds = measurement.audioSeconds
    }
}

private struct AssessmentMetrics {
    let wordErrorRegression: Double
    let latencyImprovement: Double
    let memoryImprovement: Double

    init(
        baseline: LocalTranscriptionBenchmarkSummary,
        candidate: LocalTranscriptionBenchmarkSummary
    ) {
        wordErrorRegression = LocalTranscriptionAssessmentGate.relativeRegression(
            baseline: baseline.wordErrorRate,
            candidate: candidate.wordErrorRate
        )
        latencyImprovement = LocalTranscriptionAssessmentGate.relativeImprovement(
            baseline: baseline.medianWallSeconds,
            candidate: candidate.medianWallSeconds
        )
        memoryImprovement = LocalTranscriptionAssessmentGate.relativeImprovement(
            baseline: baseline.peakResidentMemoryMB,
            candidate: candidate.peakResidentMemoryMB
        )
    }
}

private struct AssessmentOutcome {
    let status: LocalTranscriptionAssessmentDecision.Status
    let reasons: [String]
}
