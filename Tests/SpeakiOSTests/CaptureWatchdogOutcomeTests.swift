#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// The outcomes a watchdog fires into have to be readable by the person whose
/// recording just ended (issue #993). The alert that shows them is driven by
/// `TranscriptionRecordingService.lastSessionError`, so these are the words
/// they see.
final class CaptureWatchdogOutcomeTests: XCTestCase {
    func testStalledStartNamesTheBoundaryItReached() {
        let message = iOSTranscriptionError
            .startTimedOut(after: .audioSessionConfigured)
            .localizedDescription
        XCTAssertTrue(message.contains("configuring audio"), message)
    }

    func testStalledStartWithNoBoundarySaysSo() {
        let message = iOSTranscriptionError.startTimedOut(after: nil).localizedDescription
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("nil"), message)
    }

    func testEveryStartBoundaryHasWordsOfItsOwn() {
        var seen: Set<String> = []
        for stage in StartupStage.allCases {
            let described = iOSTranscriptionError.describe(stage)
            XCTAssertFalse(described.isEmpty)
            XCTAssertNotEqual(described, stage.rawValue, "closed-set label leaked into user copy")
            XCTAssertTrue(seen.insert(described).inserted, "duplicate copy for \(stage.rawValue)")
        }
    }

    /// A dead microphone and an unfinished transcript are different failures
    /// and must not be reported with the same sentence.
    func testWatchdogOutcomesAreDistinguishable() {
        let noAudio = iOSTranscriptionError.microphoneDeliveredNoAudio.localizedDescription
        let timedOut = iOSTranscriptionError.finalisationTimedOut.localizedDescription
        XCTAssertFalse(noAudio.isEmpty)
        XCTAssertFalse(timedOut.isEmpty)
        XCTAssertNotEqual(noAudio, timedOut)
    }
}
#endif
