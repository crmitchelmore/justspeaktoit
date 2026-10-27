import AVFoundation
import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

@MainActor
final class OpenRouterTTSPlaybackOperationTests: XCTestCase {
    func testPrecancelledOperationDoesNotCreateEngineOrRequest() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        var engines = 0
        let player = TTSProgressivePlayer(makeEngine: { engines += 1; return AVAudioEngine() })
        let settled = expectation(description: "Precancelled operation settles")
        var outcome: Result<TTSSynthesisOutput, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await OpenRouterTTSPlaybackOperation.synthesize(
                    text: "Hello", voice: fixture.selection.id, settings: TTSSettings(),
                    client: fixture.client, player: player
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        task.cancel()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertEqual(engines, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertFalse(player.isActive)
    }

    func testLocalSetupFailureStartsOnlyOneCompletedFileRequest() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        try respondWithMP3()
        let engine = OpenRouterUnavailableEngine()
        try configureOffline(engine)
        let player = TTSProgressivePlayer(makeEngine: { engine })
        defer { player.stop() }
        let settled = expectation(description: "Setup fallback settles")
        var outcome: Result<TTSSynthesisOutput, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await OpenRouterTTSPlaybackOperation.synthesize(
                    text: "Hello", voice: fixture.selection.id, settings: TTSSettings(),
                    client: fixture.client, player: player
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [settled], timeout: 2)
        let output = try XCTUnwrap(outcome).get()
        XCTAssertFalse(output.playbackCompleted)
        XCTAssertEqual(output.result.voice, fixture.selection.id)
        XCTAssertNil(output.result.cost)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.result.audioURL.path))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertFalse(player.isActive)
    }

    func testReplacementAfterActualSchedulingDoesNotReplayOrStopNewOwner() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        try respondWithMP3()
        let first = AVAudioEngine()
        let replacement = AVAudioEngine()
        try configureOffline(first)
        try configureOffline(replacement)
        var engines = 0
        let player = TTSProgressivePlayer(makeEngine: { engines += 1; return engines == 1 ? first : replacement })
        defer { player.stop() }
        let settled = expectation(description: "Replaced concrete operation settles")
        var outcome: Result<TTSSynthesisOutput, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await OpenRouterTTSPlaybackOperation.synthesize(
                    text: "Hello", voice: fixture.selection.id, settings: TTSSettings(),
                    client: fixture.client, player: player
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        guard await waitForScheduledPCM(player) else { return XCTFail("Actual native scheduling was not observed") }
        let newOwner = try player.prepareOwned(sampleRate: 24_000)
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertTrue(player.isActive)
        try await player.waitUntilDrained(session: newOwner)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1, "No second billable request after scheduling")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testCancellationAfterActualSchedulingDiscardsUnpublishedFile() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        try respondWithMP3()
        let engine = AVAudioEngine()
        try configureOffline(engine)
        let player = TTSProgressivePlayer(makeEngine: { engine })
        defer { player.stop() }
        let settled = expectation(description: "Cancelled concrete operation settles")
        var outcome: Result<TTSSynthesisOutput, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await OpenRouterTTSPlaybackOperation.synthesize(
                    text: "Hello", voice: fixture.selection.id, settings: TTSSettings(),
                    client: fixture.client, player: player
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        guard await waitForScheduledPCM(player) else { return XCTFail("Actual native scheduling was not observed") }
        task.cancel()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertFalse(player.isActive)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    private func respondWithMP3() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = tests.appendingPathComponent("SpeakCoreTests/Fixtures/openrouter-tone-mp3.mp3")
        let bytes = try Data(contentsOf: path)
        StubURLProtocol.respond { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "audio/mpeg"])!, bytes)
        }
    }

    private func waitForScheduledPCM(_ player: TTSProgressivePlayer) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while player.scheduledAheadSeconds == 0, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return player.scheduledAheadSeconds > 0
    }

    private func configureOffline(_ engine: AVAudioEngine) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    }

    private func assertCancelled(_ outcome: Result<TTSSynthesisOutput, Error>?) {
        guard case .failure(let error)? = outcome else { return XCTFail("Expected owned cancellation outcome") }
        XCTAssertTrue(error is CancellationError)
    }
}

private final class OpenRouterUnavailableEngine: AVAudioEngine {
    override func start() throws { throw TTSError.audioPlaybackFailure }
}
