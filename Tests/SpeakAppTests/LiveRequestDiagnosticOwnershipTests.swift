import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class LiveRequestDiagnosticOwnershipTests: XCTestCase {
    func testHeldStartFailureAfterReplacementOrCancellationCannotMutateEitherOwner() async throws {
        for cancelled in [false, true] {
            let held = LiveDiagnosticHeldStart()
            let session = self.session()
            let replacement = self.session()
            var active: ActiveSession? = session
            let exit = XCTestExpectation(description: "retired live start exited")
            let task = Task { @MainActor in
                defer { exit.fulfill() }
                try await TranscriptionManager.performLiveInvocation(
                    model: "deepgram/nova-3-streaming", language: "en", onDiagnostic: {
                        MainManager.retainBatchDiagnostic($0, for: session, activeSession: active)
                    }, start: { try await held.start() }
                )
            }
            self.own(task, held: held, exit: exit)
            await fulfillment(of: [held.entered], timeout: 2)
            let admitted = session.diagnosticContext
            XCTAssertNotNil(admitted?.observedHandoff)
            let other = replacement.diagnosticContext
            if cancelled { task.cancel() } else { active = replacement }
            held.complete(.failure(URLError(.timedOut)))
            do {
                try await task.value
                XCTFail("The uncooperative start's original failure must propagate")
            } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertEqual(session.diagnosticContext, admitted)
            XCTAssertEqual(replacement.diagnosticContext, other)
        }
    }

    func testLiveFailureHistoryAndLocalRecordRoundTripKeepAdmissionSeparateFromObservedInput() async throws {
        let session = self.session()
        let admission = session.diagnosticContext?.requestContext
        do {
            try await TranscriptionManager.performLiveInvocation(
                model: "deepgram/nova-3-streaming", language: "en", onDiagnostic: {
                    MainManager.retainBatchDiagnostic($0, for: session, activeSession: session)
                }, start: { throw URLError(.timedOut) }
            )
            XCTFail("The start must fail")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let item = session.buildHistoryItem(finalText: nil)
        XCTAssertEqual(item.diagnosticContext?.requestContext, admission)
        XCTAssertEqual(item.diagnosticContext?.requestContext?.mode, .batch)
        XCTAssertEqual(item.diagnosticContext?.observedHandoff?.mode, .live)
        XCTAssertEqual(item.diagnosticContext?.observedHandoff?.model.identifier, "deepgram/nova-3-streaming")
        XCTAssertNil(item.diagnosticContext?.observedHandoff?.observedProvider)
        XCTAssertEqual(item.diagnosticContext?.requestFailure,
                       .init(stage: .request, code: .timeout, domain: .transport))
        let record = try JSONDecoder().decode(HistoryRecord.self, from: JSONEncoder().encode(item.historyRecord))
        let restored = try XCTUnwrap(HistoryItem(historyRecord: record))
        XCTAssertEqual(restored, item)
        let report = HistoryIssueReporter.report(for: restored)
        XCTAssertFalse((report.title + report.body + report.jsonString + (report.issueURL?.absoluteString ?? ""))
            .contains(LiveDiagnosticHeldStart.canary))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
        XCTAssertNotNil(object["context"])
        XCTAssertNotNil(object["observedHandoff"])
        XCTAssertEqual((object["failures"] as? [[String: Any]])?.first?["code"] as? String, "timeout")
        let removed = IssueDiagnosticReport(
            context: admission, omittedSections: Set(IssueDiagnosticReport.Section.allCases),
            observedHandoff: item.diagnosticContext?.observedHandoff
        )
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: removed.jsonData) as? [String: Any])
        XCTAssertNil(empty["context"])
        XCTAssertNil(empty["observedHandoff"])
        XCTAssertEqual(empty["contextState"] as? String, "userRemoved")
    }

    func testMissingLegacyContextDoesNotInventAdmissionOrPersistLiveReceipt() async throws {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: LiveDiagnosticHeldStart.canary)
        try await TranscriptionManager.performLiveInvocation(
            model: "deepgram/nova-3-streaming", language: nil, onDiagnostic: {
                MainManager.retainBatchDiagnostic($0, for: session, activeSession: session)
            }, start: {}
        )
        XCTAssertNil(session.diagnosticContext)
        let report = HistoryIssueReporter.report(for: session.buildHistoryItem(finalText: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
        XCTAssertEqual(object["contextState"] as? String, "missingLegacyContext")
        XCTAssertNil(object["observedHandoff"])
    }

    private func own(_ task: Task<Void, Error>, held: LiveDiagnosticHeldStart, exit: XCTestExpectation) {
        addTeardownBlock { @MainActor in
            task.cancel()
            held.complete(.failure(CancellationError()))
            let result = await XCTWaiter.fulfillment(of: [exit], timeout: 2)
            XCTAssertEqual(result, .completed, "No owned start continuation may survive teardown")
        }
    }

    private func session() -> ActiveSession {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: LiveDiagnosticHeldStart.canary)
        session.diagnosticContext = HistoryDiagnosticContext(
            appVersion: "unknown", appBuild: "unknown", operatingSystem: "unknown", processIdentifier: 1,
            microphonePermission: "unknown", inputDeviceName: LiveDiagnosticHeldStart.canary,
            providerLabel: LiveDiagnosticHeldStart.canary, latencyTier: "unknown", transcriptionMode: "unknown",
            transcriptionModel: LiveDiagnosticHeldStart.canary, postProcessingModel: LiveDiagnosticHeldStart.canary,
            speedMode: "unknown", requestContext: .init(model: .project("openai/whisper-1"), mode: .batch)
        )
        return session
    }
}
