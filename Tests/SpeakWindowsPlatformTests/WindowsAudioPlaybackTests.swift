#if os(Windows)
import Foundation
import SpeakCore
import CWindowsSupport
import XCTest
@testable import SpeakWindowsPlatform

/// Native playback checks. The synthetic self-test and the input/codec
/// refusals run on every runner; the hardware checks probe the endpoint
/// explicitly and skip only the audible part, never reporting a pass.
final class WindowsAudioPlaybackTests: XCTestCase {
    func testNativePlaybackSelfTest_PassesWithoutAnEndpoint() {
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_audio_playback_self_test(&error, error.count), 0, String(cString: error))
    }

    func testNonFileMissingAndDirectoryInputs_FailWithoutCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/audio.wav"))
        for input in [remote, directory.appendingPathComponent("missing.wav"), directory] {
            do {
                _ = try await WindowsAudioPlayback.play(input: input)
                XCTFail("Expected \(input) to be refused")
            } catch {
                XCTAssertFalse(error is CancellationError, "\(input): \(error)")
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    /// The decoder opens before any endpoint, so junk bytes fail the same way
    /// with or without a speaker and are never mistaken for a missing device.
    func testCorruptInput_FailsWithACodecErrorRegardlessOfEndpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("corrupt.wav")
        let source = Data("Not a WAV recording".utf8)
        try source.write(to: input)
        do {
            _ = try await WindowsAudioPlayback.play(input: input)
            XCTFail("Expected corrupt audio to fail")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(error)")
            XCTAssertFalse(error.localizedDescription.contains("No active audio output device"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: input), source)
        try FileManager.default.removeItem(at: input) // The pin is released after failure.
    }

    func testCancelledBeforeStart_ThrowsCancellationAndLeavesSourceUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("short.wav")
        let source = try tone(seconds: 0.1)
        try source.write(to: input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WindowsAudioPlayback.play(input: input)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: input), source)
        try FileManager.default.removeItem(at: input)
    }

    func testEndpointPlayback_PlaysSyntheticToneWithAccurateDuration() async throws {
        try skipWithoutEndpoint()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("tone.wav")
        let source = try tone(seconds: 0.1)
        try source.write(to: input)
        let output = try await WindowsAudioPlayback.play(input: input)
        XCTAssertEqual(output.playedDuration, 0.1, accuracy: 0.02)
        XCTAssertEqual(try Data(contentsOf: input), source)
        // Returning must have joined both native threads and released the pin.
        try FileManager.default.removeItem(at: input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    func testEndpointPlayback_PauseFreezesPositionAndResumeFinishes() async throws {
        try skipWithoutEndpoint()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("pause.wav")
        try tone(seconds: 2).write(to: input)
        let done = expectation(description: "Native completion arrives once")
        done.assertForOverFulfill = true
        let result = PlaybackResult()
        let handle = try WindowsAudioPlaybackNativeBackend().open(path: input.path) { completion in
            result.store(completion)
            done.fulfill()
        }
        try handle.start()
        await settle({ handle.snapshot().state == .playing }, "Playback never started")
        try await Task.sleep(for: .milliseconds(300))
        handle.pause()
        await settle({ handle.snapshot().state == .paused }, "Pause was not acknowledged")
        let paused = handle.snapshot()
        XCTAssertGreaterThan(paused.position, 0)
        XCTAssertEqual(paused.duration ?? -1, 2, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(handle.snapshot().position, paused.position, "The position moved while paused")
        handle.resume()
        await fulfillment(of: [done], timeout: 15)
        XCTAssertEqual(result.value?.status, .finished)
        XCTAssertEqual(result.value?.played ?? -1, 2, accuracy: 0.05)
        XCTAssertEqual(handle.snapshot().state, .ended)
        try await Task.detached { try handle.destroy() }.value
        try FileManager.default.removeItem(at: input)
    }

    func testEndpointPlayback_CancellationDuringPlaybackCompletesPromptly() async throws {
        try skipWithoutEndpoint()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("long.wav")
        let source = try tone(seconds: 3)
        try source.write(to: input)
        let task = Task { try await WindowsAudioPlayback.play(input: input) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        task.cancel()
        do {
            // Completion may win the race only for a file this long if the
            // engine finished first, which the assertion below still bounds.
            let output = try await task.value
            XCTAssertEqual(output.playedDuration, 3, accuracy: 0.05)
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(try Data(contentsOf: input), source)
        try FileManager.default.removeItem(at: input)
    }

    private func skipWithoutEndpoint() throws {
        // A probe failure is a test failure: only a definite "no endpoint"
        // answer skips, and it skips only the audible checks.
        guard try WindowsAudioPlayback.isOutputEndpointAvailable() else {
            throw XCTSkip("No active Windows audio output endpoint; audible playback checks are skipped, not passed.")
        }
    }

    /// Polls a condition with a firm deadline and records a failure at the
    /// call site when it never holds.
    private func settle(
        _ condition: @escaping () -> Bool, _ message: String, timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { XCTFail(message, file: file, line: line) }
    }

    /// A quiet 200 Hz square wave: deterministic, audible in a test, never loud.
    private func tone(seconds: Double, rate: Int = 24_000) throws -> Data {
        let frames = Int(seconds * Double(rate))
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value: Int16 = (frame / (rate / 400)) % 2 == 0 ? 512 : -512
            pcm.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value)))
            pcm.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8))
        }
        return try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class PlaybackResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WindowsAudioPlaybackCompletion?
    var value: WindowsAudioPlaybackCompletion? { lock.withLock { stored } }
    func store(_ completion: WindowsAudioPlaybackCompletion) { lock.withLock { stored = completion } }
}
#endif
