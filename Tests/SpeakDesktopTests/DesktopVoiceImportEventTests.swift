import XCTest
import SpeakCore
import SpeakDesktop

final class DesktopVoiceImportEventTests: XCTestCase {
    func testCancellation_DropsOnlyItsQueuedFileImportNotVoiceWork() throws {
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic speech")
        var pending: [DesktopHistoryEvent] = [.voiceRead(snapshot)]
        DesktopHistoryEvent.coalesce(&pending, .voiceImport(path: "/text.txt", requestID: "file"))
        DesktopHistoryEvent.coalesce(&pending, .voiceImportCancel(requestID: "file"))
        XCTAssertEqual(pending, [.voiceRead(snapshot)])
    }

    func testActiveCancellation_SurvivesOtherCancelledImportsAndRemainsBounded() {
        var pending: [DesktopHistoryEvent] = []
        DesktopHistoryEvent.coalesce(&pending, .voiceImportCancel(requestID: "active"))
        for index in 0..<1_000 {
            let requestID = String(index)
            DesktopHistoryEvent.coalesce(&pending, .voiceImport(path: "/text.txt", requestID: requestID))
            DesktopHistoryEvent.coalesce(&pending, .voiceImportCancel(requestID: requestID))
        }
        XCTAssertEqual(pending, [.voiceImportCancel(requestID: "active")])
    }

    func testStop_DropsQueuedImportBeforeItCanOpenAFile() {
        var pending: [DesktopHistoryEvent] = [.voiceImport(path: "/text.txt", requestID: "file")]
        DesktopHistoryEvent.coalesce(&pending, .stop)
        XCTAssertEqual(pending, [.stop])
    }
}
