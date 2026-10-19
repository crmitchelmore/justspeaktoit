import Foundation
import XCTest
import SpeakCore
import SpeakDesktopHost

extension DesktopHostReadAloudTests {
    func testSpeechPause_ControlsCapturedSpeechWithoutUsingSelectedHistory() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        for source in [VoiceOutputSource.clipboard, .externalSelection] {
            FakeSpeech.shared.reset(holdingSegments: true)
            defer { FakeSpeech.shared.releaseSegments() }
            await controller.readVoiceSource(source) { "Pause this captured speech." }
            try await waitFor("captured speech") { FakeSpeech.shared.events.contains("play") }
            let task = await controller.readAloudState.task
            let selected = await controller.selectedHistoryID
            let owner = await controller.voiceOutputRecordID
            XCTAssertEqual(selected, record)
            XCTAssertNil(owner)
            await controller.pauseResumeSpeech()
            await controller.pauseResumeSpeech()
            XCTAssertEqual(FakeSpeech.shared.events.filter { $0 == "togglePause" }.count, 2)
            await controller.playbackStop()
            FakeSpeech.shared.releaseSegments()
            await task?.value
            let events = FakeSpeech.shared.events
            await controller.pauseResumeSpeech()
            XCTAssertEqual(FakeSpeech.shared.events, events)
            XCTAssertEqual(statuses.last, "No active speech to pause or resume.")
        }
    }

    func testSpeechPause_WhileNoSpeechIsActiveDoesNotStartSelectedHistory() async {
        let selected = await controller.selectedHistoryID
        XCTAssertEqual(selected, record)
        await controller.pauseResumeSpeech()
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertEqual(statuses.last, "No active speech to pause or resume.")
    }
}
