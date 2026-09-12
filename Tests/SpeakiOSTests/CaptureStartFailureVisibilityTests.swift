#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// Drives `CaptureCommandRunner`'s real failure path — the one a Home Screen
/// quick action reaches when its start throws — through the `publish` seam,
/// with the errors the recorder actually throws (issue #944).
@MainActor
final class CaptureStartFailureVisibilityTests: XCTestCase {
    private var published: [Error] = []

    /// - Returns: whether the user was told, which is what these assert on.
    ///   The disposition itself is covered by `CaptureStartFailurePolicyTests`.
    private func surface(
        _ error: Error,
        later: Bool = false,
        ownedElsewhere: Bool = false
    ) -> Bool {
        self.disposition(error, later: later, ownedElsewhere: ownedElsewhere).presentedMessage != nil
    }

    private func disposition(
        _ error: Error,
        later: Bool = false,
        ownedElsewhere: Bool = false
    ) -> CaptureStartFailurePolicy.Disposition {
        CaptureCommandRunner.surfaceStartFailure(
            error,
            laterCaptureInFlight: later,
            microphoneOwnedElsewhere: ownedElsewhere,
            publish: { self.published.append($0) }
        )
    }

    override func setUp() {
        super.setUp()
        self.published = []
    }

    func testDeniedMicrophonePermissionIsPublishedWithItsActionableMessage() {
        XCTAssertTrue(surface(iOSTranscriptionError.permissionDenied(.microphone)))
        XCTAssertEqual(self.published.count, 1)
        let presentation = self.published.first as? CaptureStartFailurePresentation
        XCTAssertEqual(presentation?.code, "start_permission_microphone")
        XCTAssertEqual(presentation?.recovery, .appPermissions)
    }

    func testMissingLiveActivityIsPublishedRatherThanOnlyLogged() {
        // The recorder throws this when a background start has no Live
        // Activity to run under; the capture genuinely did not begin, and the
        // message tells the user which setting to turn on.
        XCTAssertTrue(surface(iOSTranscriptionError.liveActivityUnavailable))
        XCTAssertEqual(self.published.count, 1)
        XCTAssertEqual(
            (self.published.first as? CaptureStartFailurePresentation)?.recovery,
            .appPermissions
        )
    }

    func testMissingKeyPublishesCredentialRecoveryWithoutItsProviderIdentifier() {
        XCTAssertTrue(self.surface(StreamingClientError.missingAPIKey(provider: "private-provider-id")))
        XCTAssertEqual(self.published.count, 1)
        let presentation = self.published.first as? CaptureStartFailurePresentation
        XCTAssertEqual(presentation?.code, "start_missing_api_key")
        XCTAssertEqual(presentation?.recovery, .credentials)
        XCTAssertFalse(presentation?.message.contains("private-provider-id") == true)
    }

    /// The disposition, not just the silence: `dictate` reads this to answer
    /// its caller with `x-cancel` rather than a failure, so the difference
    /// between "cancelled" and "silently failed" has to survive this call.
    func testACancelledStartIsReportedAsCancelledRatherThanMerelySilent() {
        XCTAssertEqual(disposition(CancellationError()), .logOnly(.cancelled))
        XCTAssertEqual(
            disposition(iOSTranscriptionError.recognizerUnavailable, later: true),
            .logOnly(.superseded)
        )
        XCTAssertTrue(published.isEmpty)
    }

    /// The alert receives the message the policy chose, not the raw error: an
    /// error whose `localizedDescription` is blank or padded would otherwise
    /// reach the user as an empty or malformed alert.
    func testThePublishedFailureCarriesTheNormalisedMessage() throws {
        struct BlankError: LocalizedError { var errorDescription: String? { "   " } }

        XCTAssertTrue(surface(BlankError()))
        let published = try XCTUnwrap(self.published.first)
        XCTAssertEqual((published as? CaptureStartFailurePresentation)?.code, "start_unknown")
        XCTAssertEqual(
            published.localizedDescription,
            "Recording couldn't start. Try again, or open the app to check your setup."
        )
        XCTAssertFalse(published.localizedDescription.isEmpty)
    }

    func testCancelledStartPublishesNothing() {
        // The recorder's run-identity guard turns a retired start into a
        // `CancellationError`; a second press cancelling the first must not
        // alert.
        XCTAssertFalse(surface(CancellationError()))
        XCTAssertTrue(published.isEmpty)
    }

    func testSupersededStartPublishesNothing() {
        XCTAssertFalse(surface(iOSTranscriptionError.recognizerUnavailable, later: true))
        XCTAssertTrue(published.isEmpty)
    }

    func testFailureWhileTheInAppRecorderOwnsTheMicrophonePublishesNothing() {
        XCTAssertFalse(surface(iOSTranscriptionError.recognizerUnavailable, ownedElsewhere: true))
        XCTAssertTrue(published.isEmpty)
    }

    func testASuccessfulLaterStartInheritsNoEarlierFailure() {
        XCTAssertTrue(surface(iOSTranscriptionError.permissionDenied(.microphone)))
        // The retry is in flight, so the earlier failure is stale and stays
        // out of the alert.
        XCTAssertFalse(surface(CancellationError(), later: true))
        XCTAssertEqual(published.count, 1)
    }

    func testPublishedFailureReachesTheServiceAlertPath() {
        // The production sink: the same published error the app's alert
        // already watches, rather than a parallel error store.
        let service = TranscriptionRecordingService.shared
        service.reportCaptureFailure(iOSTranscriptionError.permissionDenied(.microphone))
        XCTAssertEqual(
            service.lastSessionError?.localizedDescription,
            iOSTranscriptionError.permissionDenied(.microphone).localizedDescription
        )
    }

    func testEveryStartOutcomeReportsWhetherItStarted() {
        XCTAssertTrue(CaptureCommandRunner.StartOutcome.started.didStart)
        XCTAssertFalse(CaptureCommandRunner.StartOutcome.cancelled.didStart)
        XCTAssertFalse(
            CaptureCommandRunner.StartOutcome.failed(.recordingFailed, surfaced: true).didStart
        )
        XCTAssertFalse(
            CaptureCommandRunner.StartOutcome.failed(.modelUnavailable, surfaced: false).didStart
        )
    }

    /// A failed start carries the reason, not just the fact: `dictate` hands it
    /// to the caller's `x-error`, so a `model=` this device cannot honour must
    /// not arrive as a generic `recordingFailed`.
    func testAFailedStartCarriesTheReasonTheCallerWillBeGiven() {
        let outcome = CaptureCommandRunner.StartOutcome.failed(.modelUnavailable, surfaced: true)
        guard case .failed(let failure, let surfaced) = outcome else {
            return XCTFail("Expected a failed outcome")
        }
        XCTAssertEqual(failure, .modelUnavailable)
        XCTAssertTrue(surfaced)
        XCTAssertNotEqual(
            outcome,
            .failed(.recordingFailed, surfaced: true),
            "Two different reasons must not compare equal"
        )
    }
}
#endif
