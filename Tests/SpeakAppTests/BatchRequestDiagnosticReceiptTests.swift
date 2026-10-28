import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class BatchRequestDiagnosticReceiptTests: XCTestCase {
    func testProductionBatchDelegateRetainsExactArgumentsAfterSettingsChange() async throws {
        let fixture = try await self.fixture()
        let session = self.session()
        var active: ActiveSession? = session
        let exit = XCTestExpectation(description: "owned request exited for cleanup")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return try await self.transcribe(fixture) { receipt in
                MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: active)
            }
        }
        self.cleanup(task: task, client: fixture.client, exit: exit, host: fixture.host)
        await fulfillment(of: [fixture.entered], timeout: 2)
        fixture.settings.preferredLocaleIdentifier = "fr"
        fixture.settings.batchTranscriptionModel = ModelCatalog.defaultBatchTranscriptionModel
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.model, Self.model)
        XCTAssertEqual(requests.first?.language, "en")
        let handoff = try XCTUnwrap(session.diagnosticContext?.observedHandoff)
        XCTAssertEqual(handoff.model.identifier, requests.first?.model)
        XCTAssertEqual(handoff.language.identifier, requests.first?.language)
        XCTAssertEqual(handoff.provenance, .observedHandoff)
        XCTAssertEqual(handoff.mode, .batch)
        XCTAssertEqual(handoff.options.streamingEnabled, false)
        XCTAssertNil(handoff.observedProvider, "Injected clients can hide internal transport and fallback")
        XCTAssertEqual(session.diagnosticContext?.requestContext?.mode, .live)
        await fixture.client.finish(.success(Self.result))
        let result = try await task.value
        XCTAssertEqual(result, Self.result)
        active = nil
    }

    func testProductionBatchDelegateKeepsOriginalErrorAndExcludesAssociatedCanaries() async throws {
        let fixture = try await self.fixture()
        let session = self.session()
        let exit = XCTestExpectation(description: "failed owned request exited for cleanup")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return try await self.transcribe(fixture) { receipt in
                MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: session)
            }
        }
        self.cleanup(task: task, client: fixture.client, exit: exit, host: fixture.host)
        await fulfillment(of: [fixture.entered], timeout: 2)
        await fixture.client.finish(.failure(OpenRouterClientError.httpStatus(401, Self.canary)))
        do {
            _ = try await task.value
            XCTFail("Original client error must still propagate")
        } catch OpenRouterClientError.httpStatus(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(body, Self.canary)
        }
        XCTAssertEqual(session.diagnosticContext?.requestFailure,
                       .init(stage: .request, code: .authentication, domain: .provider, httpStatus: 401))
        let report = HistoryIssueReporter.report(for: session.buildHistoryItem(finalText: nil))
        let output = report.title + report.body + report.jsonString
            + (report.issueURL?.absoluteString ?? "") + IssueDiagnosticReport.attachmentFilename
        XCTAssertFalse(output.contains(Self.canary))
        XCTAssertFalse(output.contains("PRIVATE_PATH"))
        let payload = try self.object(report.jsonData)
        XCTAssertNotNil(payload["context"])
        XCTAssertNotNil(payload["observedHandoff"])
        XCTAssertEqual((payload["failures"] as? [[String: Any]])?.first?["httpStatus"] as? Int, 401)
    }

    func testStaleAndCancelledReceiptsCannotMutateEitherSession() async {
        let first = self.session()
        let replacement = self.session()
        let receipt = TranscriptionManager.BatchDiagnosticReceipt.handoff(Self.handoff)
        let original = first.diagnosticContext
        let originalReplacement = replacement.diagnosticContext
        MainManager.retainBatchDiagnostic(receipt, for: first, activeSession: replacement)
        XCTAssertEqual(first.diagnosticContext, original)
        XCTAssertEqual(replacement.diagnosticContext, originalReplacement)
        let task = Task { @MainActor in
            MainManager.retainBatchDiagnostic(receipt, for: first, activeSession: first)
        }
        // No suspension before cancellation: this MainActor child cannot run yet.
        task.cancel()
        await task.value
        XCTAssertEqual(first.diagnosticContext, original)
        XCTAssertEqual(replacement.diagnosticContext, originalReplacement)
    }

    func testHeldRequestFailureAfterReplacementOrCancellationCannotInstallLateMetadata() async throws {
        for cancelled in [false, true] {
            let fixture = try await self.fixture()
            let session = self.session()
            let replacement = self.session()
            var active: ActiveSession? = session
            let exit = XCTestExpectation(description: "late owned request exited for cleanup")
            let task = Task { @MainActor in
                defer { exit.fulfill() }
                return try await self.transcribe(fixture) { receipt in
                    MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: active)
                }
            }
            self.cleanup(task: task, client: fixture.client, exit: exit, host: fixture.host)
            await fulfillment(of: [fixture.entered], timeout: 2)
            let before = session.diagnosticContext
            let replacementBefore = replacement.diagnosticContext
            if cancelled { task.cancel() } else { active = replacement }
            // The fake deliberately ignores cancellation until its actual operation is released.
            await fixture.client.finish(.failure(URLError(.timedOut)))
            do {
                _ = try await task.value
                XCTFail("Original held client failure must propagate")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
            XCTAssertEqual(session.diagnosticContext, before)
            XCTAssertEqual(replacement.diagnosticContext, replacementBefore)
        }
    }

    func testTypedFailureProjectionNeverParsesUnknownErrorsOrInventsHandoffs() {
        let error = NSError(domain: Self.canary, code: 401, userInfo: ["HTTPStatus": 401, "body": Self.canary])
        XCTAssertEqual(TranscriptionManager.batchFailure(error, stage: .admission),
                       .init(stage: .admission, code: .unknown, domain: .unknown))
        XCTAssertEqual(TranscriptionManager.batchFailure(URLError(.timedOut), stage: .request),
                       .init(stage: .request, code: .timeout, domain: .transport))
        let session = self.session()
        MainManager.retainBatchDiagnostic(.failure(.init(stage: .admission, code: .authentication)),
                                         for: session, activeSession: session)
        XCTAssertNil(session.diagnosticContext?.observedHandoff)
        XCTAssertEqual(session.diagnosticContext?.requestFailure?.stage, .admission)
    }

    func testTypedFailureCannotHideOtherLegacyPhaseFacts() throws {
        let session = self.session()
        let phases: [HistoryError.Phase] = [.transcription, .postProcessing, .output]
        session.errors = phases.map {
            HistoryError(phase: $0, message: Self.canary, debugDescription: Self.canary)
        }
        MainManager.retainBatchDiagnostic(.failure(.init(stage: .request, code: .authentication, httpStatus: 401)),
                                         for: session, activeSession: session)
        let report = HistoryIssueReporter.report(for: session.buildHistoryItem(finalText: nil))
        let failures = try XCTUnwrap(try self.object(report.jsonData)["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.count, 4)
        XCTAssertEqual(failures.first?["httpStatus"] as? Int, 401)
        XCTAssertEqual(Set(failures.compactMap { $0["stage"] as? String }), ["request", "postProcessing", "output"])
        XCTAssertFalse(report.jsonString.contains(Self.canary))
        XCTAssertTrue(report.body.contains("Failure observations may overlap"))
    }

    func testProductionBatchDelegateWithoutObserverPreservesResultAndSingleClientCall() async throws {
        let fixture = try await self.fixture()
        let exit = XCTestExpectation(description: "unobserved request exited for cleanup")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return try await self.transcribe(fixture)
        }
        self.cleanup(task: task, client: fixture.client, exit: exit, host: fixture.host)
        await fulfillment(of: [fixture.entered], timeout: 2)
        await fixture.client.finish(.success(Self.result))
        let result = try await task.value
        XCTAssertEqual(result, Self.result)
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.model, Self.model)
        XCTAssertEqual(requests.first?.language, "en")
    }

    func testReportKeepsAdmissionSeparateAndAppliesAllRemovalPoliciesToHandoff() throws {
        let admission = RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        let report = IssueDiagnosticReport(context: admission, observedHandoff: Self.handoff)
        let full = try self.object(report.jsonData)
        XCTAssertEqual((full["context"] as? [String: Any])?["mode"] as? String, "live")
        XCTAssertEqual((full["observedHandoff"] as? [String: Any])?["mode"] as? String, "batch")
        let removals: [Set<IssueDiagnosticReport.Section>] = [
            [.models], [.options], Set(IssueDiagnosticReport.Section.allCases)
        ]
        for sections in removals {
            let output = IssueDiagnosticReport(
                context: admission, omittedSections: sections, observedHandoff: Self.handoff
            )
            let payload = try self.object(output.jsonData)
            XCTAssertLessThanOrEqual(output.jsonData.count, IssueDiagnosticReport.maximumJSONBytes)
            if sections == Set(IssueDiagnosticReport.Section.allCases) {
                XCTAssertNil(payload["context"])
                XCTAssertNil(payload["observedHandoff"])
            } else if sections.contains(.models) {
                let handoff = try XCTUnwrap(payload["observedHandoff"] as? [String: Any])
                XCTAssertNil(handoff["observedProvider"])
                XCTAssertNil((handoff["model"] as? [String: Any])?["identifier"])
            } else {
                let handoff = payload["observedHandoff"] as? [String: Any]
                XCTAssertTrue((handoff?["options"] as? [String: Any])?.isEmpty == true)
            }
        }
        let notObserved = IssueDiagnosticReport(observedHandoff: admission)
        XCTAssertNil(try self.object(notObserved.jsonData)["observedHandoff"])
    }

    func testHistoryRoundTripKeepsAdmissionAndLossilyIgnoresInvalidNewObservations() throws {
        let session = self.session()
        MainManager.retainBatchDiagnostic(.handoff(Self.handoff), for: session, activeSession: session)
        MainManager.retainBatchDiagnostic(.failure(.init(stage: .request, code: .timeout)),
                                         for: session, activeSession: session)
        let item = session.buildHistoryItem(finalText: nil)
        let data = try JSONEncoder().encode(item.historyRecord)
        let restored = try JSONDecoder().decode(HistoryRecord.self, from: data)
        XCTAssertEqual(HistoryItem(historyRecord: restored), item)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.diagnosticContext?.requestContext, item.diagnosticContext?.requestContext)
        var object = try self.object(data)
        var context = try XCTUnwrap(object["diagnosticContext"] as? [String: Any])
        context["observedHandoff"] = ["provenance": "future", "model": Self.canary]
        context["requestFailure"] = "malformed"
        object["diagnosticContext"] = context
        let invalid = try JSONSerialization.data(withJSONObject: object)
        let record = try JSONDecoder().decode(HistoryRecord.self, from: invalid)
        XCTAssertEqual(record.id, restored.id)
        XCTAssertEqual(record.rawTranscription, restored.rawTranscription)
        XCTAssertEqual(record.diagnosticContext?.requestContext, restored.diagnosticContext?.requestContext)
        XCTAssertNil(record.diagnosticContext?.observedHandoff)
        XCTAssertNil(record.diagnosticContext?.requestFailure)
        context["processIdentifier"] = "not an integer"
        object["diagnosticContext"] = context
        XCTAssertThrowsError(try JSONDecoder().decode(
            HistoryRecord.self, from: JSONSerialization.data(withJSONObject: object)
        ))
    }
}

extension BatchRequestDiagnosticReceiptTests {
    func testProductionBatchDelegateKeepsModelButReadsLanguageAfterProviderLookup() async throws {
        let fixture = try await self.fixture()
        let lookupEntered = expectation(description: "owned provider lookup admitted")
        let lookup = HeldDiagnosticProviderLookup(entered: lookupEntered)
        let session = self.session()
        let exit = XCTestExpectation(description: "delayed lookup request exited for cleanup")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return try await TranscriptionManager.performBatchTranscription(
                at: self.privateURL, model: { fixture.settings.batchTranscriptionModel },
                settings: fixture.settings, batchClient: fixture.client,
                providerForModel: { _ in await lookup.wait(); return nil },
                apiKey: { _ in
                    XCTFail("The owned nil lookup must never request a credential")
                    throw DiagnosticFixtureError.unexpectedCredentialRequest
                },
                onDiagnostic: { MainManager.retainBatchDiagnostic($0, for: session, activeSession: session) }
            )
        }
        self.cleanup(task: task, client: fixture.client, exit: exit, host: fixture.host, lookup: lookup)
        await fulfillment(of: [lookupEntered], timeout: 2)
        fixture.settings.batchTranscriptionModel = ModelCatalog.defaultBatchTranscriptionModel
        fixture.settings.preferredLocaleIdentifier = "fr"
        await lookup.release()
        await fulfillment(of: [fixture.entered], timeout: 2)
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.model, Self.model)
        XCTAssertEqual(requests.first?.language, "fr")
        XCTAssertEqual(session.diagnosticContext?.observedHandoff?.model.identifier, requests.first?.model)
        XCTAssertEqual(session.diagnosticContext?.observedHandoff?.language.identifier, requests.first?.language)
        XCTAssertNil(session.diagnosticContext?.observedHandoff?.observedProvider)
        await fixture.client.finish(.success(Self.result))
        let result = try await task.value
        XCTAssertEqual(result, Self.result)
    }

    private func fixture() async throws -> BatchDiagnosticFixture {
        let host = try WireUpTestHost()
        let settings = host.makeSettings()
        settings.localStreamingModelSource = "local/streaming/diagnostic-fixture-uninstalled"
        settings.transcriptionMode = .batchRemote
        settings.batchTranscriptionModel = Self.model
        settings.preferredLocaleIdentifier = "en"
        let entered = expectation(description: "production batch delegate admitted owned fake client")
        let client = HeldDiagnosticBatchClient(entered: entered)
        return BatchDiagnosticFixture(settings: settings, client: client, entered: entered, host: host)
    }

    private func transcribe(
        _ fixture: BatchDiagnosticFixture,
        onDiagnostic: ((TranscriptionManager.BatchDiagnosticReceipt) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        try await TranscriptionManager.performBatchTranscription(
            at: self.privateURL, model: { fixture.settings.batchTranscriptionModel },
            settings: fixture.settings, batchClient: fixture.client,
            providerForModel: { _ in nil },
            apiKey: { _ in
                XCTFail("The owned opaque-client route must never request a credential")
                throw DiagnosticFixtureError.unexpectedCredentialRequest
            },
            onDiagnostic: onDiagnostic
        )
    }

    private func cleanup(
        task: Task<TranscriptionResult, Error>, client: HeldDiagnosticBatchClient, exit: XCTestExpectation,
        host: WireUpTestHost, lookup: HeldDiagnosticProviderLookup? = nil
    ) {
        addTeardownBlock { @MainActor in
            await lookup?.release()
            await client.finish(.failure(CancellationError()))
            task.cancel()
            let settled = await XCTWaiter.fulfillment(of: [exit], timeout: 2)
            guard settled == .completed else {
                XCTFail("Owned request is still active; fixture storage retained")
                return
            }
            do { try host.tearDown() } catch { XCTFail("Could not remove owned diagnostic test storage") }
        }
    }

    private func session() -> ActiveSession {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: Self.canary)
        session.diagnosticContext = HistoryDiagnosticContext(
            appVersion: "private", appBuild: "private", operatingSystem: "private", processIdentifier: 1,
            microphonePermission: "unknown", inputDeviceName: Self.canary, providerLabel: Self.canary,
            latencyTier: "private", transcriptionMode: "private", transcriptionModel: Self.canary,
            postProcessingModel: Self.canary, speedMode: "private",
            requestContext: RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        )
        return session
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private var privateURL: URL { URL(fileURLWithPath: "/PRIVATE_PATH/\(Self.canary).wav") }
    private static let model = "mistralai/voxtral-small-24b-2507"
    private static let canary = "PRIVATE_CANARY_token=user@example.com"
    private static var handoff: RequestDiagnosticContext {
        RequestDiagnosticContext(provenance: .observedHandoff, model: .project(model), mode: .batch,
                                 language: .project("en"), options: .init(streamingEnabled: false))
    }
    private static var result: TranscriptionResult {
        TranscriptionResult(text: canary, segments: [], confidence: nil, duration: 1, modelIdentifier: model,
                            cost: nil, rawPayload: canary, debugInfo: nil)
    }
}

private enum DiagnosticFixtureError: Error { case unexpectedCredentialRequest }

@MainActor
private struct BatchDiagnosticFixture {
    let settings: AppSettings
    let client: HeldDiagnosticBatchClient
    let entered: XCTestExpectation
    let host: WireUpTestHost
}

private actor HeldDiagnosticProviderLookup {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.entered.fulfill()
            if self.released { self.release() }
        }
    }

    func release() {
        self.released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor HeldDiagnosticBatchClient: BatchTranscriptionClient {
    struct Request: Sendable { let model: String; let language: String? }
    private(set) var requests: [Request] = []
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var earlyResult: Result<TranscriptionResult, Error>?
    init(entered: XCTestExpectation) { self.entered = entered }

    func transcribeFile(at url: URL, model: String, language: String?) async throws -> TranscriptionResult {
        self.requests.append(Request(model: model, language: language))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.entered.fulfill()
            if let earlyResult = self.earlyResult { self.finish(earlyResult) }
        }
    }

    func finish(_ result: Result<TranscriptionResult, Error>) {
        guard let continuation = self.continuation else { self.earlyResult = result; return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
