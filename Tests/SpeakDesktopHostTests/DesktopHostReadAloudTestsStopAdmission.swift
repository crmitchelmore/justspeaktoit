import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension DesktopHostReadAloudTests {
    func testStop_WhileBusySilencesSpeechWithoutClearingWorkStateOrStatus() async throws {
        FakeSpeech.shared.reset(holdingSegments: true)
        defer { FakeSpeech.shared.releaseSegments() }
        FakeLog.shared.setKey("synthetic-key", name: deepgramKey)
        let voice = try XCTUnwrap(DeepgramSpeechCatalog.fluxVoices.first)
        await controller.saveVoiceOutput(DesktopVoiceOutputSettings(voice: voice))
        await controller.readAloud(record.uuidString, text: "Stop remains available while other work is running.")
        try await waitFor("held speech playback") { FakeSpeech.shared.events.contains("play") }
        let pendingSpeech = await controller.readAloudState.task
        let speech = try XCTUnwrap(pendingSpeech)
        let previousStatus = statuses.last
        await controller.stopAdmissionFixtureBusy(true)
        await controller.playbackStop()
        FakeSpeech.shared.releaseSegments()
        await speech.value
        let remainedBusy = await controller.busy
        let owner = await controller.voiceOutputRecordID
        let retainedStatus = statuses.last
        await controller.stopAdmissionFixtureBusy(false)
        XCTAssertTrue(remainedBusy)
        XCTAssertNil(owner)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        XCTAssertEqual(retainedStatus, previousStatus)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    fileprivate func stopAdmissionFixtureBusy(_ value: Bool) { busy = value }
}
