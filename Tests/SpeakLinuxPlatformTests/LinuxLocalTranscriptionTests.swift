import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakLinuxPlatform

final class LinuxLocalTranscriptionTests: XCTestCase {
    func testGLibSHA256MatchesKnownVectors() throws {
        let provider = LinuxSHA256Hasher.provider
        XCTAssertEqual(try provider.sha256(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try provider.sha256(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            try provider.sha256(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // FIPS 180-2 long message: one million "a", streamed in uneven pieces.
        let hasher = try LinuxSHA256Hasher()
        let piece = Data(repeating: UInt8(ascii: "a"), count: 999)
        var remaining = 1_000_000
        while remaining > 0 {
            let count = min(remaining, piece.count)
            try piece.prefix(count).withUnsafeBytes { try hasher.update($0) }
            remaining -= count
        }
        XCTAssertEqual(try hasher.finish(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        XCTAssertThrowsError(try hasher.finish(), "A finished digest is single-use")
        XCTAssertThrowsError(try Data("x".utf8).withUnsafeBytes { try hasher.update($0) })
    }

    func testStreamedFileDigestMatchesTheWholeBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chunks.bin")
        let body = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try body.write(to: file)
        let provider = LinuxSHA256Hasher.provider
        XCTAssertEqual(try provider.sha256(ofFileAt: file, chunkSize: 1 << 20), try provider.sha256(of: body))
    }

    func testMissingOrUntrustedRuntimeIsRefusedWithoutCrashing() throws {
        let manager = FileManager.default
        let empty = manager.temporaryDirectory.appendingPathComponent("no-runtime-\(UUID().uuidString)")
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: empty) }
        XCTAssertThrowsError(try LinuxWhisperRuntime.open(directory: empty, allowGPU: false)) { error in
            XCTAssertTrue((error as? LinuxLocalTranscriptionError)?.message.contains("incomplete") == true, "\(error)")
        }
        XCTAssertThrowsError(try LinuxWhisperRuntime.open(
            directory: empty.appendingPathComponent("absent"), allowGPU: false
        )) { error in
            let message = (error as? LinuxLocalTranscriptionError)?.message ?? ""
            XCTAssertTrue(message.contains("not installed"), "\(error)")
        }
        // A library replaced by a link is not loaded, whatever it points at.
        for name in ["libggml-base.so.0", "libggml.so.0", "libwhisper.so.1"] {
            try manager.createSymbolicLink(
                at: empty.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
        }
        XCTAssertThrowsError(try LinuxWhisperRuntime.open(directory: empty, allowGPU: false)) { error in
            XCTAssertTrue((error as? LinuxLocalTranscriptionError)?.message.contains("incomplete") == true, "\(error)")
        }
    }

    /// The real runtime with the pinned tiny catalogue model. CI sets
    /// `JSTI_WHISPER_RUNTIME_DIRECTORY` to the whisper.cpp build,
    /// `JSTI_WHISPER_TEST_AUDIO` to the upstream JFK sample and
    /// `JSTI_LOCAL_MODEL_DIRECTORY` to a cached model folder.
    func testPinnedTinyModelTranscribesSpeechAndKeepsSilenceEmpty() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.runtime.description.hasPrefix("whisper.cpp 1.9.4"), fixture.runtime.description)
        XCTAssertTrue(fixture.runtime.description.contains("CPU"), fixture.runtime.description)
        let recognizer = LinuxWhisperRecognizer(runtime: fixture.runtime)
        let speech = try await DesktopLocalTranscription.transcribe(
            audioURL: fixture.audio, model: fixture.spec, modelFile: fixture.installed, language: "en",
            recognizer: recognizer
        )
        let words = speech.text.lowercased().filter { $0.isLetter || $0 == " " }
        XCTAssertTrue(words.contains("ask not what your country can do for you"), speech.text)
        XCTAssertEqual(speech.modelIdentifier, "local/whisperkit/tiny")
        XCTAssertEqual(speech.duration, 11, accuracy: 0.1)

        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: silent) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(count: 32_000), sampleRate: 16_000)).write(to: silent)
        let silence = try await DesktopLocalTranscription.transcribe(
            audioURL: silent, model: fixture.spec, modelFile: fixture.installed, language: nil, recognizer: recognizer
        )
        XCTAssertEqual(silence.text, "")

        let samples = [Float](repeating: 0.05, count: 32_000)
        let cancelled = Task {
            try await fixture.runtime.transcribe(samples: samples, modelFile: fixture.installed, language: nil)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled transcription completed")
        } catch is CancellationError {}
    }

    /// Cancelling while whisper.cpp runs aborts it through its abort callback.
    func testCancellingDuringRecognitionAbortsIt() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.recognise(fixture.installed)
        let long = Array(repeating: fixture.samples, count: 6).flatMap { $0 }
        let started = Date()
        let running = Task {
            try await fixture.runtime.transcribe(samples: long, modelFile: fixture.installed, language: "en")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("A transcription cancelled while running completed")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "Cancellation did not abort recognition promptly")
    }

    /// The runtime closes a model's file once it is loaded and keys its cache
    /// by path. So a removal can delete the loaded model's folder first and the
    /// model still recognises from memory; freeing another path keeps it, and
    /// freeing its own path releases it.
    func testLoadedModelSurvivesDeletingItsFileUntilItsOwnPathIsReleased() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        let model = try fixture.copy("loaded")
        try await fixture.recognise(model)
        try FileManager.default.removeItem(at: model.deletingLastPathComponent())
        let afterDeletion = try await fixture.recognisesWithoutItsFile(model)
        XCTAssertTrue(afterDeletion, "The loaded model needed its deleted file")

        let other = fixture.scratch.appendingPathComponent("other").appendingPathComponent(model.lastPathComponent)
        XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: other))
        let afterOtherRelease = try await fixture.recognisesWithoutItsFile(model)
        XCTAssertTrue(afterOtherRelease, "Freeing another path released the loaded model")

        XCTAssertTrue(fixture.runtime.releaseModel(loadedFrom: model))
        XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: model), "Nothing is cached any more")
        let afterOwnRelease = try await fixture.recognisesWithoutItsFile(model)
        XCTAssertFalse(afterOwnRelease, "The released model was still cached")
    }

    /// A's removal is admitted while A is loaded, and its teardown waits while
    /// B is recognised, replacing A in the cache. An unconditional release then
    /// frees B; releasing A by path, checked under the lock recognition loads
    /// under, frees nothing and B stays warm.
    func testHeldRemovalFreesOnlyTheModelItRemoves() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        let unconditional = try await replacementSurvivesHeldRemoval(fixture) { runtime, _ in runtime.releaseModel() }
        XCTAssertFalse(unconditional, "Expected the race: an unconditional release frees the replacement")
        let byPath = try await replacementSurvivesHeldRemoval(fixture) { runtime, removed in
            _ = runtime.releaseModel(loadedFrom: removed)
        }
        XCTAssertTrue(byPath, "Removing one model freed the model that replaced it")
    }

    private func replacementSurvivesHeldRemoval(
        _ fixture: LocalRuntimeFixture, release: @escaping @Sendable (LinuxWhisperRuntime, URL) -> Void
    ) async throws -> Bool {
        let removed = try fixture.copy("removed-\(UUID().uuidString)")
        let replacement = try fixture.copy("replacement-\(UUID().uuidString)")
        try await fixture.recognise(removed)
        let teardown = LocalModelTeardown()
        let held = expectation(description: "The teardown is held")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let holding = Task {
            await teardown.remove({ held.fulfill(); _ = gate.wait(timeout: .now() + 60) }, release: {})
        }
        await fulfillment(of: [held], timeout: 10)
        let runtime = fixture.runtime
        let removal = Task {
            await teardown.remove(
                { try FileManager.default.removeItem(at: removed.deletingLastPathComponent()) },
                release: { release(runtime, removed) }
            )
        }
        try await fixture.recognise(replacement)
        gate.signal()
        _ = await holding.value
        let failure = await removal.value
        XCTAssertNil(failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        return try await fixture.recognisesWithoutItsFile(replacement)
    }
}

/// The real runtime with copies of the pinned tiny model. Each copy's path is
/// its identity in the runtime's one-model cache, so copies act as models.
private struct LocalRuntimeFixture {
    let runtime: LinuxWhisperRuntime
    let spec: WhisperCppModel
    let installed: URL
    let audio: URL
    let samples: [Float]
    let scratch: URL

    /// CI sets the variables the transcription test above documents.
    static func make() async throws -> LocalRuntimeFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let runtimeDirectory = environment["JSTI_WHISPER_RUNTIME_DIRECTORY"],
              let audio = environment["JSTI_WHISPER_TEST_AUDIO"],
              let models = environment["JSTI_LOCAL_MODEL_DIRECTORY"] else {
            throw XCTSkip("Requires the whisper.cpp runtime build, its JFK sample and a model folder.")
        }
        let spec = try XCTUnwrap(DesktopLocalTranscription.model(for: "local/whisperkit/tiny", host: .linux))
        let installer = LocalModelInstaller(
            root: URL(fileURLWithPath: models, isDirectory: true), digests: LinuxSHA256Hasher.provider,
            transport: LocalModelURLSessionTransport()
        )
        let installed = try await installer.install(.init(spec))
        try installer.verify(.init(spec))
        let runtime = try LinuxWhisperRuntime.open(
            directory: URL(fileURLWithPath: runtimeDirectory, isDirectory: true), allowGPU: false
        )
        let audioURL = URL(fileURLWithPath: audio)
        let samples = try DesktopLocalAudio.read(audioURL, maximumBytes: DesktopLocalTranscription.maximumAudioBytes)
            .samples
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsti-model-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return LocalRuntimeFixture(
            runtime: runtime, spec: spec, installed: installed, audio: audioURL, samples: samples, scratch: scratch
        )
    }

    func copy(_ name: String) throws -> URL {
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(installed.lastPathComponent)
        try FileManager.default.copyItem(at: installed, to: file)
        return file
    }

    /// Loads `model` unless the runtime already holds it, then recognises.
    func recognise(_ model: URL) async throws {
        _ = try await runtime.transcribe(samples: samples, modelFile: model, language: "en")
    }

    /// Deletes the model's file if it is still there, then reports whether the
    /// model still recognises, which only a cached model can then do.
    func recognisesWithoutItsFile(_ model: URL) async throws -> Bool {
        if FileManager.default.fileExists(atPath: model.path) { try FileManager.default.removeItem(at: model) }
        do {
            try await recognise(model)
            return true
        } catch let error as LinuxLocalTranscriptionError where error.message.contains("could not be opened") {
            return false
        }
    }

    func cleanUp() {
        runtime.releaseModel()
        try? FileManager.default.removeItem(at: scratch)
    }
}
