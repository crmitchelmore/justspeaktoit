import CLinuxSupport
import Foundation
import XCTest
@testable import SpeakLinuxPlatform

/// What "System resources in use" (#1473) reads from the Linux platform.
final class LinuxSystemResourceProbeTests: XCTestCase {
    /// A stalled sound server ends at the deadline, and a list the server
    /// fails is unknown rather than "microphone closed".
    func testCaptureQuery_HasADeadlineAndTreatsAServerErrorAsUnknown() {
        XCTAssertEqual(jsti_audio_capture_query_self_test(), 0)
    }

    /// History playback is listed while it plays or is paused; Read aloud
    /// segments are speech, not saved audio.
    func testIsPlayingSavedAudio_FollowsHistoryPlaybackOnly() async throws {
        let audio = FakeLinuxAudio()
        let playback = audio.makePlayback()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString).wav")
        try LinuxSpeechFixture.wav().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        XCTAssertFalse(playback.isPlayingSavedAudio)
        try playback.play(recordID: id, path: file.path, knownDuration: nil)
        XCTAssertTrue(playback.isPlayingSavedAudio)
        XCTAssertTrue(playback.togglePause(recordID: id))
        XCTAssertTrue(playback.isPlayingSavedAudio, "Paused playback still holds the output")
        try XCTUnwrap(audio.players.first).finish()
        await linuxEventually("the finished run to end") { !playback.isPlayingSavedAudio }

        let speech = try playback.beginSpeech(recordID: id)
        XCTAssertFalse(playback.isPlayingSavedAudio)
        playback.endSpeech(speech)
        try await playback.close()
    }
}
