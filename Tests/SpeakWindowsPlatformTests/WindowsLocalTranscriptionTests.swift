import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsLocalTranscriptionTests: XCTestCase {
    func testWindowsCNGSHA256MatchesKnownVectors() throws {
        let provider = WindowsSHA256Hasher.provider
        XCTAssertEqual(try provider.sha256(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try provider.sha256(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            try provider.sha256(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        let hasher = try WindowsSHA256Hasher()
        _ = try hasher.finish()
        XCTAssertThrowsError(try hasher.finish(), "A finished digest is single-use")
    }

    func testStreamedFileDigestMatchesTheWholeBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chunks.bin")
        let body = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try body.write(to: file)
        let provider = WindowsSHA256Hasher.provider
        XCTAssertEqual(try provider.sha256(ofFileAt: file, chunkSize: 1 << 20), try provider.sha256(of: body))
    }

    func testMissingRuntimeIsRefusedWithoutCrashing() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try WindowsWhisperRuntime.open(directory: empty, allowGPU: false)) { error in
            XCTAssertTrue(error is WindowsLocalTranscriptionError, "\(error)")
        }
        let unrelated = URL(fileURLWithPath: "relative-runtime-folder")
        XCTAssertThrowsError(try WindowsWhisperRuntime.open(directory: unrelated, allowGPU: false))
    }

    /// The real runtime with the pinned tiny catalogue model. CI sets
    /// `JSTI_WHISPER_RUNTIME_DIRECTORY` to the whisper.cpp build,
    /// `JSTI_WHISPER_TEST_AUDIO` to the upstream JFK sample and
    /// `JSTI_LOCAL_MODEL_DIRECTORY` to a cached model folder.
    func testPinnedTinyModelTranscribesSpeechAndKeepsSilenceEmpty() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let runtimeDirectory = environment["JSTI_WHISPER_RUNTIME_DIRECTORY"],
              let audio = environment["JSTI_WHISPER_TEST_AUDIO"],
              let models = environment["JSTI_LOCAL_MODEL_DIRECTORY"] else {
            throw XCTSkip("Requires the whisper.cpp runtime build, its JFK sample and a model folder.")
        }
        let spec = try XCTUnwrap(DesktopLocalTranscription.model(for: "local/whisperkit/tiny", host: .windows))
        let installer = LocalModelInstaller(
            root: URL(fileURLWithPath: models, isDirectory: true), digests: WindowsSHA256Hasher.provider,
            transport: LocalModelURLSessionTransport()
        )
        let file = try await installer.install(.init(spec))
        try installer.verify(.init(spec))
        let runtime = try WindowsWhisperRuntime.open(
            directory: URL(fileURLWithPath: runtimeDirectory, isDirectory: true), allowGPU: true
        )
        XCTAssertTrue(runtime.description.hasPrefix("whisper.cpp 1.9.4"), runtime.description)
        let recognizer = WindowsWhisperRecognizer(runtime: runtime)
        let speech = try await DesktopLocalTranscription.transcribe(
            audioURL: URL(fileURLWithPath: audio), model: spec, modelFile: file, language: "en", recognizer: recognizer
        )
        let words = speech.text.lowercased().filter { $0.isLetter || $0 == " " }
        XCTAssertTrue(words.contains("ask not what your country can do for you"), speech.text)
        XCTAssertEqual(speech.modelIdentifier, "local/whisperkit/tiny")
        XCTAssertEqual(speech.duration, 11, accuracy: 0.1)

        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: silent) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(count: 32_000), sampleRate: 16_000)).write(to: silent)
        let silence = try await DesktopLocalTranscription.transcribe(
            audioURL: silent, model: spec, modelFile: file, language: nil, recognizer: recognizer
        )
        XCTAssertEqual(silence.text, "")

        let samples = [Float](repeating: 0.05, count: 32_000)
        let cancelled = Task { try await runtime.transcribe(samples: samples, modelFile: file, language: nil) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled transcription completed")
        } catch is CancellationError {}
    }
}
