import Foundation
import XCTest
@testable import SpeakCore

final class PostProcessingDiagnosticContractTests: XCTestCase {
    private let canary = "PRIVATE_POLISH_token=user@example.com/path"

    func testPhaseConstructorAndDecoderDiscardUnrelatedFactsAndFalseFallback() throws {
        let model = try self.model()
        let broad = RequestDiagnosticContext(
            provenance: .observedHandoff, model: .project(model), postProcessingModel: .project(model),
            observedProvider: .project("openai"), mode: .live, origin: .global, language: .project("en"),
            destination: .clipboard, options: .init(diarizationEnabled: true, streamingEnabled: true, speechSpeed: 2)
        )
        let phase = RequestDiagnosticContext.PostProcessingObservation(
            handoff: broad, finalFailure: .init(stage: .request, code: .timeout), fallbackObserved: false
        )
        let restored = try JSONDecoder().decode(
            RequestDiagnosticContext.PostProcessingObservation.self, from: JSONEncoder().encode(phase)
        )
        XCTAssertEqual(restored, phase)
        XCTAssertNil(phase.finalFailure)
        XCTAssertNil(phase.fallbackObserved)
        XCTAssertEqual(phase.handoff?.postProcessingModel.identifier, model)
        XCTAssertNil(phase.handoff?.model.identifier)
        XCTAssertNil(phase.handoff?.observedProvider)
        XCTAssertEqual(phase.handoff?.mode, .unknown)
        XCTAssertEqual(phase.handoff?.origin, .unknown)
        XCTAssertEqual(phase.handoff?.destination, .unknown)
        XCTAssertNil(phase.handoff?.language.identifier)
        XCTAssertEqual(phase.handoff?.options, .init(streamingEnabled: true))
        XCTAssertNil(RequestDiagnosticContext.PostProcessingObservation(handoff: .init()).handoff)
    }

    func testDecodedCustomIdentifiersCannotEscapePhaseReport() throws {
        var context = try self.object(JSONEncoder().encode(RequestDiagnosticContext(provenance: .observedHandoff)))
        context["postProcessingModel"] = ["identifier": self.canary, "classification": "builtIn"]
        context["model"] = ["identifier": self.canary]
        context["observedProvider"] = ["identifier": self.canary]
        let data = try JSONSerialization.data(withJSONObject: ["handoff": context, "fallbackObserved": true])
        let phase = try JSONDecoder().decode(RequestDiagnosticContext.PostProcessingObservation.self, from: data)
        let report = IssueDiagnosticReport(observedHandoff: nil, postProcessingObservation: phase)
        self.assertAbsent(self.canary, report: report)
        XCTAssertNil(phase.handoff?.postProcessingModel.identifier)
        XCTAssertNil(phase.handoff?.observedProvider)
    }

    func testAllThreeLegacyHistoryInitializersKeepNilBytesAndStrictOldFields() throws {
        let original = ApplicationHistoryDiagnosticContext(
            capturedAt: Date(timeIntervalSince1970: 1), appVersion: "1", appBuild: "2", operatingSystem: "unknown",
            processIdentifier: 1, microphonePermission: "unknown", inputDeviceName: "unknown", providerLabel: "unknown",
            latencyTier: "unknown", transcriptionMode: "unknown", transcriptionModel: "unknown",
            postProcessingModel: "unknown", speedMode: "unknown"
        )
        XCTAssertEqual(try self.encoder().encode(original), try self.encoder().encode(self.context()))
        let oldData = try self.encoder().encode(original)
        var object = try self.object(oldData)
        XCTAssertNil(object["postProcessingObservation"])
        let phase = RequestDiagnosticContext.PostProcessingObservation(fallbackObserved: true)
        object["postProcessingObservation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(phase))
        let new = try JSONDecoder().decode(ApplicationHistoryDiagnosticContext.self,
                                          from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(new.postProcessingObservation, phase)
        for malformed: Any in ["invalid", 12, ["fallbackObserved": "yes"], ["handoff": ["provenance": "future"]]] {
            object["postProcessingObservation"] = malformed
            let decoded = try JSONDecoder().decode(ApplicationHistoryDiagnosticContext.self,
                                                   from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.postProcessingObservation)
            XCTAssertEqual(try self.encoder().encode(decoded), oldData)
        }
        object["processIdentifier"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(ApplicationHistoryDiagnosticContext.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(try self.encoder().encode(self.context(request: .init())),
                       try self.encoder().encode(self.context(request: .init(), observed: nil, failure: nil)))
    }

    func testSeparatePhaseAndTranscriptionSlotsRetainExplicitKeyContract() throws {
        let transcription = RequestDiagnosticContext(provenance: .observedHandoff, mode: .live)
        let phase = RequestDiagnosticContext.PostProcessingObservation(
            handoff: .init(provenance: .observedHandoff, postProcessingModel: .project(try self.model()),
                           options: .init(streamingEnabled: false)),
            finalFailure: .init(stage: .postProcessing, code: .timeout), fallbackObserved: true
        )
        let report = IssueDiagnosticReport(observedHandoff: transcription, postProcessingObservation: phase)
        let object = try self.object(report.jsonData)
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "contextState", "observedHandoff",
            "postProcessingHandoff", "recordedModels", "environment", "failures", "timeline",
            "omittedSections", "truncated"]))
        XCTAssertEqual((object["observedHandoff"] as? [String: Any])?["mode"] as? String, "live")
        XCTAssertEqual((object["postProcessingHandoff"] as? [String: Any])?["mode"] as? String, "unknown")
        XCTAssertEqual((object["failures"] as? [[String: Any]])?.first?["stage"] as? String, "postProcessing")
        XCTAssertEqual((object["timeline"] as? [[String: Any]])?.first?["outcome"] as? String, "fallback")
        XCTAssertLessThanOrEqual(report.jsonData.count, IssueDiagnosticReport.maximumJSONBytes)
    }

    func testCombinedCapsAccountForPhaseFailureAndEventBeforeTruncation() throws {
        let phase = RequestDiagnosticContext.PostProcessingObservation(
            finalFailure: .init(stage: .postProcessing, code: .timeout), fallbackObserved: true
        )
        let report = IssueDiagnosticReport(
            failures: Array(repeating: .init(stage: .request), count: 8),
            events: Array(repeating: .init(stage: .request, outcome: .started), count: 16),
            observedHandoff: nil, postProcessingObservation: phase
        )
        let object = try self.object(report.jsonData)
        XCTAssertEqual((object["failures"] as? [Any])?.count, 8)
        XCTAssertEqual((object["timeline"] as? [Any])?.count, 16)
        XCTAssertEqual((object["truncated"] as? [String: Int])?["failures"], 1)
        XCTAssertEqual((object["truncated"] as? [String: Int])?["timeline"], 1)
    }

    func testOmissionsAndFullRemovalCoverEveryPhaseFieldAndSurface() throws {
        let model = try self.model()
        let phase = RequestDiagnosticContext.PostProcessingObservation(
            handoff: .init(provenance: .observedHandoff, postProcessingModel: .project(model),
                           options: .init(streamingEnabled: true)),
            finalFailure: .init(stage: .postProcessing, code: .timeout), fallbackObserved: true
        )
        let limited = IssueDiagnosticReport(omittedSections: [.models, .options, .failures, .timeline],
                                            observedHandoff: nil, postProcessingObservation: phase)
        let object = try self.object(limited.jsonData)
        XCTAssertNil(object["failures"])
        XCTAssertNil(object["timeline"])
        let handoff = try XCTUnwrap(object["postProcessingHandoff"] as? [String: Any])
        XCTAssertTrue((handoff["options"] as? [String: Any])?.isEmpty == true)
        self.assertAbsent(model, report: limited)
        let removed = IssueDiagnosticReport(omittedSections: Set(IssueDiagnosticReport.Section.allCases),
                                            observedHandoff: nil, postProcessingObservation: phase)
        let empty = try self.object(removed.jsonData)
        XCTAssertNil(empty["postProcessingHandoff"])
        XCTAssertEqual(empty["contextState"] as? String, "userRemoved")
        XCTAssertEqual((empty["truncated"] as? [String: Int])?["failures"], 0)
        XCTAssertEqual((empty["truncated"] as? [String: Int])?["timeline"], 0)
    }

    func testBothOldReportConstructorsAreByteIdenticalWithExplicitNilPhase() {
        let old = IssueDiagnosticReport()
        let observed = IssueDiagnosticReport(observedHandoff: nil)
        let new = IssueDiagnosticReport(observedHandoff: nil, postProcessingObservation: nil)
        XCTAssertEqual(old.jsonData, observed.jsonData)
        XCTAssertEqual(old.jsonData, new.jsonData)
        XCTAssertEqual(old.body, new.body)
        XCTAssertEqual(old.issueURL, new.issueURL)
    }

    func testMigrationStillRedactsWholeDiagnosticContextIncludingNewPhase() throws {
        let original = HistoryRecordFixtures.richMac()
        var object = try self.object(DataMigrationCoding.encoder.encode(original))
        var diagnostic = try XCTUnwrap(object["diagnosticContext"] as? [String: Any])
        diagnostic["postProcessingObservation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RequestDiagnosticContext.PostProcessingObservation(fallbackObserved: true)
        ))
        object["diagnosticContext"] = diagnostic
        let item = try DataMigrationCoding.decoder.decode(
            ApplicationHistoryItem.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNotNil(item.diagnosticContext?.postProcessingObservation)
        let redacted = try DataMigrationHistoryValue.value(DataMigrationCoding.value(item))
        let json = try self.object(DataMigrationCoding.encoder.encode(redacted))
        XCTAssertNil(json["diagnosticContext"])
        XCTAssertEqual(json["rawTranscription"] as? String, original.rawTranscription)
    }

    private func model() throws -> String {
        try XCTUnwrap(ModelCatalog.allOptions.first { $0.id != ModelCatalog.customOptionID }?.id)
    }

    private func context() -> ApplicationHistoryDiagnosticContext { self.context(request: nil) }

    private func context(request: RequestDiagnosticContext?) -> ApplicationHistoryDiagnosticContext {
        .init(capturedAt: Date(timeIntervalSince1970: 1), appVersion: "1", appBuild: "2", operatingSystem: "unknown",
              processIdentifier: 1, microphonePermission: "unknown", inputDeviceName: "unknown",
              providerLabel: "unknown",
              latencyTier: "unknown", transcriptionMode: "unknown", transcriptionModel: "unknown",
              postProcessingModel: "unknown", speedMode: "unknown", requestContext: request)
    }

    private func context(request: RequestDiagnosticContext?, observed: RequestDiagnosticContext?,
                         failure: RequestDiagnosticContext.Failure?) -> ApplicationHistoryDiagnosticContext {
        .init(capturedAt: Date(timeIntervalSince1970: 1), appVersion: "1", appBuild: "2", operatingSystem: "unknown",
              processIdentifier: 1, microphonePermission: "unknown", inputDeviceName: "unknown",
              providerLabel: "unknown",
              latencyTier: "unknown", transcriptionMode: "unknown", transcriptionModel: "unknown",
              postProcessingModel: "unknown", speedMode: "unknown", requestContext: request,
              observedHandoff: observed, requestFailure: failure)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertAbsent(_ text: String, report: IssueDiagnosticReport,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse((report.jsonString + report.body + (report.issueURL?.absoluteString ?? "")).contains(text),
                       file: file, line: line)
    }
}
