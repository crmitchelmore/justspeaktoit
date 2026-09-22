#if os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CWindowsSupport
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakWindowsPlatform

/// Records the exact bytes the player was given when it opened the file,
/// before any release, while the shared device-free engine plays them.
final class VoiceOutputRecordingBackend: WindowsAudioPlaybackBackend, @unchecked Sendable {
    struct Opened {
        let path: String
        let bytes: Data?
    }

    let engine = PlaybackTestBackend()
    private let lock = NSLock()
    private var values: [Opened] = []

    var opened: [Opened] { lock.withLock { values } }

    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: path))
        lock.withLock { values.append(Opened(path: path, bytes: bytes)) }
        return try engine.open(path: path, completion: completion)
    }
}

/// Synthesis runs through the real shared transport against a local stub; no
/// vendor key or network is used. The fake engine proves ordering and file
/// ownership only; audible output is claimed solely by the endpoint test.
final class WindowsVoiceOutputTests: XCTestCase {
    private var session: URLSession!
    private var parent: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = StubURLProtocol.makeSession()
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: parent)
        try super.tearDownWithError()
    }

    private var directory: URL { parent.appendingPathComponent("VoiceOutput") }

    func testStaging_CreatesExclusiveFilesAndRemovesOnlyItsOwn() throws {
        let staging = WindowsVoiceOutputStaging(directory: directory)
        let wav = Self.canonicalWAV(frames: 240)
        let first = try staging.store(wav)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "VoiceOutput")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("voice-output-"))
        XCTAssertEqual(try Data(contentsOf: first), wav)

        // A saved recording that happens to share the directory is never touched.
        let saved = directory.appendingPathComponent("saved-recording.wav")
        let savedBytes = Data("A saved recording must survive".utf8)
        try savedBytes.write(to: saved)
        let second = try staging.store(wav)
        XCTAssertNotEqual(first, second)
        staging.discard(first)
        staging.discard(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: saved), savedBytes)
        XCTAssertEqual(staging.retainedCount, 0)
    }

    func testStaging_RetainsAFileWindowsStillPinsAndRemovesItAfterRelease() async throws {
        let staging = WindowsVoiceOutputStaging(directory: directory)
        let file = try staging.store(Self.canonicalWAV(frames: 240))
        // The real native player pins its input with delete sharing denied,
        // without touching any device until it is started.
        let pin = try WindowsAudioPlaybackNativeBackend().open(path: file.path) { _ in }
        staging.discard(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(staging.retainedCount, 1)
        XCTAssertThrowsError(try staging.removeRetained())

        try await Task.detached { try pin.destroy() }.value
        try staging.removeRetained()
        XCTAssertEqual(staging.retainedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testEngine_PlaysTheCanonicalFileAndRemovesItOnlyAfterRelease() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        let backend = VoiceOutputRecordingBackend()
        backend.engine.enqueue(PlaybackTestPlan(completeOnStart: .init(status: .finished, played: 0.1)))
        let outcome = try await engine(backend).speak(try request("Hello from Windows")) { "fixture-key" }

        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertEqual(receipt.playedDuration, 0.1)
        XCTAssertEqual(receipt.audioDuration, 0.1, accuracy: 1e-12)
        let opened = try XCTUnwrap(backend.opened.first)
        XCTAssertEqual(backend.opened.count, 1)
        XCTAssertEqual(opened.bytes, Self.canonicalWAV(frames: 2_400), "The player must receive exact lengths")
        XCTAssertTrue(opened.path.contains("VoiceOutput"))
        XCTAssertEqual(backend.engine.handles.first?.counts.destroyed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testEngine_CancellationDuringPlaybackKeepsTheFileUntilNativeRelease() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        let backend = VoiceOutputRecordingBackend(), destroy = PlaybackTestGate()
        backend.engine.enqueue(PlaybackTestPlan(destroyGate: destroy))
        let output = engine(backend)
        let speech = try request("Hello")
        let task = Task { try await output.speak(speech) { "fixture-key" } }
        await playbackEventually { backend.engine.handles.first?.counts.started == 1 }
        let handle = try XCTUnwrap(backend.engine.handles.first)
        let path = try XCTUnwrap(backend.opened.first?.path)

        task.cancel()
        await playbackEventually { handle.counts.cancelled == 1 }
        handle.complete(.init(status: .cancelled, played: 0.02))
        await playbackEventually { destroy.entered }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "The file was removed before native release")
        destroy.open()
        do {
            let outcome = try await task.value
            XCTFail("Cancellation reported \(outcome)")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(handle.counts.destroyed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testEngine_WhitespaceUsesNoCredentialRequestFileOrPlayer() async throws {
        let backend = VoiceOutputRecordingBackend()
        let outcome = try await engine(backend).speak(try request(" \r\n\t ")) {
            XCTFail("The credential was read for whitespace")
            return "fixture-key"
        }
        XCTAssertEqual(outcome, .nothingToSpeak)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(backend.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEngine_MP3FixtureResponseIsRefusedBeforeAnyFileOrPlayer() async throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "tone-mp3", withExtension: "mp3", subdirectory: "Fixtures")
        )
        respond(with: try Data(contentsOf: fixture), contentType: "audio/mpeg")
        let backend = VoiceOutputRecordingBackend()
        do {
            _ = try await engine(backend).speak(try request("Hello")) { "fixture-key" }
            XCTFail("MP3 bytes were accepted as the requested WAV")
        } catch { XCTAssertEqual(error as? DeepgramSpeechError, .unsupportedAudioFormat) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(backend.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEngine_OutputCollisionNeverTruncatesOrRemovesTheExistingFile() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        var error = [CChar](repeating: 0, count: 1_024)
        let prepared = directory.path.withCString { jsti_private_directory_prepare($0, &error, error.count) }
        XCTAssertEqual(prepared, 0, String(cString: error))
        let existing = directory.appendingPathComponent("collision.wav")
        let sentinel = Data("Existing output must survive".utf8)
        try sentinel.write(to: existing)

        let backend = VoiceOutputRecordingBackend()
        let staging = WindowsVoiceOutputStaging(directory: directory) { "collision.wav" }
        let output = WindowsVoiceOutput(staging: staging, session: session, backend: backend)
        do {
            _ = try await output.speak(try request("Hello")) { "fixture-key" }
            XCTFail("A colliding output path was reused")
        } catch { XCTAssertFalse(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertTrue(backend.opened.isEmpty)
        XCTAssertEqual(output.retainedFileCount, 0)
    }

    /// Real synthesis transport, private staging and the native Media Foundation
    /// decoder. Without an endpoint the decoder must accept the file and fail
    /// only at the missing device; the audible part is then skipped, not passed.
    func testEndToEnd_NativeDecoderAcceptsSynthesizedSpeechAndCleansUp() async throws {
        // A probe failure is a test failure; only a definite "no endpoint" skips.
        let endpoint = try WindowsAudioPlayback.isOutputEndpointAvailable()
        respond(with: Self.streamedWAV(frames: 2_400))
        let output = WindowsVoiceOutput(stagingDirectory: directory, session: session)
        do {
            let outcome = try await output.speak(try request("Hello from Windows")) { "fixture-key" }
            XCTAssertTrue(endpoint, "Playback reported speech without an output endpoint")
            guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
            XCTAssertEqual(receipt.playedDuration, 0.1, accuracy: 0.02)
        } catch let error as WindowsAudioPlaybackError where !endpoint {
            XCTAssertTrue(error.message.contains("No active audio output device"), error.message)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(output.retainedFileCount, 0)
        if !endpoint {
            throw XCTSkip("No active Windows audio output endpoint: synthesis, staging, decode and cleanup were "
                + "verified; audible playback was not exercised.")
        }
    }

    // MARK: - Helpers

    private func engine(_ backend: VoiceOutputRecordingBackend) -> WindowsVoiceOutput {
        WindowsVoiceOutput(stagingDirectory: directory, session: session, backend: backend)
    }

    private func request(_ text: String) throws -> DeepgramSpeechRequest {
        try DeepgramSpeechRequest(text: text, modelID: "aura-2", voiceID: "deepgram/aura-2-thalia-en")
    }

    private func respond(with body: Data, contentType: String = "audio/wav") {
        StubURLProtocol.handler = { request in
            .respond(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType]
                )!,
                body
            )
        }
    }

    /// A quiet 200 Hz square wave, like the other playback tests.
    private static func pcm(frames: Int) -> Data {
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = UInt16(bitPattern: (frame / 60).isMultiple(of: 2) ? 512 : -512)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return pcm
    }

    private static func canonicalWAV(frames: Int) -> Data {
        PCMWaveWriter.wavData(pcm: pcm(frames: frames), sampleRate: 24_000)!
    }

    /// Deepgram streams its header before synthesis ends, so both lengths are
    /// placeholders here.
    private static func streamedWAV(frames: Int) -> Data {
        var wav = canonicalWAV(frames: frames)
        wav.replaceSubrange(4..<8, with: Data(repeating: 0xFF, count: 4))
        wav.replaceSubrange(40..<44, with: Data(repeating: 0xFF, count: 4))
        return wav
    }
}
#endif
