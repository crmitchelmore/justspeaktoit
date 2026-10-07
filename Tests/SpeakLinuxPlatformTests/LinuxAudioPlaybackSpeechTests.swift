import Foundation
import XCTest
@testable import SpeakLinuxPlatform

/// Read aloud keeps its record the active owner while segments are
/// synthesized and between them, so Pause and Stop stay available until the
/// speech ends, and nothing queued behind a Stop can play. The player and
/// window are device-free fakes.
final class LinuxAudioPlaybackSpeechTests: XCTestCase {
    private var audio = FakeLinuxAudio()
    private var playback: LinuxAudioPlayback!
    private var directory: URL!
    private var segmentPath: String!

    override func setUpWithError() throws {
        audio = FakeLinuxAudio()
        playback = audio.makePlayback()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segment = directory.appendingPathComponent("segment.wav")
        try LinuxSpeechFixture.wav().write(to: segment)
        segmentPath = segment.path
    }

    override func tearDown() async throws {
        try await playback.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testDeepgramSpeechFormat_IsPlayable() throws {
        let (samples, rate) = try LinuxAudioPlayback.readPCM16WAV(URL(fileURLWithPath: segmentPath))
        XCTAssertEqual(rate, 24_000)
        XCTAssertEqual(samples.count, 2_400)
        XCTAssertEqual(samples.first, 512)
    }

    func testSpeech_StaysActiveWhileSynthesizedAndBetweenSegments() async throws {
        let id = UUID()
        let speech = try playback.beginSpeech(recordID: id)
        XCTAssertEqual(audio.displays.last, .init(recordID: id, state: 1, text: "0:00 / --:--"),
                       "Pause and Stop must be available before the first segment")
        let (first, player) = try await segment(speech)
        XCTAssertEqual(player.sampleRate, 24_000)
        player.finish()
        let played = try await first.value
        XCTAssertEqual(played, 0.1, accuracy: 1e-9)
        XCTAssertTrue(player.destroyed)
        XCTAssertEqual(audio.displays.last?.state, 1, "between segments the record must stay active, not idle")
        let (second, next) = try await segment(speech)
        next.finish()
        _ = try await second.value
        playback.endSpeech(speech)
        XCTAssertEqual(audio.displays.last, .init(recordID: id, state: 0, text: ""))
        XCTAssertTrue(audio.statuses.isEmpty, "Read aloud reports its own outcome")
    }

    func testSpeech_ReplacesPlaybackAtTheClickWithoutReportingAStop() async throws {
        let id = UUID()
        try playback.play(recordID: id, path: segmentPath, knownDuration: nil)
        let history = try XCTUnwrap(audio.players.first)
        let speech = try playback.beginSpeech(recordID: id)
        XCTAssertTrue(history.destroyed)
        XCTAssertEqual(audio.displays.last?.state, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(audio.statuses.isEmpty)
        playback.endSpeech(speech)
    }

    /// The user's Stop ends speech while it is synthesized or playing, and
    /// refuses every segment still queued behind it.
    func testStop_EndsSpeechAndRefusesItsQueuedSegments() async throws {
        let id = UUID()
        let synthesizing = try playback.beginSpeech(recordID: id)
        playback.stop(announcing: true)
        XCTAssertEqual(audio.displays.last?.state, 0)
        await assertRefused(synthesizing)

        let playing = try playback.beginSpeech(recordID: id)
        let (segment, player) = try await segment(playing)
        playback.stop(announcing: true)
        await assertCancelled(segment)
        XCTAssertTrue(player.destroyed)
        XCTAssertEqual(audio.displays.last?.state, 0)
        await assertRefused(playing)
        XCTAssertTrue(audio.statuses.isEmpty, "Read aloud reports its own stop")
    }

    func testAnotherRowCaptureAndOtherPlayback_EndSpeech() async throws {
        let id = UUID()
        let kept = try playback.beginSpeech(recordID: id)
        playback.stop(unless: id)
        XCTAssertEqual(audio.displays.last, .init(recordID: id, state: 1, text: "0:00 / --:--"),
                       "its own row keeps the speech, presented again")
        playback.stop(unless: UUID())
        XCTAssertEqual(audio.displays.last, .init(recordID: id, state: 0, text: ""))
        await assertRefused(kept)

        let captured = try playback.beginSpeech(recordID: id)
        try await playback.stopAndWait()
        await assertRefused(captured)

        let replaced = try playback.beginSpeech(recordID: id)
        try playback.play(recordID: id, path: segmentPath, knownDuration: nil)
        await assertRefused(replaced)
        playback.stop()

        let older = try playback.beginSpeech(recordID: id)
        let newer = try playback.beginSpeech(recordID: id)
        playback.endSpeech(older)
        XCTAssertEqual(audio.displays.last?.state, 1, "an older speech ended a newer one")
        await assertRefused(older)
        playback.endSpeech(newer)
        XCTAssertEqual(audio.displays.last?.state, 0)
    }

    /// Pausing while a segment is synthesized pauses the speech: its next
    /// segment does not open the sound server until the user resumes.
    func testPausedSpeech_OpensItsNextSegmentOnlyWhenResumed() async throws {
        let id = UUID()
        let speech = try playback.beginSpeech(recordID: id)
        XCTAssertTrue(playback.togglePause(recordID: id))
        XCTAssertFalse(playback.togglePause(recordID: UUID()))
        XCTAssertEqual(audio.displays.last?.state, 2)
        let owned = try XCTUnwrap(playback)
        let path = try XCTUnwrap(segmentPath)
        let waiting = Task { try await owned.playToCompletion(speech, path: path) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(audio.players.isEmpty, "a segment of paused speech was audible before the user resumed")
        XCTAssertTrue(playback.togglePause(recordID: id))
        await linuxEventually("the resumed segment to open") { self.audio.players.count == 1 }
        let player = try XCTUnwrap(audio.players.first)
        XCTAssertTrue(player.pauses.isEmpty)
        player.finish()
        _ = try await waiting.value
        playback.endSpeech(speech)
    }

    /// Pause during a segment pauses its stream and the speech, so the
    /// record shows paused between segments and the next one waits.
    func testPauseDuringASegment_PausesTheSpeech() async throws {
        let id = UUID()
        let speech = try playback.beginSpeech(recordID: id)
        let (first, player) = try await segment(speech)
        XCTAssertTrue(playback.togglePause(recordID: id))
        XCTAssertEqual(player.pauses, [true])
        XCTAssertEqual(audio.displays.last?.state, 2)
        player.finish()
        _ = try await first.value
        XCTAssertEqual(audio.displays.last?.state, 2, "paused speech must not look like it is playing")
        playback.endSpeech(speech)
    }

    /// Cancelling the reader stops its segment; the speech itself stays until
    /// its reader ends it.
    func testCancellingTheReader_StopsItsSegment() async throws {
        let id = UUID()
        let speech = try playback.beginSpeech(recordID: id)
        let (segment, player) = try await segment(speech)
        segment.cancel()
        await assertCancelled(segment)
        XCTAssertTrue(player.destroyed)
        XCTAssertEqual(audio.displays.last?.state, 1)
        playback.endSpeech(speech)
        XCTAssertEqual(audio.displays.last?.state, 0)
    }

    func testFailedSegment_IsReportedToItsReaderOnly() async throws {
        let speech = try playback.beginSpeech(recordID: UUID())
        let (segment, player) = try await segment(speech)
        player.fail()
        do {
            _ = try await segment.value
            XCTFail("A failed segment returned success")
        } catch let error as LinuxNativeError {
            XCTAssertEqual(error.message, "The audio output failed.")
        }
        XCTAssertTrue(audio.statuses.isEmpty)
        playback.endSpeech(speech)
    }

    func testHistoryPlayback_StillReportsItsOwnEnd() async throws {
        let id = UUID()
        try playback.play(recordID: id, path: segmentPath, knownDuration: nil)
        try XCTUnwrap(audio.players.first).finish()
        await linuxEventually("the finished status") { self.audio.statuses == ["Playback finished."] }
        XCTAssertEqual(audio.displays.last, .init(recordID: id, state: 0, text: ""))
        try playback.play(recordID: id, path: segmentPath, knownDuration: nil)
        playback.stop(announcing: true)
        XCTAssertEqual(audio.statuses, ["Playback finished.", "Playback stopped."])
    }

    func testClosing_RefusesNewSpeech() async throws {
        let speech = try playback.beginSpeech(recordID: UUID())
        try await playback.close()
        XCTAssertThrowsError(try playback.beginSpeech(recordID: UUID()))
        await assertRefused(speech)
    }

    private func segment(
        _ speech: LinuxAudioPlayback.Speech
    ) async throws -> (Task<TimeInterval, Error>, FakeLinuxPlayer) {
        let count = audio.players.count
        let owned = try XCTUnwrap(playback)
        let path = try XCTUnwrap(segmentPath)
        let task = Task { try await owned.playToCompletion(speech, path: path) }
        await linuxEventually("the segment to open") { self.audio.players.count > count }
        return (task, try XCTUnwrap(audio.players.last))
    }

    private func assertRefused(
        _ speech: LinuxAudioPlayback.Speech, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let count = audio.players.count
        do {
            _ = try await playback.playToCompletion(speech, path: segmentPath)
            XCTFail("A segment of an ended speech played", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(audio.players.count, count, "a refused segment opened the sound server", file: file, line: line)
    }

    private func assertCancelled(
        _ task: Task<TimeInterval, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("An interrupted segment returned success", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
    }
}
