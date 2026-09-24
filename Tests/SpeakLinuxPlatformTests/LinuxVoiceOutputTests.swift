import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakTestSupport
@testable import SpeakLinuxPlatform

/// The Linux voice output engine: private staging on disk, and one request
/// from a stubbed Deepgram response through the shared playback's speech
/// mode to a device-free player. No network or audio device is used.
final class LinuxVoiceOutputTests: XCTestCase {
    private var directory: URL!
    private var staging: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        staging = directory.appendingPathComponent("VoiceOutput")
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testStagedSpeech_IsPrivateAndRemovedOnlyByItsOwner() throws {
        let store = try LinuxVoiceOutputStaging(directory: staging)
        let wav = LinuxSpeechFixture.wav()
        let file = try store.store(wav)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path, staging.standardizedFileURL.path)
        XCTAssertEqual(try permissions(staging), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), wav)
        XCTAssertEqual(store.ownedCount, 1)

        let foreign = staging.appendingPathComponent("notes.wav")
        try Data("keep".utf8).write(to: foreign)
        try store.discard(foreign)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "a file it did not create was removed")

        try store.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.ownedCount, 0)
    }

    func testAnExistingFolder_IsTightenedAndEarlierLeftoversRemoved() throws {
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        let leftover = staging.appendingPathComponent("voice-output-\(UUID().uuidString).wav")
        let other = staging.appendingPathComponent("unrelated.txt")
        try Data("old".utf8).write(to: leftover)
        try Data("other".utf8).write(to: other)
        let output = try LinuxVoiceOutput(stagingDirectory: staging, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(output.stagedFileCount, 0)
        _ = try LinuxVoiceOutputStaging(directory: staging).store(LinuxSpeechFixture.wav())
        XCTAssertEqual(try permissions(staging), 0o700)
    }

    func testMissingKey_StopsBeforeTheNetworkOrDisk() async throws {
        let output = try LinuxVoiceOutput(stagingDirectory: staging, session: session)
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        do {
            _ = try await output.speak(request, credential: { "" }, through: { _ in
                XCTFail("Nothing should play without a key")
                return 0
            })
            XCTFail("Speech without a key succeeded")
        } catch DeepgramSpeechError.missingCredential {}
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// One request from Deepgram's streamed WAV to the end of playback: the
    /// staged file is private while it plays and gone afterwards.
    func testSpokenSegment_PlaysThroughTheSharedPlaybackAndIsRemoved() async throws {
        let body = LinuxSpeechFixture.streamedWAV()
        StubURLProtocol.handler = { request in
            .respond(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"]
                )!,
                body
            )
        }
        let audio = FakeLinuxAudio()
        let playback = audio.makePlayback()
        let output = try LinuxVoiceOutput(stagingDirectory: staging, session: session)
        let speech = try playback.beginSpeech(recordID: UUID())
        let staged = StagedFile()
        let request = try DeepgramSpeechRequest(text: "Hello from Linux.", modelID: "flux", voiceID: "flux-kit-en")
        let speaking = Task {
            try await output.speak(request, credential: { "fixture-key" }, through: { file in
                staged.record(file)
                return try await playback.playToCompletion(speech, path: file.path)
            })
        }
        await linuxEventually("the segment to open") { audio.players.count == 1 }
        let file = try XCTUnwrap(staged.url)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(staging), 0o700)
        try XCTUnwrap(audio.players.first).finish()
        let outcome = try await speaking.value
        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertEqual(receipt.voice.id, "flux-kit-en")
        XCTAssertEqual(receipt.playedDuration, 0.1, accuracy: 1e-9)
        XCTAssertTrue(receipt.audioFileRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(output.stagedFileCount, 0)
        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token fixture-key")
        playback.endSpeech(speech)
        try await playback.close()
    }
}

private final class StagedFile: @unchecked Sendable {
    private let lock = NSLock()
    private var file: URL?
    var url: URL? { lock.withLock { file } }
    func record(_ url: URL) { lock.withLock { file = url } }
}
