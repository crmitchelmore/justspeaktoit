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
        published = []
    }

    func testDeniedMicrophonePermissionIsPublishedWithItsActionableMessage() {
        XCTAssertTrue(surface(iOSTranscriptionError.permissionDenied(.microphone)))
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(
            published.first?.localizedDescription,
            iOSTranscriptionError.permissionDenied(.microphone).localizedDescription
        )
    }

    func testMissingLiveActivityIsPublishedRatherThanOnlyLogged() {
        // The recorder throws this when a background start has no Live
        // Activity to run under; the capture genuinely did not begin, and the
        // message tells the user which setting to turn on.
        XCTAssertTrue(surface(iOSTranscriptionError.liveActivityUnavailable))
        XCTAssertEqual(published.count, 1)
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
        XCTAssertEqual(
            published.localizedDescription,
            CaptureLinkFailure.recordingFailed.localizedDescription,
            "A failure with nothing quotable must still say the recording did not start"
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
        XCTAssertFalse(CaptureCommandRunner.StartOutcome.failed(surfaced: true).didStart)
        XCTAssertFalse(CaptureCommandRunner.StartOutcome.failed(surfaced: false).didStart)
    }
}
#endif
