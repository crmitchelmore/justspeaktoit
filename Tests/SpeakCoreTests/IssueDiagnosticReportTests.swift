import XCTest
@testable import SpeakCore

final class IssueDiagnosticReportTests: XCTestCase {
    private let canary = "CANARY-secret-person-email@example.test-/Users/private-token?key=123"

    func testLegacyReportHasNoInventedEffectiveContext() throws {
        let report = IssueDiagnosticReport()
        let json = try object(report)
        XCTAssertEqual(json["contextState"] as? String, "missingLegacyContext")
        XCTAssertNil(json["context"])
        XCTAssertTrue(report.body.contains("not verified handoffs"))
        XCTAssertTrue(report.body.contains("## Description"))
        XCTAssertTrue(report.body.contains("does not upload"))
    }

    func testExactCanonicalModelProjectionAndCustomClassification() throws {
        let option = try XCTUnwrap(ModelCatalog.allOptions.first { $0.id != ModelCatalog.customOptionID })
        let known = RequestDiagnosticContext.ModelSelection.project(option.id)
        XCTAssertEqual(known.identifier, option.id)
        XCTAssertEqual(known.classification, .builtIn)
        XCTAssertNil(RequestDiagnosticContext.ModelSelection.project(" " + option.id).identifier)
        XCTAssertNil(RequestDiagnosticContext.ModelSelection.project(ModelCatalog.customOptionID).identifier)
        let report = IssueDiagnosticReport(recordedModels: [known, .project(canary)])
        XCTAssertTrue(report.jsonString.contains(option.id))
        XCTAssertTrue(report.jsonString.contains("customOrUnknown"))
        assertAbsent(canary, from: report)
    }

    func testUntrustedInputsCannotReachAnyOutputSurface() {
        let context = RequestDiagnosticContext(
            provenance: .observedHandoff, model: .project(canary), postProcessingModel: .project(canary),
            observedProvider: .project(canary), language: .project(canary)
        )
        let environment = RequestDiagnosticContext.Environment(
            appVersion: .project(canary), appBuild: .project(canary), osVersion: .project(canary)
        )
        let report = IssueDiagnosticReport(
            context: context, recordedModels: [.project(canary)], environment: environment
        )
        assertAbsent(canary, from: report)
        XCTAssertLessThanOrEqual(report.jsonData.count, IssueDiagnosticReport.maximumJSONBytes)
    }

    func testDecodedUnknownFieldsAndForgedCatalogueIdentifiersAreExcluded() throws {
        var json = try contextObject(RequestDiagnosticContext())
        json["model"] = ["classification": "builtIn", "identifier": canary]
        json["postProcessingModel"] = ["identifier": canary]
        json["language"] = ["identifier": canary]
        json["observedProvider"] = ["identifier": canary]
        let forbidden = ["transcript", "prompt", "headers", "device", "error", "url", "profile", "newSetting",
                         "clipboard", "audio", "path", "filename", "account", "keyterms", "timestamp", "historyID"]
        for key in forbidden {
            json[key] = ["nested": "\(canary)-\(key)"]
        }
        let decoded = try JSONDecoder().decode(
            RequestDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: json)
        )
        let report = IssueDiagnosticReport(context: decoded)
        assertAbsent(canary, from: report)
        XCTAssertFalse(report.jsonString.contains("newSetting"))
        XCTAssertTrue(report.jsonString.contains("customOrUnknown"))
    }

    func testDecodedAdmissionCannotClaimObservedProvider() throws {
        var json = try contextObject(RequestDiagnosticContext())
        json["observedProvider"] = ["identifier": "gladia"]
        let decoded = try JSONDecoder().decode(
            RequestDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: json)
        )
        let report = IssueDiagnosticReport(context: decoded)
        let context = try XCTUnwrap(try object(report)["context"] as? [String: Any])
        XCTAssertNil(context["observedProvider"])
        XCTAssertEqual(context["provenance"] as? String, "admission")
    }

    func testObservedProviderUsesCanonicalMembershipWithoutModelInference() throws {
        let context = RequestDiagnosticContext(
            provenance: .observedHandoff, model: .project("gladia/solaria-1-streaming"),
            observedProvider: .project("gladia"), mode: .live
        )
        XCTAssertEqual(context.observedProvider?.identifier, "gladia")
        XCTAssertNil(RequestDiagnosticContext(model: context.model).observedProvider)
        XCTAssertNil(RequestDiagnosticContext.ProviderSelection.project("GLADIA").identifier)
        XCTAssertEqual(RequestDiagnosticContext.ProviderSelection.project("openrouter").identifier, "openrouter")
    }

    func testNumericVersionsAreFiniteBoundedAndDoNotEchoInvalidInput() throws {
        for value in [canary, "", "1..2", ".1", "1.", "1.2.3.4.5", "123456789", "1\n2", "١.٢"] {
            XCTAssertNil(RequestDiagnosticContext.Version.project(value))
            let data = try JSONEncoder().encode(value)
            XCTAssertThrowsError(try JSONDecoder().decode(RequestDiagnosticContext.Version.self, from: data))
        }
        XCTAssertEqual(RequestDiagnosticContext.Version.project("2.24.3")?.value, "2.24.3")
        XCTAssertEqual(RequestDiagnosticContext.Version.project("1000.0.42")?.value, "1000.0.42")
    }

    func testDecodedInvalidNumbersAreRevalidatedAtFinalSerialization() throws {
        var json = try contextObject(RequestDiagnosticContext())
        json["options"] = ["speechSpeed": 1e100, "finalizationBudgetMilliseconds": Int.max]
        let decoded = try JSONDecoder().decode(
            RequestDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: json)
        )
        let report = IssueDiagnosticReport(context: decoded)
        let context = try XCTUnwrap(try object(report)["context"] as? [String: Any])
        let options = try XCTUnwrap(context["options"] as? [String: Any])
        XCTAssertNil(options["speechSpeed"])
        XCTAssertNil(options["finalizationBudgetMilliseconds"])
    }

    func testNonFiniteAndOutOfRangeOptionsAreNotClampedIntoClaims() {
        for speed in [Double.nan, .infinity, -.infinity, -1, 0, 4.01] {
            XCTAssertNil(RequestDiagnosticContext.Options(speechSpeed: speed).speechSpeed)
        }
        for value in [Int.min, -1, 86_400_001, Int.max] {
            XCTAssertNil(RequestDiagnosticContext.Event(stage: .request, outcome: .failed,
                                                      elapsedMilliseconds: value).elapsedMilliseconds)
        }
        XCTAssertEqual(RequestDiagnosticContext.Options(speechSpeed: 0.25).speechSpeed, 0.25)
        XCTAssertEqual(RequestDiagnosticContext.Options(speechSpeed: 4).speechSpeed, 4)
    }

    func testDecodedFailureAndEventBoundsCannotBypassExportValidation() throws {
        let failure = try JSONDecoder().decode(RequestDiagnosticContext.Failure.self, from: Data(
            #"{"stage":"request","code":"unknown","domain":"provider","httpStatus":99999}"#.utf8
        ))
        let event = try JSONDecoder().decode(RequestDiagnosticContext.Event.self, from: Data(
            #"{"stage":"request","outcome":"failed","elapsedMilliseconds":-1}"#.utf8
        ))
        let json = try object(IssueDiagnosticReport(failures: [failure], events: [event]))
        XCTAssertNil((json["failures"] as? [[String: Any]])?.first?["httpStatus"])
        XCTAssertNil((json["timeline"] as? [[String: Any]])?.first?["elapsedMilliseconds"])
        XCTAssertEqual(RequestDiagnosticContext.Failure(httpStatus: 429).httpStatus, 429)
        XCTAssertEqual(RequestDiagnosticContext.Failure().domain, .unknown)
    }

    func testCountsAndWorstCaseEncodedSizeAreBoundedAndVisible() throws {
        let models = ModelCatalog.allOptions.map { RequestDiagnosticContext.ModelSelection.project($0.id) }
        let failures = Array(repeating: RequestDiagnosticContext.Failure(stage: .postProcessing,
                                                                       code: .missingCompletion), count: 100)
        let events = Array(repeating: RequestDiagnosticContext.Event(stage: .providerHandoff, outcome: .succeeded,
                                                                    elapsedMilliseconds: 86_400_000), count: 100)
        let report = IssueDiagnosticReport(recordedModels: models, failures: failures, events: events)
        let json = try object(report)
        XCTAssertEqual((json["recordedModels"] as? [Any])?.count, min(models.count, 8))
        XCTAssertEqual((json["failures"] as? [Any])?.count, 8)
        XCTAssertEqual((json["timeline"] as? [Any])?.count, 16)
        XCTAssertEqual((json["truncated"] as? [String: Int])?["failures"], 92)
        XCTAssertEqual((json["truncated"] as? [String: Int])?["timeline"], 84)
        XCTAssertLessThanOrEqual(report.jsonData.count, 16 * 1_024)
    }

    func testOmissionsRemoveDetailsFromEveryOutputAndKeepExplicitNotice() throws {
        let model = try XCTUnwrap(ModelCatalog.allOptions.first { $0.id != ModelCatalog.customOptionID })
        let report = IssueDiagnosticReport(
            context: .init(model: .project(model.id), options: .init(postProcessingEnabled: true)),
            recordedModels: [.project(model.id)], environment: .init(platform: .macOS),
            failures: [.init(code: .authentication)], events: [.init(stage: .streaming, outcome: .failed)],
            omittedSections: Set(IssueDiagnosticReport.Section.allCases)
        )
        let json = try object(report)
        XCTAssertNil(json["failures"])
        XCTAssertNil(json["timeline"])
        XCTAssertNil(json["environment"])
        XCTAssertNil(json["recordedModels"])
        XCTAssertNil(json["context"])
        XCTAssertEqual(json["contextState"] as? String, "userRemoved")
        XCTAssertEqual(json["omissionReason"] as? String, "userRemoved")
        XCTAssertEqual((json["omittedSections"] as? [String])?.count, 5)
        assertAbsent(model.id, from: report)
        XCTAssertFalse(report.jsonString.contains("authentication"))
    }

    func testExactEncodedKeyContractCannotExpandWithUnknownSettings() throws {
        let report = IssueDiagnosticReport(context: .init(
            provenance: .observedHandoff, model: .project("gladia/solaria-1-streaming"),
            observedProvider: .project("gladia"), language: .project("en_GB"),
            options: .init(postProcessingEnabled: true, diarizationEnabled: false, streamingEnabled: true,
                           speechSpeed: 1, finalizationBudgetMilliseconds: 4_500)
        ), environment: .init(platform: .macOS, appVersion: .project("2.24.3")),
        failures: [.init(httpStatus: 429)], events: [.init(stage: .request, outcome: .retry, elapsedMilliseconds: 5)])
        let json = try object(report)
        XCTAssertEqual(Set(json.keys), Set([
            "schemaVersion", "contextState", "context", "recordedModels", "environment", "failures", "timeline",
            "omittedSections", "truncated"
        ]))
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), Set([
            "provenance", "model", "postProcessingModel", "observedProvider", "mode", "origin", "language",
            "destination", "options"
        ]))
        XCTAssertEqual(Set((context["options"] as? [String: Any] ?? [:]).keys), Set([
            "postProcessingEnabled", "diarizationEnabled", "streamingEnabled", "speechSpeed",
            "finalizationBudgetMilliseconds"
        ]))
        XCTAssertEqual(Set((context["model"] as? [String: Any] ?? [:]).keys), ["classification", "identifier"])
        XCTAssertEqual(Set((context["observedProvider"] as? [String: Any] ?? [:]).keys), ["identifier"])
        XCTAssertEqual(Set((context["language"] as? [String: Any] ?? [:]).keys), ["identifier"])
        XCTAssertEqual(Set((json["environment"] as? [String: Any] ?? [:]).keys), [
            "platform", "architecture", "channel", "appVersion", "microphonePermission"
        ])
        let failure = try XCTUnwrap((json["failures"] as? [[String: Any]])?.first)
        let event = try XCTUnwrap((json["timeline"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(failure.keys), ["stage", "code", "domain", "httpStatus"])
        XCTAssertEqual(Set(event.keys), ["stage", "outcome", "elapsedMilliseconds"])
    }

    func testSingleFrozenPayloadBindsJSONDraftURLAndSafeFilename() throws {
        let report = IssueDiagnosticReport(failures: [.init(stage: .request, code: .timeout)])
        XCTAssertEqual(Data(report.jsonString.utf8), report.jsonData)
        XCTAssertTrue(report.body.contains(report.jsonString))
        let url = try XCTUnwrap(report.issueURL)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "body" }?.value, report.body)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, report.title)
        XCTAssertEqual(items.first { $0.name == "labels" }?.value, "bug")
        XCTAssertEqual(IssueDiagnosticReport.attachmentFilename, "justspeaktoit-diagnostics.json")
        let repeated = IssueDiagnosticReport(failures: [.init(stage: .request, code: .timeout)])
        XCTAssertEqual(report.jsonData, repeated.jsonData)
    }

    func testUnknownTypedStatesAreRejectedRatherThanExported() throws {
        var json = try contextObject(RequestDiagnosticContext())
        json["mode"] = canary
        XCTAssertThrowsError(try JSONDecoder().decode(
            RequestDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: json)
        ))
    }

    private func object(_ report: IssueDiagnosticReport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    }

    private func contextObject(_ context: RequestDiagnosticContext) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
    }

    private func assertAbsent(_ value: String, from report: IssueDiagnosticReport,
                              file: StaticString = #filePath, line: UInt = #line) {
        for surface in [report.title, report.body, report.jsonString, report.issueURL?.absoluteString ?? "",
                        IssueDiagnosticReport.attachmentFilename] {
            XCTAssertFalse(surface.contains(value), file: file, line: line)
        }
    }
}

final class IssueDiagnosticReportBoundaryTests: XCTestCase {
    func testOversizedComposerURLIsUnavailableWithoutTruncatingTheArtifact() throws {
        let models = ModelCatalog.allOptions.sorted { $0.id.count > $1.id.count }.prefix(8).map {
            RequestDiagnosticContext.ModelSelection.project($0.id)
        }
        let report = IssueDiagnosticReport(
            context: .init(provenance: .observedHandoff, model: models[0], postProcessingModel: models[1],
                           observedProvider: .project("gladia"), language: .project("en_GB"),
                           options: .init(postProcessingEnabled: true, diarizationEnabled: true,
                                          streamingEnabled: true, speechSpeed: 1,
                                          finalizationBudgetMilliseconds: 86_400_000)),
            recordedModels: models,
            failures: Array(repeating: .init(stage: .postProcessing, code: .missingCompletion), count: 8),
            events: Array(repeating: .init(stage: .providerHandoff, outcome: .succeeded,
                                          elapsedMilliseconds: 86_400_000), count: 16)
        )
        XCTAssertNil(report.issueURL)
        XCTAssertEqual(Data(report.jsonString.utf8), report.jsonData)
        XCTAssertTrue(report.body.contains(report.jsonString))
        XCTAssertEqual((try object(report)["timeline"] as? [Any])?.count, 16)
    }

    func testFrozenAdmissionDoesNotReadLaterModelSelection() throws {
        let models = Array(ModelCatalog.allOptions.prefix(2))
        XCTAssertEqual(models.count, 2)
        var selected = models[0].id
        let admission = RequestDiagnosticContext(model: .project(selected), mode: .live)
        selected = models[1].id
        let report = IssueDiagnosticReport(context: admission)
        let context = try XCTUnwrap(try object(report)["context"] as? [String: Any])
        XCTAssertEqual((context["model"] as? [String: Any])?["identifier"] as? String, models[0].id)
        XCTAssertNotEqual(admission.model.identifier, selected)
    }

    private func object(_ report: IssueDiagnosticReport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    }
}
