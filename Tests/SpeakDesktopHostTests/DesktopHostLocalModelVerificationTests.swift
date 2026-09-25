import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// Recognition never runs a downloaded model whose bytes no longer match its
// pinned SHA-256: the shared host rehashes the file whenever the runtime may
// load it, and only then. Driven through the fake local platform, whose
// stand-in digest reports a mismatch for any byte other than zero.

final class DesktopHostLocalModelVerificationTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakeLocalPlatform>!
    private let tiny = DesktopLocalTranscription.model(for: "local/whisperkit/tiny", host: .linux)!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeLocalState.shared.reset()
        FakeLocalState.shared.pinnedDigest = tiny.artifact.sha256
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        DesktopHostModels.setLocalLabels([:])
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("verify-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakeLocalPlatform>(directory: directory, effects: LocalEffects())
        await controller.markReadyForSelfTest()
        await controller.configureLocalModels()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true, local: [])
        DesktopHostModels.setLocalLabels([:])
    }

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func row(_ model: WhisperCppModel) -> DesktopHostLocalModelRow? {
        FakeLocalState.shared.rows.first { $0.name == model.displayName }
    }

    private func download(_ model: WhisperCppModel) async throws {
        let index = DesktopLocalTranscription.models(host: .linux).firstIndex(of: model)!
        await controller.localModelAction(.download, index: index)
        try await waitFor("\(model.displayName) to download") { self.row(model)?.state == .downloaded }
    }

    private func speech() throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let samples = (0..<16_000).map { Int16(($0 % 40) * 400 - 8_000) }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)).write(to: url)
        return url
    }

    private var tinyFile: URL {
        LocalModelInstaller(
            root: directory.appendingPathComponent("LocalModels"), digests: FakeLocalPlatform.localModelDigests,
            transport: HeldTransport()
        ).fileURL(for: .init(tiny))
    }

    /// Replaces the model with the same bytes as a new, later file, which the
    /// runtime would read on its next load.
    private func replaceTinyFile() throws {
        try Data(contentsOf: tinyFile).write(to: tinyFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3_600)], ofItemAtPath: tinyFile.path
        )
    }

    func testAModelTamperedAtItsPinnedSizeIsDeletedAndNeverRecognised() async throws {
        try await download(tiny)
        // The receipt and byte count still match; only the bytes differ.
        let handle = try FileHandle(forWritingTo: tinyFile)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data([0x5a]))
        try handle.close()
        let slot = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == tiny.catalogueID })
        for _ in 0..<2 {
            await controller.toggle(
                target: nil, modelIndex: slot, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
            )
        }
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 0, "The recogniser never received the model")
        let records = try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
        let record = try XCTUnwrap(records.first)
        XCTAssertNil(record.result)
        XCTAssertEqual(
            record.failure,
            "Whisper Tiny no longer matches its pinned SHA-256, so it was deleted and not used. "
                + "Download it again in Local models, then retry this recording."
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename).path
        ), "The recording keeps its audio for a retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tinyFile.path))
        XCTAssertEqual(row(tiny)?.state, .notDownloaded, "Local models offers the download again")
    }

    func testTheModelIsRehashedOnlyWhenTheRuntimeMayLoadItsBytes() async throws {
        try await download(tiny)
        XCTAssertEqual(FakeLocalState.shared.hashCount, 1, "The download was verified")
        let speech = try speech()
        _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
        XCTAssertEqual(FakeLocalState.shared.hashCount, 2, "The first load in this process rehashes the model")
        _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
        XCTAssertEqual(FakeLocalState.shared.hashCount, 2, "The unchanged model the runtime holds is not rehashed")
        try replaceTinyFile()
        let result = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
        XCTAssertEqual(FakeLocalState.shared.hashCount, 3, "A changed file is rehashed before it can be loaded")
        XCTAssertEqual(result.text, "Local words from Whisper Tiny.")
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 3)
    }

    func testATranscriptIsRefusedWhenItsModelChangedDuringRecognition() async throws {
        try await download(tiny)
        let runtime = FakeLocalState.shared.runtime
        runtime.hold()
        let speech = try speech()
        let transcribing = Task {
            try await self.controller.transcribeLocally(speech, model: self.tiny.catalogueID, language: nil)
        }
        try await waitFor("the held recognition") { runtime.recognitions == 1 }
        try replaceTinyFile()
        runtime.release()
        do {
            _ = try await transcribing.value
            XCTFail("A transcript from a model that changed during recognition was kept")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Whisper Tiny changed on disk during transcription, so its transcript was not kept. "
                    + "Retry this recording to check the model again."
            )
        }
        XCTAssertEqual(runtime.releasedPaths, [tinyFile.path], "The runtime let go of bytes that were never hashed")
        let hashes = FakeLocalState.shared.hashCount
        _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
        XCTAssertEqual(FakeLocalState.shared.hashCount, hashes + 1, "The next use checks the new file first")
    }
}
