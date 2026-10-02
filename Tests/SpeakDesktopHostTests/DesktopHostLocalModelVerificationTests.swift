import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// Recognition never runs a downloaded model whose bytes no longer match its
// pinned SHA-256: the runtime checks the bytes it loads, and the shared host
// deletes a model it refuses. Driven through the fake local platform, whose
// stand-in digest and runtime report a mismatch for any byte other than zero;
// the platform runtimes' own hashing is covered by their runtime tests.

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

    /// Changes one byte of the installed model; its receipt and size still match.
    private func tamperWithTinyFile() throws {
        let handle = try FileHandle(forWritingTo: tinyFile)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data([0x5a]))
        try handle.close()
    }

    func testAModelTamperedAtItsPinnedSizeIsDeletedAndNeverRecognised() async throws {
        try await download(tiny)
        try tamperWithTinyFile()
        let slot = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == tiny.catalogueID })
        for _ in 0..<2 {
            await controller.toggle(
                target: nil, modelIndex: slot, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
            )
        }
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 0, "No recognition ran with the refused bytes")
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

    func testTheHostLeavesHashingToTheRuntimeLoad() async throws {
        try await download(tiny)
        XCTAssertEqual(FakeLocalState.shared.hashCount, 1, "The download was verified")
        let speech = try speech()
        for _ in 0..<2 {
            let result = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
            XCTAssertEqual(result.text, "Local words from Whisper Tiny.")
        }
        XCTAssertEqual(FakeLocalState.shared.hashCount, 1, "Only the runtime reads the model before recognising")
        XCTAssertEqual(FakeLocalState.shared.runtime.loads, 1, "The runtime loads the model once and keeps it")
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 2)
    }

    func testAModelTheRuntimeRefusesFailsThatTranscriptionAndIsDeleted() async throws {
        try await download(tiny)
        try tamperWithTinyFile()
        let speech = try speech()
        do {
            _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
            XCTFail("A transcript from bytes that do not match the pinned digest was kept")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Whisper Tiny no longer matches its pinned SHA-256, so it was deleted and not used. "
                    + "Download it again in Local models, then retry this recording."
            )
        }
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 0, "No recognition ran with the refused bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tinyFile.path))
        XCTAssertEqual(row(tiny)?.state, .notDownloaded, "Local models offers the download again")
        do {
            _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
            XCTFail("A deleted model was used")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not downloaded"), error.localizedDescription)
        }
    }
}
