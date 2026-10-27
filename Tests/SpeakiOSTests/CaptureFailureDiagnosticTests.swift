#if os(iOS)
import ActivityKit
import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

final class CaptureFailureDiagnosticTests: XCTestCase {
    @MainActor
    func testJournalPersistsOnlyMappedCodesAndClearsThemForLaterOutcomes() throws {
        let suite = "CaptureFailureDiagnosticTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failures: [(Error, String)] = [
            (iOSTranscriptionError.permissionDenied(.microphone), "start_permission_microphone"),
            (StreamingClientError.missingAPIKey(provider: "private-provider"), "start_missing_api_key"),
            (AppSettings.CredentialLoadingError.unavailable, "start_credentials_unavailable"),
            (iOSTranscriptionError.finalisationTimedOut, "start_finalisation_timeout"),
            (NSError(domain: "private-provider", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "private-transcript-and-key"
            ]), "start_unknown")
        ]
        for (error, expectedCode) in failures {
            CaptureOutcomeJournal.record(
                CaptureOutcomeJournal.outcome(for: error), failure: error,
                at: Date(timeIntervalSince1970: 123), defaults: defaults
            )
            XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: defaults), expectedCode)
            let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
            XCTAssertEqual(stored.count, 3, "Only outcome, date and the closed-mapped code are stored")
            XCTAssertFalse(String(describing: stored).contains("private-"))
        }
        for outcome in [CaptureHealthLastOutcome.delivered, .cancelled] {
            CaptureOutcomeJournal.record(.failed, failure: failures[0].0, defaults: defaults)
            XCTAssertNotNil(CaptureOutcomeJournal.lastFailureCode(defaults: defaults))
            CaptureOutcomeJournal.record(outcome, failure: CancellationError(), defaults: defaults)
            XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: defaults))
            XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 2)
        }
        CaptureOutcomeJournal.record(.failed, failure: failures[0].0, defaults: defaults)
        CaptureOutcomeJournal.record(.failed, failure: nil, defaults: defaults)
        XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: defaults), "Legacy callers remain neutral")
    }

    @MainActor
    func testActivityReceivesMappedCodeAndDoesNotReuseItForLegacyErrorOrNextRun() async throws {
        let activity = FakeActivity()
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in activity }
        )
        defer { activity.didUpdate = nil; manager.endActivity() }
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        let published = expectation(description: "classified error reaches activity handle")
        activity.didUpdate = { state in
            if state.failureCode == "start_permission_speech_recognition" { published.fulfill() }
        }
        RecordingServiceActivity.live(manager).reportClassifiedError(
            iOSTranscriptionError.permissionDenied(.speechRecognition)
        )
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(activity.transcriptionState.status, .error)
        XCTAssertEqual(
            activity.transcriptionState.errorMessage,
            iOSTranscriptionError.permissionDenied(.speechRecognition).localizedDescription
        )
        XCTAssertEqual(activity.transcriptionState.failureCode, "start_permission_speech_recognition")

        let legacy = expectation(description: "legacy error clears previous diagnostic")
        activity.didUpdate = { state in
            if state.errorMessage == "Legacy error" { legacy.fulfill() }
        }
        manager.reportError("Legacy error")
        await fulfillment(of: [legacy], timeout: 2)
        XCTAssertNil(activity.transcriptionState.failureCode)

        let repeated = expectation(description: "another coded error reaches activity handle")
        activity.didUpdate = { state in
            if state.failureCode == "start_permission_speech_recognition" { repeated.fulfill() }
        }
        RecordingServiceActivity.live(manager).reportClassifiedError(
            iOSTranscriptionError.permissionDenied(.speechRecognition)
        )
        await fulfillment(of: [repeated], timeout: 2)
        let replacement = expectation(description: "new recording receives neutral state")
        activity.didUpdate = { state in
            if state.provider == "Replacement" { replacement.fulfill() }
        }
        XCTAssertTrue(manager.startActivity(provider: "Replacement"))
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertNil(activity.transcriptionState.failureCode)
        XCTAssertNil(activity.transcriptionState.errorMessage)
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    func testOwnedStartupFailureRetiresActivityWithCanonicalCodeAndSafeMessage() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let activity = DiagnosticActivity()
        let ended = expectation(description: "owned startup activity retired")
        activity.didEnd = { ended.fulfill() }
        let manager = self.makeManager(activity)
        defer { activity.didEnd = nil; manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))
        service.makeSession = { throw iOSTranscriptionError.permissionDenied(.microphone) }
        do {
            try await service.startRecording(requiresLiveActivity: true)
            XCTFail("Injected session allocation failure must refuse the start")
        } catch {
            guard case .permissionDenied(.microphone) = error as? iOSTranscriptionError else {
                return XCTFail("Unexpected startup failure")
            }
        }
        await fulfillment(of: [ended], timeout: 2)
        let terminal = try XCTUnwrap(activity.finalState)
        XCTAssertEqual(terminal.status, .error)
        XCTAssertEqual(terminal.failureCode, "start_permission_microphone")
        XCTAssertEqual(terminal.errorMessage, "Microphone access is off. Allow it in Settings, then try again.")
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertTrue(activity.endedImmediately)
        XCTAssertFalse(manager.isActivityRunning, "The failure must preserve immediate retirement")
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(SharedTranscriptionState(defaults: harness.defaults).isRecording)
    }

    @MainActor
    func testCancelledStartupRetiresWithoutAClassifiedFailurePayload() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let activity = DiagnosticActivity()
        let ended = expectation(description: "cancelled startup activity retired")
        activity.didEnd = { ended.fulfill() }
        let manager = self.makeManager(activity)
        defer { activity.didEnd = nil; manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))
        service.makeSession = { throw CancellationError() }
        do {
            try await service.startRecording(requiresLiveActivity: true)
            XCTFail("Injected cancellation must refuse the start")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertNil(activity.finalState, "Cancellation retains the existing neutral retirement")
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertEqual(service.state, .idle)
    }

    @MainActor
    func testForegroundReplacementCannotReceiveOldStartupsFailureMetadata() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let activity = DiagnosticActivity()
        let ended = expectation(description: "existing unwind settled neutrally")
        activity.didEnd = { ended.fulfill() }
        let manager = self.makeManager(activity)
        let ownership = ForegroundRecordingOwnership()
        let foregroundRun = UUID()
        defer { activity.didEnd = nil; manager.endActivity(); ownership.release(foregroundRun) }
        let service = harness.makeService(activity: .live(manager), foregroundOwnership: ownership)
        service.makeSession = {
            XCTAssertTrue(ownership.claim(foregroundRun))
            XCTAssertTrue(manager.startActivity(provider: "Foreground replacement"))
            throw iOSTranscriptionError.permissionDenied(.microphone)
        }
        do {
            try await service.startRecording(requiresLiveActivity: true)
            XCTFail("Injected allocation failure must refuse the start")
        } catch {
            XCTAssertTrue(error is iOSTranscriptionError)
        }
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertNil(activity.finalState, "Existing neutral cleanup must not attach the old startup's code")
        XCTAssertFalse(activity.endedImmediately, "The classified-error end path was not selected")
    }

    @MainActor
    func testStartupWithoutActivityDoesNotCreateOneForFailureMetadata() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        var requests = 0
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [] }, request: { _ in
                requests += 1
                return DiagnosticActivity()
            }
        )
        defer { manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))
        service.makeSession = { throw iOSTranscriptionError.permissionDenied(.microphone) }
        do {
            try await service.startRecording(requiresLiveActivity: false)
            XCTFail("Injected allocation failure must refuse the start")
        } catch {
            XCTAssertTrue(error is iOSTranscriptionError)
        }
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(manager.isActivityRunning)
        XCTAssertEqual(service.state, .idle)
    }

    @MainActor
    private func makeManager(_ activity: DiagnosticActivity) -> TranscriptionActivityManager {
        TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [] }, request: { _ in activity }
        )
    }
    #endif
}

@MainActor
private final class DiagnosticActivity: TranscriptionActivityHandle {
    let id = UUID().uuidString
    var activityState: ActivityState = .active
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { nil }
    var transcriptionState = TranscriptionActivityAttributes.ContentState()
    var supportsUpdateTimestamps: Bool { true }
    var finalState: TranscriptionActivityAttributes.ContentState?
    var endCount = 0
    var endedImmediately = false
    var didEnd: (() -> Void)?

    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async {
        self.transcriptionState = state
    }

    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?, timestamp: Date) async {
        self.finalState = state
        self.endCount += 1
        self.activityState = .ended
        self.didEnd?()
    }

    func endTranscriptionImmediately(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async {
        self.endedImmediately = true
        await self.endTranscription(state, timestamp: timestamp)
    }

    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        Task {}
    }
}
#endif
