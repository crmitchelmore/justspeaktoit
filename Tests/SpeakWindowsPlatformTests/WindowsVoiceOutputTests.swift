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

/// File ownership: exclusive creation, only-our-own removal, a bounded budget
/// that counts files still held, and refusal of unsafe locations and names.
final class WindowsVoiceOutputStagingTests: WindowsVoiceOutputTestCase {
    func testStaging_CreatesExclusiveFilesAndRemovesOnlyItsOwn() throws {
        let staging = try WindowsVoiceOutputStaging(directory: directory)
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
        try staging.discard(first)
        try staging.discard(second)
        try staging.discard(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: saved), savedBytes)
        XCTAssertEqual(staging.ownedCount, 0)
    }

    func testStaging_RefusesUnsafeLocationsAndNamesBeforeAnyFileSystemCall() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/VoiceOutput"))
        XCTAssertThrowsError(try WindowsVoiceOutput(stagingDirectory: remote, session: session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // An embedded NUL would shorten a path to its prefix at the C boundary.
        XCTAssertNil(WindowsVoiceOutputStaging.cString(directory.path + "\u{0}escape"))
        XCTAssertNil(WindowsVoiceOutputStaging.cString(""))
        XCTAssertEqual(WindowsVoiceOutputStaging.cString(directory.path), directory.path)
        // However this Foundation represents such a URL, the prefix is never prepared.
        let probe = StagingFileSystemProbe()
        let embedded = URL(fileURLWithPath: directory.path + "\u{0}escape")
        if let staging = try? WindowsVoiceOutputStaging(directory: embedded, fileSystem: probe.fileSystem) {
            try staging.discard(try staging.store(Data([1])))
        }
        XCTAssertFalse(probe.preparedPaths.contains(directory.path), "A truncated prefix was prepared")
        XCTAssertFalse(probe.preparedPaths.contains { $0.utf8.contains(0) })

        let refusedNames = StagingFileSystemProbe()
        for name in ["", ".", "..", "a/b", "a\\b", "audio.wav:stream", "a\u{0}b"] {
            let staging = try WindowsVoiceOutputStaging(
                directory: directory, makeName: { name }, fileSystem: refusedNames.fileSystem
            )
            XCTAssertThrowsError(try staging.store(Data([1])), "\(name.debugDescription) was accepted")
            XCTAssertEqual(staging.ownedCount, 0)
        }
        XCTAssertEqual(refusedNames.creations, 0)
        XCTAssertTrue(refusedNames.preparedPaths.isEmpty)
    }

    /// A removal held in progress keeps its files counted: a concurrent store
    /// cannot admit a file beyond the budget while Windows still holds the rest.
    func testHeldRemoval_KeepsPendingFilesCountedAgainstTheBudget() async throws {
        let probe = StagingFileSystemProbe()
        let staging = try WindowsVoiceOutputStaging(directory: directory, fileSystem: probe.fileSystem)
        probe.pin(true)
        for _ in 0..<WindowsVoiceOutputStaging.maximumOwnedFiles {
            let file = try staging.store(Data([1]))
            XCTAssertThrowsError(try staging.discard(file), "A still-held file was reported removed")
        }
        XCTAssertEqual(staging.retainedCount, WindowsVoiceOutputStaging.maximumOwnedFiles)

        let held = PlaybackTestGate()
        probe.holdNextRemoval(held)
        let shutdown = Task.detached { try staging.removeRetained() }
        await playbackEventually { held.entered }
        XCTAssertEqual(staging.retainedCount, WindowsVoiceOutputStaging.maximumOwnedFiles)
        XCTAssertThrowsError(try staging.store(Data([1])), "A file beyond the budget was admitted")
        XCTAssertEqual(probe.creations, WindowsVoiceOutputStaging.maximumOwnedFiles)
        XCTAssertEqual(probe.preparedPaths.count, WindowsVoiceOutputStaging.maximumOwnedFiles, "Refusal touched disk")
        held.open()
        do {
            try await shutdown.value
            XCTFail("Held files were reported removed")
        } catch {}
        XCTAssertEqual(staging.retainedCount, WindowsVoiceOutputStaging.maximumOwnedFiles)

        // Once Windows lets go, every owned file is removed and speech is admitted again.
        probe.pin(false)
        try staging.removeRetained()
        XCTAssertEqual(staging.ownedCount, 0)
        XCTAssertEqual(probe.existing, 0)
        try staging.discard(try staging.store(Data([1])))
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
        let staging = try WindowsVoiceOutputStaging(directory: directory, makeName: { "collision.wav" })
        let output = WindowsVoiceOutput(staging: staging, session: session, backend: backend)
        do {
            _ = try await output.speak(try request("Hello")) { "fixture-key" }
            XCTFail("A colliding output path was reused")
        } catch { XCTAssertFalse(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertTrue(backend.opened.isEmpty)
        XCTAssertEqual(output.retainedFileCount, 0)
        XCTAssertEqual(staging.ownedCount, 0)
    }
}

/// The engine end to end: ordering against the player, release before removal,
/// failed and held releases, whitespace and refused audio.
final class WindowsVoiceOutputTests: WindowsVoiceOutputTestCase {
    func testFailedNativeRelease_KeepsThePinnedInputOwnedUntilWindowsReleasesIt() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        let backend = PinnedInputBackend(failures: 1)
        let output = try WindowsVoiceOutput(stagingDirectory: directory, session: session, backend: backend)
        do {
            _ = try await output.speak(try request("Hello")) { "fixture-key" }
            XCTFail("A failed native release reported speech")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("Injected release failure"), "\(error)")
        }
        let handle = try XCTUnwrap(backend.handles.first)
        XCTAssertFalse(handle.isPinReleased)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.path), "A pinned input was reported removed")
        XCTAssertEqual(output.retainedFileCount, 1)
        XCTAssertThrowsError(try output.removeRetainedFiles())
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.path))

        // The playback registry retries a failed release when it admits the next job.
        let next = PlaybackTestBackend()
        next.enqueue(PlaybackTestPlan(completeOnStart: .init(status: .finished, played: 0)))
        _ = try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: next)
        await playbackEventually { handle.isPinReleased }
        try output.removeRetainedFiles()
        XCTAssertEqual(output.retainedFileCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.path))
    }

    func testRemovalFailureAfterSpeech_IsReportedAndTheFileStaysOwned() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        let backend = PinnedInputBackend(failures: 0, keepPinAfterRelease: true)
        let output = try WindowsVoiceOutput(stagingDirectory: directory, session: session, backend: backend)
        let outcome = try await output.speak(try request("Hello")) { "fixture-key" }
        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertFalse(receipt.audioFileRemoved, "A file another holder keeps open was reported removed")
        let handle = try XCTUnwrap(backend.handles.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.path))
        XCTAssertEqual(output.retainedFileCount, 1)

        try await Task.detached { try handle.releasePin() }.value
        try output.removeRetainedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.path))
    }

    func testEngine_PlaysTheCanonicalFileAndRemovesItOnlyAfterRelease() async throws {
        respond(with: Self.streamedWAV(frames: 2_400))
        let backend = VoiceOutputRecordingBackend()
        backend.engine.enqueue(PlaybackTestPlan(completeOnStart: .init(status: .finished, played: 0.1)))
        let outcome = try await engine(backend).speak(try request("Hello from Windows")) { "fixture-key" }

        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertEqual(receipt.playedDuration, 0.1)
        XCTAssertEqual(receipt.audioDuration, 0.1, accuracy: 1e-12)
        XCTAssertTrue(receipt.audioFileRemoved)
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
        let output = try engine(backend)
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

    /// Real synthesis transport, private staging and the native Media Foundation
    /// decoder. Without an endpoint the decoder must accept the file and fail
    /// only at the missing device; the audible part is then skipped, not passed.
    func testEndToEnd_NativeDecoderAcceptsSynthesizedSpeechAndCleansUp() async throws {
        // A probe failure is a test failure; only a definite "no endpoint" skips.
        let endpoint = try WindowsAudioPlayback.isOutputEndpointAvailable()
        respond(with: Self.streamedWAV(frames: 2_400))
        let output = try WindowsVoiceOutput(stagingDirectory: directory, session: session)
        do {
            let outcome = try await output.speak(try request("Hello from Windows")) { "fixture-key" }
            XCTAssertTrue(endpoint, "Playback reported speech without an output endpoint")
            guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
            XCTAssertEqual(receipt.playedDuration, 0.1, accuracy: 0.02)
            XCTAssertTrue(receipt.audioFileRemoved)
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

    private func engine(_ backend: VoiceOutputRecordingBackend) throws -> WindowsVoiceOutput {
        try WindowsVoiceOutput(stagingDirectory: directory, session: session, backend: backend)
    }
}
#endif
