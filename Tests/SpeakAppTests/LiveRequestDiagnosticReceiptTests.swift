import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class LiveRequestDiagnosticReceiptTests: XCTestCase {
    func testActualInvocationFreezesConfiguredArgumentsBeforeHeldStart() async throws {
        let held = LiveDiagnosticHeldStart()
        var selectedModel = "deepgram/nova-3-streaming"
        var selectedLanguage = "en"
        let configuredModel = selectedModel
        let configuredLanguage = selectedLanguage
        var observations: [RequestDiagnosticContext] = []
        let exit = XCTestExpectation(description: "owned live invocation exited")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            try await TranscriptionManager.performLiveInvocation(
                model: configuredModel, language: configuredLanguage,
                onDiagnostic: { if case .handoff(let value) = $0 { observations.append(value) } },
                start: { try await held.start() }
            )
        }
        self.own(task, held: held, exit: exit)
        await fulfillment(of: [held.entered], timeout: 2)
        selectedModel = "openai/gpt-live-transcribe-streaming"
        selectedLanguage = "fr"
        XCTAssertNotEqual(selectedModel, configuredModel)
        XCTAssertNotEqual(selectedLanguage, configuredLanguage)
        XCTAssertEqual(held.calls, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observation.provenance, .observedHandoff)
        XCTAssertEqual(observation.model.identifier, configuredModel)
        XCTAssertEqual(observation.language.identifier, configuredLanguage)
        XCTAssertEqual(observation.mode, .live)
        XCTAssertNil(observation.observedProvider)
        XCTAssertEqual(observation.options, .init())
        held.complete(.success(()))
        try await task.value
    }

    func testActualInvocationWithoutObserverStartsExactlyOnce() async throws {
        var calls = 0
        try await TranscriptionManager.performLiveInvocation(
            model: "deepgram/nova-3-streaming", language: nil, onDiagnostic: nil
        ) { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testPrecancelledInvocationDoesNotStartOrPublishAnyReceipt() async {
        var calls = 0
        var receipts = 0
        let task = Task { @MainActor in
            try await TranscriptionManager.performLiveInvocation(
                model: "deepgram/nova-3-streaming", language: nil,
                onDiagnostic: { _ in receipts += 1 }, start: { calls += 1 }
            )
        }
        // No suspension: this queued MainActor child is cancelled before entry.
        task.cancel()
        do {
            try await task.value
            XCTFail("A precancelled invocation must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(receipts, 0)
    }

    func testOriginalTypedErrorPropagatesWhileReportExcludesAssociatedCanary() async throws {
        let held = LiveDiagnosticHeldStart()
        var handoff: RequestDiagnosticContext?
        var failure: RequestDiagnosticContext.Failure?
        let exit = XCTestExpectation(description: "failed live invocation exited")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            try await TranscriptionManager.performLiveInvocation(
                model: "deepgram/nova-3-streaming", language: "en", onDiagnostic: {
                    switch $0 {
                    case .handoff(let value): handoff = value
                    case .failure(let value): failure = value
                    }
                }, start: { try await held.start() }
            )
        }
        self.own(task, held: held, exit: exit)
        await fulfillment(of: [held.entered], timeout: 2)
        held.complete(.failure(OpenRouterClientError.httpStatus(401, LiveDiagnosticHeldStart.canary)))
        do {
            try await task.value
            XCTFail("The original start error must propagate")
        } catch OpenRouterClientError.httpStatus(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(body, LiveDiagnosticHeldStart.canary)
        }
        XCTAssertEqual(held.calls, 1)
        XCTAssertEqual(failure, .init(stage: .request, code: .authentication, domain: .provider, httpStatus: 401))
        XCTAssertNil(handoff?.observedProvider, "A local controller call does not identify wrapped transport")
        let report = IssueDiagnosticReport(failures: failure.map { [$0] } ?? [], observedHandoff: handoff)
        XCTAssertFalse((report.body + report.jsonString + (report.issueURL?.absoluteString ?? ""))
            .contains(LiveDiagnosticHeldStart.canary))
    }

    func testUnknownErrorMetadataAndCustomIdentifiersNeverBecomeProviderFacts() async throws {
        var failure: RequestDiagnosticContext.Failure?
        var handoff: RequestDiagnosticContext?
        let unknown = NSError(domain: LiveDiagnosticHeldStart.canary, code: 401,
                              userInfo: ["HTTPStatus": 401, "body": LiveDiagnosticHeldStart.canary])
        do {
            try await TranscriptionManager.performLiveInvocation(
                model: LiveDiagnosticHeldStart.canary, language: LiveDiagnosticHeldStart.canary, onDiagnostic: {
                    switch $0 {
                    case .handoff(let value): handoff = value
                    case .failure(let value): failure = value
                    }
                }, start: { throw unknown }
            )
            XCTFail("Unknown error must still propagate")
        } catch { XCTAssertTrue((error as NSError) === unknown) }
        XCTAssertEqual(failure, .init(stage: .request, code: .unknown, domain: .unknown))
        XCTAssertNil(handoff?.observedProvider)
        XCTAssertNil(handoff?.model.identifier)
        XCTAssertNil(handoff?.language.identifier)
        let report = IssueDiagnosticReport(failures: failure.map { [$0] } ?? [], observedHandoff: handoff)
        XCTAssertFalse((report.body + report.jsonString + (report.issueURL?.absoluteString ?? ""))
            .contains(LiveDiagnosticHeldStart.canary))
    }

    private func own(_ task: Task<Void, Error>, held: LiveDiagnosticHeldStart, exit: XCTestExpectation) {
        addTeardownBlock { @MainActor in
            task.cancel()
            held.complete(.failure(CancellationError()))
            let result = await XCTWaiter.fulfillment(of: [exit], timeout: 2)
            XCTAssertEqual(result, .completed, "The owned operation must exit before fixture retirement")
        }
    }
}

/// Inert start operation: no settings, credentials, audio, provider or filesystem.
/// It deliberately ignores cancellation until released; teardown may release
/// before admission without stranding a later continuation.
@MainActor
final class LiveDiagnosticHeldStart {
    static let canary = "PRIVATE_LIVE_token=user@example.com/PRIVATE_PATH"
    let entered = XCTestExpectation(description: "owned start operation admitted")
    private(set) var calls = 0
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func start() async throws {
        self.calls += 1
        self.entered.fulfill()
        try await withCheckedThrowingContinuation { continuation in
            if let result = self.result { continuation.resume(with: result) } else { self.continuation = continuation }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
