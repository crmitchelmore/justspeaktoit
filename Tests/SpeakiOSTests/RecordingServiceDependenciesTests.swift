#if os(iOS) && DEBUG && targetEnvironment(simulator)
import AVFoundation
import Combine
import SpeakCore
import UIKit
import XCTest

@testable import SpeakiOSLib

@MainActor
final class RecordingServiceDependenciesTests: XCTestCase {
    func testInjectedSettingsAndActivity_OwnStartAndCompletion() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.settings.hardwareTriggerDestination = .historyOnly
        harness.settings.autoPostProcess = true
        harness.defaults.set("Isolated transcript", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()

        XCTAssertEqual(service.resolvedStopDestination(), .historyOnly)
        harness.settings.autoPostProcess = false
        try await service.startRecording(requiresLiveActivity: false, trigger: .shortcut)
        XCTAssertEqual(service.automaticStopDestination, .historyOnly)
        XCTAssertEqual(harness.activityStarts, [.arming])
        let result = await service.stopRecording(destination: .historyOnly)

        XCTAssertEqual(result.text, "Isolated transcript")
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Isolated transcript"])
        XCTAssertEqual(harness.dictations.map(\.0), [.shortcut])
        XCTAssertEqual(harness.dictations.map(\.1), ["Isolated transcript"])
        XCTAssertEqual(harness.completions, [.ready])
        XCTAssertTrue(harness.activityUpdates.contains(.finalising))
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertTrue(harness.deliveredRecordings.isEmpty, "The simulator stub has no safety recording")
    }

    func testInjectedSettings_ControlAutomaticPolishAndItsModel() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        harness.settings.autoPostProcess = true
        harness.settings.postProcessingModel = "openai/gpt-4o-mini"
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording()
        let polished = expectation(description: "Automatic polish completed")
        let observation = service.$isPostProcessing.filter { !$0 }.prefix(1).sink { _ in polished.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [polished], timeout: 2) == .completed else {
            return XCTFail("Automatic polish did not complete before the timeout")
        }

        XCTAssertEqual(harness.polishRequests.map(\.0), ["Raw transcript"])
        XCTAssertEqual(harness.polishRequests.map(\.1), ["openai/gpt-4o-mini"])
        XCTAssertEqual(harness.history.items.first?.postProcessedTranscription, "Polished transcript")
        XCTAssertEqual(harness.pasteboard.writes, ["Raw transcript"])
        harness.settings.autoPostProcess = false
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording()
        XCTAssertEqual(harness.polishRequests.count, 1)
    }

    func testInjectedApplicationState_RequiresActivityOnlyInBackground() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Transcript", forKey: "simulatorValidationTranscript")
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        let service = harness.makeService()

        do {
            try await service.startRecording(requiresLiveActivity: true)
            XCTFail("Background capture requires a Live Activity")
        } catch {
            guard case .liveActivityUnavailable = error as? iOSTranscriptionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(service.isActive)
        harness.applicationState = .active
        try await service.startRecording(requiresLiveActivity: true)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(harness.activityStarts, [.arming, .arming])
        service.cancelRecording()
    }

    func testInjectedKeyboardStore_PublishesLatePickupAndReceipt() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Keyboard transcript", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .auto)

        XCTAssertEqual(harness.keyboard.pendingOffer()?.text, "Keyboard transcript")
        XCTAssertEqual(harness.keyboard.pendingOffer()?.mode, .latePickup)
        XCTAssertEqual(harness.pasteboard.writes, ["Keyboard transcript"])
        XCTAssertNotNil(service.lastCaptureReceipt)
    }

    func testSuccessfulDelivery_MarksOnlyTheInjectedSessionsSafetyRecording() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let session = DependencySession()
        let service = harness.makeService()
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .historyOnly)

        XCTAssertEqual(harness.deliveredRecordings, [try XCTUnwrap(session.safetyRecordingID)])
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Safety transcript"])
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testSalvagedFailureAndUnsavedCompletion_AreNeverNotificationEligible() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        let session = DependencySession()
        session.stopError = URLError(.timedOut)
        harness.expectsActivityError = true
        let service = harness.makeService()
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        session.onPartialResult?("Salvaged partial", false)
        XCTAssertEqual(service.partialText, "Salvaged partial")
        _ = await service.stopRecording(destination: .historyOnly)
        let failed = try XCTUnwrap(harness.notifications.first)
        XCTAssertEqual(harness.activityErrors.count, 1)
        XCTAssertNotNil(failed.historyID, "A salvaged partial is saved but must not alert")
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.isEligible)
        session.stopError = nil
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .historyOnly, saveToHistory: false)
        let unsaved = try XCTUnwrap(harness.notifications.last)
        XCTAssertNil(unsaved.historyID)
        XCTAssertFalse(unsaved.isEligible)
    }

    func testNonliveDependencyDefaults_KeepNotificationEffectsDisabled() throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let dependencies = RecordingServiceDependencies(
            settings: harness.settings,
            activity: RecordingServiceActivity(
                start: { _, _ in false }, update: { _, _, _, _ in }, endActivity: {},
                reportError: { _ in }, complete: { _, _, _, _, _, _, _ in }
            ),
            keyboardDelivery: harness.keyboard, recordDictation: { _, _ in }, markDelivered: { _ in },
            applicationState: { .background }
        )
        dependencies.notifyTranscriptReady(.init(historyID: UUID()))
        XCTAssertTrue(harness.notifications.isEmpty)
        XCTAssertFalse(harness.settings.transcriptReadyNotificationsEnabled)
    }

    func testBackgroundCompletion_NotifiesWithDurableHistoryIDBeforeOptionalPolish() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        harness.defaults.set("Saved background result", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .historyOnly)
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertEqual(input.historyID, harness.history.items.first?.id)
        XCTAssertTrue(input.isEligible)
        XCTAssertEqual(harness.notifications.count, 1)
        XCTAssertFalse(input.keyboardInserted, "Late pickup offers do not prove insertion")
        XCTAssertNotNil(harness.history.items.first)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testCancellationDuringInjectedKeyLoad_PreventsSessionAllocation() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let keys = DependencyKeyLoadGate(entered: expectation(description: "Key loading entered"))
        var allocations = 0
        let service = harness.makeService(ensureKeysLoaded: { await keys.wait() })
        service.makeSession = {
            allocations += 1
            throw CancellationError()
        }
        let completed = expectation(description: "Cancelled startup completed")
        var startError: Error?
        let start = Task {
            do {
                try await service.startRecording(requiresLiveActivity: false)
            } catch {
                startError = error
            }
            completed.fulfill()
        }
        defer {
            start.cancel()
            service.cancelRecording()
            keys.release()
        }
        guard await XCTWaiter.fulfillment(of: [keys.entered], timeout: 2) == .completed else {
            return XCTFail("Startup did not enter key loading before the timeout")
        }
        service.cancelRecording()
        keys.release()
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            return XCTFail("Cancelled startup did not complete before the timeout")
        }
        XCTAssertTrue(startError is CancellationError, "Cancelled startup must throw CancellationError")
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertTrue(harness.dictations.isEmpty)
        XCTAssertTrue(harness.deliveredRecordings.isEmpty)
    }
}
#endif
