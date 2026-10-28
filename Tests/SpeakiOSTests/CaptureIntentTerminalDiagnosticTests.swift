#if os(iOS) && DEBUG && targetEnvironment(simulator)
import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

@available(iOS 18, *)
@MainActor
final class CaptureIntentTerminalDiagnosticTests: XCTestCase {
    func testActualFailedAdmissionsKeepDistinctCodesWithoutPersistingPrivateErrors() async throws {
        let cases: [(Error, String)] = [
            (iOSTranscriptionError.permissionDenied(.microphone), "start_permission_microphone"),
            (StreamingClientError.missingAPIKey(provider: "private-provider"), "start_missing_api_key"),
            (AppSettings.CredentialLoadingError.unavailable, "start_credentials_unavailable"),
            (NSError(domain: "AppleSpeechPreparation", code: 1), "start_apple_model_unprepared")
        ]
        for (error, code) in cases {
            let harness = try DependencyHarness()
            defer { harness.cleanUp() }
            let service = harness.makeService()
            service.makeSession = { throw error }
            do {
                try await self.start(service)
                XCTFail("An actual failed service admission must throw")
            } catch {}
            XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: harness.defaults), code)
            XCTAssertEqual(harness.defaults.string(forKey: "captureHealth.lastOutcome.v1"), "failed")
            let journal = self.journal(harness)
            XCTAssertEqual(journal.count, 3)
            XCTAssertFalse(String(describing: journal).contains("private-"))
            XCTAssertNil(service.lastSessionError, "Intent journaling must not manufacture an alert publication")
            XCTAssertEqual(service.state, .idle)
        }
    }

    func testSuccessfulForegroundRetryPreservesPriorJournalAndFrozenConfiguration() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        self.seedJournal(harness)
        let before = self.journal(harness)
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        harness.defaults.set("Retry words", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        var foregroundRequests = 0
        try await startRecordingWithForegroundRecovery(service: service, start: { request in
            try await self.startAttempt(service, request: request)
        }, continueInForeground: { continuation in
            foregroundRequests += 1
            harness.applicationState = .active
            harness.activityStartsSuccessfully = true
            try await continuation()
        })
        XCTAssertEqual(foregroundRequests, 1)
        XCTAssertEqual(harness.focusReads, 1, "Recovery keeps the first attempt's configuration")
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(self.journal(harness), before)
    }

    func testFailedForegroundRetryRecordsOnlyItsFinalAdmittedCause() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        let service = harness.makeService()
        service.makeSession = { throw StreamingClientError.missingAPIKey(provider: "private-provider") }
        var foregroundRequests = 0
        do {
            try await startRecordingWithForegroundRecovery(service: service, start: { request in
                try await self.startAttempt(service, request: request)
            }, continueInForeground: { continuation in
                foregroundRequests += 1
                harness.applicationState = .active
                harness.activityStartsSuccessfully = true
                try await continuation()
            })
            XCTFail("Second admitted attempt must propagate its failure")
        } catch {}
        XCTAssertEqual(foregroundRequests, 1)
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: harness.defaults), "start_missing_api_key")
        XCTAssertEqual(harness.focusReads, 1)
        XCTAssertEqual(service.state, .idle)
    }

    func testUnknownForegroundFrameworkFailureStaysUnknownWithoutClaimingUserDecline() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        let service = harness.makeService()
        do {
            try await startRecordingWithForegroundRecovery(service: service, start: { request in
                try await self.startAttempt(service, request: request)
            }, continueInForeground: { _ in throw self.privateFrameworkError })
            XCTFail("Framework error must propagate")
        } catch {}
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: harness.defaults), "start_unknown")
        XCTAssertEqual(self.journal(harness).count, 3)
        XCTAssertFalse(String(describing: self.journal(harness)).contains("private-"))
    }

    func testLateFrameworkFailureCannotOverwriteSameRunDeliveredOutcome() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        harness.defaults.set("Delivered words", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        var deliveredJournal: [String: AnyHashable] = [:]
        do {
            try await startRecordingWithForegroundRecovery(service: service, start: { request in
                try await self.startAttempt(service, request: request)
            }, continueInForeground: { continuation in
                harness.applicationState = .active
                harness.activityStartsSuccessfully = true
                try await continuation()
                _ = await service.stopRecording(destination: .historyOnly)
                deliveredJournal = self.journal(harness)
                throw self.privateFrameworkError
            })
            XCTFail("The late framework error still propagates to its caller")
        } catch {}
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Delivered words"])
        XCTAssertEqual(deliveredJournal["captureHealth.lastOutcome.v1"]?.base as? String, "delivered")
        XCTAssertEqual(self.journal(harness), deliveredJournal)
        XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: harness.defaults))
    }

    func testLateOldFrameworkFailureCannotOverwriteActiveOrCompletedReplacement() async throws {
        for completeReplacement in [false, true] {
            let harness = try DependencyHarness()
            defer { harness.cleanUp() }
            self.seedJournal(harness)
            harness.applicationState = .background
            harness.activityStartsSuccessfully = false
            harness.defaults.set("Replacement words", forKey: "simulatorValidationTranscript")
            let service = harness.makeService()
            var replacementJournal: [String: AnyHashable] = [:]
            do {
                try await startRecordingWithForegroundRecovery(service: service, start: { request in
                    try await self.startAttempt(service, request: request)
                }, continueInForeground: { _ in
                    harness.applicationState = .active
                    harness.activityStartsSuccessfully = true
                    try await service.startRecording(requiresLiveActivity: false)
                    if completeReplacement { _ = await service.stopRecording(destination: .historyOnly) }
                    replacementJournal = self.journal(harness)
                    throw self.privateFrameworkError
                })
                XCTFail("Old framework call must propagate its own failure")
            } catch {}
            XCTAssertEqual(self.journal(harness), replacementJournal)
            XCTAssertEqual(service.state, completeReplacement ? .idle : .recording)
            XCTAssertEqual(harness.history.items.count, completeReplacement ? 1 : 0)
        }
    }

    func testForeignOwnerBeforeAdmissionPreservesRealPriorJournal() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        self.seedJournal(harness)
        let before = self.journal(harness)
        let ownership = ForegroundRecordingOwnership()
        let owner = UUID()
        XCTAssertTrue(ownership.claim(owner))
        defer { ownership.release(owner) }
        let service = harness.makeService(foregroundOwnership: ownership)
        do { try await self.start(service); XCTFail("Foreign owner must refuse admission") } catch {}
        XCTAssertEqual(self.journal(harness), before)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertEqual(service.state, .idle)
    }

    func testKnownCancellationRecordsNeutralOutcomeWithoutGenericFailureCode() async throws {
        for cancelForegroundContinuation in [false, true] {
            let harness = try DependencyHarness()
            defer { harness.cleanUp() }
            self.seedJournal(harness)
            if cancelForegroundContinuation {
                harness.applicationState = .background
                harness.activityStartsSuccessfully = false
            }
            let service = harness.makeService()
            service.makeSession = { throw CancellationError() }
            do {
                try await startRecordingWithForegroundRecovery(service: service, start: { request in
                    try await self.startAttempt(service, request: request)
                }, continueInForeground: { _ in throw CancellationError() })
                XCTFail("Cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(harness.defaults.string(forKey: "captureHealth.lastOutcome.v1"), "cancelled")
            XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: harness.defaults))
            XCTAssertNil(service.lastSessionError)
        }
    }

    private var privateFrameworkError: Error {
        NSError(domain: "private-framework", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-transcript-key"])
    }

    private func start(_ service: TranscriptionRecordingService) async throws {
        try await startRecordingWithForegroundRecovery(service: service, start: { request in
            try await self.startAttempt(service, request: request)
        }, continueInForeground: { _ in XCTFail("This failure must not trigger foreground recovery") })
    }

    private func startAttempt(
        _ service: TranscriptionRecordingService, request: CaptureConfigurationRequest
    ) async throws {
        try await service.startRecording(destination: nil, configurationRequest: request)
    }

    private func seedJournal(_ harness: DependencyHarness) {
        CaptureOutcomeJournal.record(
            .failed, failure: iOSTranscriptionError.permissionDenied(.microphone),
            at: Date(timeIntervalSince1970: 100), defaults: harness.defaults
        )
    }

    private func journal(_ harness: DependencyHarness) -> [String: AnyHashable] {
        (harness.defaults.persistentDomain(forName: harness.suite) ?? [:])
            .filter { $0.key.hasPrefix("captureHealth.last") }
            .compactMapValues { $0 as? AnyHashable }
    }
}
#endif
