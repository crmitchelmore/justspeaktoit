import LocalTranscriptionBenchmarkKit
import SpeakCore
import XCTest

final class AssessmentGateTests: XCTestCase {
    func testGate_proceedsWhenAllMeasuredAndOperationalGatesPass() {
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(engine: .whisperKit, wallSeconds: 1, memoryMB: 100),
            candidate: report(engine: .transcribeCpp, wallSeconds: 0.9, memoryMB: 75),
            evidence: completeEvidence()
        )

        XCTAssertEqual(decision.status, .proceed)
        XCTAssertEqual(decision.memoryImprovement, 0.25, accuracy: 0.000_1)
    }

    func testGate_rejectsAccuracyRegressionEvenWhenPerformanceImproves() {
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(engine: .whisperKit, transcript: "one two three four"),
            candidate: report(engine: .transcribeCpp, transcript: "one wrong three four", wallSeconds: 0.5),
            evidence: completeEvidence()
        )

        XCTAssertEqual(decision.status, .reject)
        XCTAssertTrue(decision.reasons.contains { $0.contains("WER") })
    }

    func testGate_reportsInsufficientEvidenceForSmokeCorpusAndUnverifiedDistribution() {
        let incompleteEvidence = LocalTranscriptionAssessmentEvidence(
            directBuildPassed: true,
            appStoreBuildPassed: false,
            cancellationPassed: false,
            longRecordingPassed: false,
            silencePassed: false,
            capabilityGain: nil,
            modelArtifacts: []
        )
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(engine: .whisperKit, tags: ["short"]),
            candidate: report(engine: .transcribeCpp, tags: ["short"]),
            evidence: incompleteEvidence
        )

        XCTAssertEqual(decision.status, .insufficientEvidence)
        XCTAssertTrue(decision.reasons.contains { $0.contains("required tags") })
        XCTAssertTrue(decision.reasons.contains { $0.contains("App Store") })
    }

    func testGate_acceptsLatencyAndAccuracyGainDespiteMemoryTradeoff() {
        let incompleteEvidence = LocalTranscriptionAssessmentEvidence(
            directBuildPassed: true,
            appStoreBuildPassed: true,
            cancellationPassed: false,
            longRecordingPassed: false,
            silencePassed: true,
            modelArtifacts: [LocalTranscriptionModelArtifactEvidence(
                identifier: "parakeet-tdt-ctc-110m-q4",
                url: "https://example.com/parakeet.gguf",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 89_989_600,
                license: "CC-BY-4.0"
            )]
        )
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(
                engine: .whisperKit,
                transcript: "one wrong three four",
                wallSeconds: 0.074_615_291,
                memoryMB: 110.4375
            ),
            candidate: report(
                engine: .transcribeCpp,
                wallSeconds: 0.044_989_875,
                memoryMB: 324.875
            ),
            evidence: incompleteEvidence
        )

        XCTAssertEqual(decision.status, .insufficientEvidence)
        XCTAssertEqual(decision.latencyImprovement, 0.397_042, accuracy: 0.000_001)
        XCTAssertLessThan(decision.memoryImprovement, 0)
        XCTAssertFalse(decision.reasons.contains { $0.contains("WER") })
        XCTAssertFalse(decision.reasons.contains { $0.contains("performance gain") })
        XCTAssertTrue(decision.reasons.contains { $0.contains("Cancellation") })
        XCTAssertTrue(decision.reasons.contains { $0.contains("Long recordings") })
    }

    func testGate_rejectsEvidenceForDifferentCandidateModel() {
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(engine: .whisperKit),
            candidate: report(engine: .transcribeCpp),
            evidence: completeEvidence(artifactIdentifier: "different-model")
        )

        XCTAssertEqual(decision.status, .insufficientEvidence)
        XCTAssertTrue(decision.reasons.contains { $0.contains("candidate model") })
    }

    func testGate_rejectsChangedCorpusContentWithSameCaseID() {
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: report(engine: .whisperKit, referenceTranscript: "original words"),
            candidate: report(engine: .transcribeCpp, referenceTranscript: "changed words"),
            evidence: completeEvidence()
        )

        XCTAssertEqual(decision.status, .insufficientEvidence)
        XCTAssertTrue(decision.reasons.contains { $0.contains("same cases") })
    }

    private func report(
        engine: LocalTranscriptionEngine,
        transcript: String = "one two three four",
        wallSeconds: Double = 1,
        memoryMB: Double = 100,
        referenceTranscript: String = "one two three four",
        tags: [String] = ["accent", "long", "multilingual", "noise", "silence"]
    ) -> LocalTranscriptionBenchmarkReport {
        LocalTranscriptionBenchmarkReport(
            engine: engine,
            runtimeVersion: "test",
            model: "test-model",
            host: LocalTranscriptionBenchmarkHost(
                hardwareModel: "test",
                processor: "test",
                operatingSystem: "test",
                architecture: "arm64",
                physicalMemoryBytes: 1
            ),
            coldLoadSeconds: 0.1,
            warmupIterations: 1,
            measuredIterations: 1,
            measurements: [LocalTranscriptionBenchmarkMeasurement(
                caseID: "case",
                iteration: 1,
                tags: tags,
                referenceTranscript: referenceTranscript,
                transcript: transcript,
                audioSeconds: 10,
                wallSeconds: wallSeconds,
                userCPUSeconds: wallSeconds,
                systemCPUSeconds: 0,
                peakResidentMemoryMB: memoryMB
            )],
            failures: []
        )
    }

    private func completeEvidence(
        artifactIdentifier: String = "test-model"
    ) -> LocalTranscriptionAssessmentEvidence {
        LocalTranscriptionAssessmentEvidence(
            directBuildPassed: true,
            appStoreBuildPassed: true,
            cancellationPassed: true,
            longRecordingPassed: true,
            silencePassed: true,
            modelArtifacts: [LocalTranscriptionModelArtifactEvidence(
                identifier: artifactIdentifier,
                url: "https://example.com/model.gguf",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 1,
                license: "Apache-2.0"
            )]
        )
    }
}
