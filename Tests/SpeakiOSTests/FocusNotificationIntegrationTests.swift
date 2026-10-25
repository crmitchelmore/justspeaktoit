#if os(iOS) && DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

@MainActor
final class FocusNotificationIntegrationTests: XCTestCase {
    func testBackgroundFocusHistoryOnlySuppressesSameRunGenericActivityWithoutExternalTranscript() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanUp() }
        let manager = self.makeManager()
        defer { manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))
        try await service.startRecording(requiresLiveActivity: false)
        harness.focus = .none
        harness.settings.hardwareTriggerDestination = .clipboardAndPostProcess
        _ = await service.stopRecording(selection: service.resolvedStopSelection())
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertTrue(input.matchingResultActivity)
        XCTAssertFalse(input.isEligible)
        XCTAssertEqual(input.historyID, harness.history.items.first?.id)
        XCTAssertEqual(service.lastCompletedDestination?.origin, .focus)
        try self.assertPrivate(harness, manager: manager)
    }

    func testUnrelatedCompletedActivityDoesNotSuppressGenericHistoryOnlyAlert() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanUp() }
        let manager = self.makeManager()
        defer { manager.endActivity() }
        var activity = RecordingServiceActivity.live(manager)
        let complete = try XCTUnwrap(activity.completeOwned)
        activity.completeOwned = { count, duration, primed, outcome, preview, message, copyToken, owner in
            complete(count, duration, primed, outcome, preview, message, copyToken, owner)
            // The same native activity can now belong to another completion.
            manager.completeActivity(
                finalWordCount: 1, duration: 1, keepPrimed: true,
                completionOutcome: .ready, surfaceOwnerID: UUID()
            )
        }
        let service = harness.makeService(activity: activity)
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(selection: service.resolvedStopSelection())
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertFalse(input.matchingResultActivity)
        XCTAssertTrue(input.isEligible)
        let identifier = try XCTUnwrap(input.historyID)
        let content = TranscriptReadyNotificationRoute.content(for: identifier)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertEqual(content.body, "Open History to view your saved transcription")
        XCTAssertEqual(Set(content.userInfo.keys), Set([AnyHashable("schema"), AnyHashable("historyID")]))
        XCTAssertEqual(content.userInfo["historyID"] as? String, identifier.uuidString)
        try self.assertPrivate(harness, manager: manager)
    }

    func testSalvagedFailureRemainsIneligibleWithFrozenFocusAndDurableHistory() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanUp() }
        let manager = self.makeManager()
        defer { manager.endActivity() }
        let session = DependencySession()
        session.stopError = URLError(.timedOut)
        let service = harness.makeService(activity: .live(manager))
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        session.onPartialResult?("Private salvaged words", false)
        _ = await service.stopRecording(selection: service.resolvedStopSelection())
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertNotNil(input.historyID)
        XCTAssertTrue(input.failed)
        XCTAssertFalse(input.isEligible)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertNil(harness.keyboard.pendingOffer())
        XCTAssertTrue(harness.polishRequests.isEmpty)
        XCTAssertEqual(manager.latestState?.resultCompletionID, "")
        XCTAssertEqual(manager.latestState?.resultPreview, "")
    }

    func testCancelDuringHeldDrainPublishesNeitherHistoryNorNotification() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanUp() }
        let manager = self.makeManager()
        defer { manager.endActivity() }
        let gate = DependencyKeyLoadGate(entered: expectation(description: "owned drain entered"))
        let session = DependencySession()
        session.finish = {
            await gate.wait()
            return TranscriptionResult(
                text: "Private cancelled words", segments: [], confidence: nil, duration: 1,
                modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        let service = harness.makeService(activity: .live(manager))
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        let done = expectation(description: "owned stop settled")
        let stop = Task { _ = await service.stopRecording(selection: service.resolvedStopSelection()); done.fulfill() }
        defer { service.cancelRecording(); gate.release(); stop.cancel() }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Drain did not register")
        }
        service.cancelRecording()
        gate.release()
        guard await XCTWaiter.fulfillment(of: [done], timeout: 2) == .completed else {
            return XCTFail("Cancelled drain did not settle")
        }
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertTrue(harness.notifications.isEmpty)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertNil(harness.keyboard.pendingOffer())
        XCTAssertTrue(harness.polishRequests.isEmpty)
        XCTAssertFalse(service.isActive)
    }

    func testUnsavedAndEmptyFocusCompletionsCannotBecomeNotificationEligible() async throws {
        for saveToHistory in [false, true] {
            let harness = try self.makeHarness()
            defer { harness.cleanUp() }
            if saveToHistory { harness.defaults.set(" \n ", forKey: "simulatorValidationTranscript") }
            let manager = self.makeManager()
            defer { manager.endActivity() }
            let service = harness.makeService(activity: .live(manager))
            try await service.startRecording(requiresLiveActivity: false)
            _ = await service.stopRecording(
                selection: service.resolvedStopSelection(), saveToHistory: saveToHistory
            )
            let input = try XCTUnwrap(harness.notifications.first)
            XCTAssertFalse(input.isEligible)
            if saveToHistory { XCTAssertTrue(input.transcriptIsEmpty) } else { XCTAssertNil(input.historyID) }
            XCTAssertTrue(harness.pasteboard.writes.isEmpty)
            XCTAssertNil(harness.keyboard.pendingOffer())
            XCTAssertTrue(harness.polishRequests.isEmpty)
        }
    }

    func testExistingInjectedCompletionCallbackRetainsOwnershipOfActivityEffects() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanUp() }
        let manager = self.makeManager()
        defer { manager.endActivity() }
        var completions = 0
        let service = harness.makeService(
            activity: .live(manager), completion: { _, _, _, _, _, _, _ in completions += 1 }
        )
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(selection: service.resolvedStopSelection())
        XCTAssertEqual(completions, 1)
        XCTAssertNotEqual(manager.latestState?.status, .completed, "The live owned callback must not bypass injection")
        XCTAssertFalse(try XCTUnwrap(harness.notifications.first).matchingResultActivity)
    }

    private func makeHarness() throws -> DependencyHarness {
        let harness = try DependencyHarness()
        harness.applicationState = .background
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
        harness.settings.autoPostProcess = true
        harness.defaults.set("Private Focus words", forKey: "simulatorValidationTranscript")
        return harness
    }

    private func makeManager() -> TranscriptionActivityManager {
        let activity = FakeActivity()
        return TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in activity },
            sleep: { _ in throw CancellationError() }
        )
    }

    private func assertPrivate(_ harness: DependencyHarness, manager: TranscriptionActivityManager) throws {
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Private Focus words"])
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertNil(harness.keyboard.pendingOffer())
        XCTAssertTrue(harness.polishRequests.isEmpty)
        XCTAssertNotEqual(harness.defaults.string(forKey: "lastCompletedTranscript"), "Private Focus words")
        XCTAssertNotEqual(harness.defaults.string(forKey: "currentTranscriptText"), "Private Focus words")
        let state = try XCTUnwrap(manager.latestState)
        XCTAssertEqual(state.resultPreview, "")
        XCTAssertEqual(state.resultCompletionID, "")
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Private Focus words"))
        XCTAssertNotEqual(TranscriptHandoffPublisher.currentEntryID, try XCTUnwrap(harness.history.items.first?.id))
    }
}
#endif
