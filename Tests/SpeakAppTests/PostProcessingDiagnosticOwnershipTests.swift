import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class PostProcessingDiagnosticOwnershipTests: XCTestCase {
    func testPostProcessingAndLaterTranscriptionReceiptsPreserveBothPhases() throws {
        let session = self.session()
        let before = try XCTUnwrap(session.diagnosticContext)
        let phase = RequestDiagnosticContext.PostProcessingObservation(
            handoff: .init(provenance: .observedHandoff, postProcessingModel: .project("openai/gpt-4o-mini"),
                           options: .init(streamingEnabled: false)),
            finalFailure: .init(stage: .postProcessing, code: .timeout), fallbackObserved: true
        )
        MainManager.retainPostProcessingDiagnostic(phase, for: session, activeSession: session)
        XCTAssertEqual(session.diagnosticContext?.requestContext, before.requestContext)
        XCTAssertEqual(session.diagnosticContext?.observedHandoff, before.observedHandoff)
        XCTAssertEqual(session.diagnosticContext?.requestFailure, before.requestFailure)
        MainManager.retainBatchDiagnostic(.failure(.init(stage: .request, code: .transport)),
                                          for: session, activeSession: session)
        XCTAssertEqual(session.diagnosticContext?.postProcessingObservation, phase)
        let item = session.buildHistoryItem(finalText: PostDiagnosticClient.canary)
        let restoredRecord = try JSONDecoder().decode(
            HistoryRecord.self, from: JSONEncoder().encode(item.historyRecord)
        )
        let restored = try XCTUnwrap(HistoryItem(historyRecord: restoredRecord))
        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.diagnosticContext?.postProcessingObservation, phase)
        let report = HistoryIssueReporter.report(for: restored)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
        XCTAssertNotNil(json["postProcessingHandoff"])
        XCTAssertNotNil(json["observedHandoff"])
        XCTAssertEqual((json["failures"] as? [[String: Any]])?.last?["stage"] as? String, "postProcessing")
        XCTAssertFalse((report.body + report.jsonString + (report.issueURL?.absoluteString ?? ""))
            .contains(PostDiagnosticClient.canary))
        let removed = HistoryIssueReporter.report(for: restored, includeDiagnostics: false)
        XCTAssertFalse(removed.jsonString.contains("postProcessingHandoff"))
    }

    func testHeldFailureAfterReplacementOrCancellationDoesNotWriteLatePhaseMetadata() async throws {
        for cancel in [false, true] {
            let client = PostDiagnosticClient()
            client.holdsChat = cancel
            client.chatResult = .failure(OpenRouterClientError.httpStatus(401, PostDiagnosticClient.canary))
            let session = self.session()
            let replacement = self.session()
            var active: ActiveSession? = session
            let exit = XCTestExpectation(description: "owned post-processing exited")
            let task = Task { @MainActor in
                defer { exit.fulfill() }
                return await self.run(client, streaming: !cancel) {
                    MainManager.retainPostProcessingDiagnostic($0, for: session, activeSession: active)
                }
            }
            addTeardownBlock { @MainActor in
                task.cancel()
                client.finish(.failure(CancellationError()))
                client.releaseChat(.failure(CancellationError()))
                let result = await XCTWaiter.fulfillment(of: [exit], timeout: 2)
                XCTAssertEqual(result, .completed)
            }
            await fulfillment(of: [cancel ? client.chatEntered : client.entered], timeout: 2)
            if cancel {
                XCTAssertTrue(client.hasPendingChat, "The actual async chat must be held before cancellation")
            }
            let admitted = session.diagnosticContext
            let other = replacement.diagnosticContext
            XCTAssertEqual(admitted?.postProcessingObservation?.handoff?.options.streamingEnabled, !cancel)
            if cancel {
                task.cancel()
                XCTAssertTrue(client.hasPendingChat, "Cancellation must not settle the uncooperative client")
                client.releaseChat()
            } else {
                active = replacement
                client.finish(.failure(URLError(.timedOut)))
            }
            let result = await task.value
            switch result {
            case .success: XCTFail("The original terminal error must survive")
            case .failure(OpenRouterClientError.httpStatus(let status, let body)):
                XCTAssertEqual(status, 401)
                XCTAssertEqual(body, PostDiagnosticClient.canary)
            case .failure: XCTFail("The original failure type must survive")
            }
            XCTAssertEqual(client.chatCalls.count, 1)
            XCTAssertEqual(session.diagnosticContext, admitted)
            XCTAssertEqual(replacement.diagnosticContext, other)
        }
    }

    func testMissingContextDoesNotFabricateHistoryMetadata() async throws {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "owned")
        let client = PostDiagnosticClient()
        client.finish(.success(()))
        _ = try await self.run(client) {
            MainManager.retainPostProcessingDiagnostic($0, for: session, activeSession: session)
        }.get()
        XCTAssertNil(session.diagnosticContext)
        let report = HistoryIssueReporter.report(for: session.buildHistoryItem(finalText: nil))
        XCTAssertTrue(report.jsonString.contains("missingLegacyContext"))
        XCTAssertFalse(report.jsonString.contains("postProcessingHandoff"))
    }

    private func run(_ client: ChatLLMClient, streaming: Bool = true,
                     observe: ((RequestDiagnosticContext.PostProcessingObservation) -> Void)?)
        async -> Result<PostProcessingOutcome, Error> {
        await PostProcessingManager.performRemoteProcess(
            client: client, rawText: PostDiagnosticClient.canary,
            promptPayload: .init(modelIdentifier: "openai/gpt-4o-mini", customPrompt: nil,
                                 systemPrompt: PostDiagnosticClient.canary, userPrompt: PostDiagnosticClient.canary),
            settings: (streamingEnabled: { streaming }, temperature: { 0.3 }),
            delivery: .init(log: SpeakLogger.logger(category: "OwnedPostProcessingFixture"),
                       streamingUpdate: nil, diagnostic: observe)
        )
    }

    private func session() -> ActiveSession {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "owned")
        session.diagnosticContext = HistoryDiagnosticContext(
            capturedAt: Date(timeIntervalSince1970: 1), appVersion: "unknown", appBuild: "unknown",
            operatingSystem: "unknown", processIdentifier: 1, microphonePermission: "unknown",
            inputDeviceName: PostDiagnosticClient.canary, providerLabel: PostDiagnosticClient.canary,
            latencyTier: "unknown", transcriptionMode: "unknown", transcriptionModel: PostDiagnosticClient.canary,
            postProcessingModel: PostDiagnosticClient.canary, speedMode: "unknown",
            requestContext: .init(model: .project("openai/whisper-1"), mode: .batch),
            observedHandoff: .init(provenance: .observedHandoff,
                                   model: .project("deepgram/nova-3-streaming"), mode: .live),
            requestFailure: .init(stage: .request, code: .timeout)
        )
        return session
    }
}
