import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// The shared on-device model workflow (downloads, readiness, recognition and
// removal ownership) driven through a fake local platform: no network, disk
// digest or speech runtime. Windows and Linux both run this code.

final class DesktopHostLocalModelsTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakeLocalPlatform>!
    private let tiny = DesktopLocalTranscription.model(for: "local/whisperkit/tiny", host: .linux)!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeLocalState.shared.reset()
        FakeLocalState.shared.pinnedDigest = tiny.artifact.sha256
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        DesktopHostModels.setLocalLabels([:])
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-tests-\(UUID().uuidString)")
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

    private var tinyIndex: Int { DesktopLocalTranscription.models(host: .linux).firstIndex(of: tiny)! }

    private func row(_ model: WhisperCppModel) -> DesktopHostLocalModelRow? {
        FakeLocalState.shared.rows.first { $0.name == model.displayName }
    }

    private func download(_ model: WhisperCppModel) async throws {
        FakeLocalState.shared.pinnedDigest = model.artifact.sha256
        let index = DesktopLocalTranscription.models(host: .linux).firstIndex(of: model)!
        await controller.localModelAction(.download, index: index)
        try await waitFor("\(model.displayName) to download") { self.row(model)?.state == .downloaded }
    }

    private func wave(_ samples: [Int16]) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)).write(to: url)
        return url
    }

    func testEveryPinnedModelIsListedAndLabelledInThePicker() throws {
        let rows = FakeLocalState.shared.rows
        XCTAssertEqual(rows.map(\.name), WhisperCppModels.all.map(\.displayName))
        XCTAssertTrue(rows.allSatisfy { $0.state == .notDownloaded && $0.detail.hasSuffix("Not downloaded") })
        XCTAssertTrue(rows.allSatisfy { $0.about.contains("pinned by SHA-256") })
        let (slots, labels) = DesktopHostModels.labelledSnapshot
        let entry = try XCTUnwrap(slots.entries.first { $0.option.id == tiny.catalogueID })
        XCTAssertTrue(entry.isLocal)
        XCTAssertEqual(
            DesktopHostModels.label(for: entry, localLabels: labels),
            "Whisper Tiny (on-device) \u{2014} download in Local models"
        )
        XCTAssertTrue(FakeLocalState.shared.status.hasPrefix("Fake runtime ready. 0 of \(rows.count)"))
    }

    func testReadinessNamesWhatIsMissing() async throws {
        FakeLocalState.shared.runtimeMissing = "No runtime in this build."
        var readiness = await controller.localReadiness(tiny.catalogueID)
        XCTAssertEqual(readiness, "No runtime in this build.")
        FakeLocalState.shared.runtimeMissing = nil
        readiness = await controller.localReadiness(tiny.catalogueID)
        XCTAssertEqual(readiness, "Whisper Tiny is not downloaded yet. Open Local models to download it.")
        readiness = await controller.localReadiness("local/whisperkit/distil-large-v3")
        XCTAssertEqual(readiness, "This on-device model is not available in this Test build.")
        try await download(tiny)
        readiness = await controller.localReadiness(tiny.catalogueID)
        XCTAssertNil(readiness)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Whisper Tiny downloaded and verified. Choose it in tests.")
        XCTAssertEqual(DesktopHostModels.labelledSnapshot.1[tiny.catalogueID], nil, "A downloaded model has no label")
    }

    func testCancelledDownloadPausesAndResumesFromItsBytes() async throws {
        let transport = HeldTransport(pauseAfter: 8 << 20)
        FakeLocalState.shared.transport = transport
        await controller.localModelAction(.download, index: tinyIndex)
        try await waitFor("the download to stall") {
            transport.offsets == [0] && self.row(self.tiny)?.state == .downloading
        }
        await controller.localModelAction(.cancel, index: tinyIndex)
        try await waitFor("the download to pause") { self.row(self.tiny)?.state == .paused }
        XCTAssertEqual(
            FakeLog.shared.allStatuses.last, "Whisper Tiny: Download paused. Choose Resume download to continue."
        )
        XCTAssertEqual(DesktopHostModels.labelledSnapshot.1[tiny.catalogueID], "download paused")
        XCTAssertTrue(row(tiny)?.detail.hasSuffix("downloaded, paused") == true, row(tiny)?.detail ?? "")
        let ownership = await controller.ownershipForTests
        XCTAssertFalse(ownership.isDownloading(tiny.catalogueID), "A paused download gave its files back")

        transport.resume.release()
        await controller.localModelAction(.download, index: tinyIndex)
        try await waitFor("the resumed download") { self.row(self.tiny)?.state == .downloaded }
        XCTAssertEqual(transport.offsets.count, 2)
        XCTAssertGreaterThanOrEqual(transport.offsets[1], 8 << 20, "The second request resumed the kept bytes")
    }

    func testLocalRecordingNeedsNoKeyAndStoresTheCatalogueModel() async throws {
        try await download(tiny)
        let slot = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == tiny.catalogueID })
        await controller.toggle(
            target: nil, modelIndex: slot, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: slot, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let records = try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.modelIdentifier, tiny.catalogueID)
        XCTAssertEqual(record.result?.text, "Local words from Whisper Tiny.")
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: record.modelIdentifier), "Whisper Tiny (on-device)")
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.hasPrefix("Transcribing on this computer with Whisper Tiny")
        })
        let ownership = await controller.ownershipForTests
        XCTAssertFalse(ownership.isInUse(tiny.catalogueID), "A finished recording let its model go")
    }

    func testSilenceStaysEmptyWithoutRunningTheModel() async throws {
        try await download(tiny)
        let silent = try wave([Int16](repeating: 0, count: 16_000))
        let result = try await controller.transcribeLocally(silent, model: tiny.catalogueID, language: "en")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 0)
    }

    func testRemovalWaitsForTheTranscriptionHoldingItsModel() async throws {
        try await download(tiny)
        let runtime = FakeLocalState.shared.runtime
        runtime.hold()
        let speech = try wave((0..<16_000).map { Int16(($0 % 40) * 400 - 8_000) })
        let transcribing = Task {
            try await self.controller.transcribeLocally(speech, model: self.tiny.catalogueID, language: nil)
        }
        try await waitFor("the held recognition") { runtime.recognitions == 1 }
        await controller.localModelAction(.remove, index: tinyIndex)
        XCTAssertEqual(FakeLog.shared.allStatuses.last,
                       "Whisper Tiny is in use. Remove it after the current recording finishes.")
        var ownership = await controller.ownershipForTests
        XCTAssertTrue(ownership.isInUse(tiny.catalogueID) && !ownership.isRemoving(tiny.catalogueID))

        runtime.release()
        _ = try await transcribing.value
        ownership = await controller.ownershipForTests
        XCTAssertFalse(ownership.isInUse(tiny.catalogueID))
        await controller.localModelAction(.remove, index: tinyIndex)
        try await waitFor("the removal") { self.row(self.tiny)?.state == .notDownloaded }
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Whisper Tiny removed from this computer.")
        let file = LocalModelInstaller(
            root: directory.appendingPathComponent("LocalModels"), digests: FakeLocalPlatform.localModelDigests,
            transport: HeldTransport()
        ).fileURL(for: .init(tiny))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(runtime.releasedPaths, [file.path], "The runtime freed only the removed model")
    }

    func testARuntimeThatCannotStartIsReportedAndKeptFromRecording() async throws {
        try await download(tiny)
        FakeLocalState.shared.runtimeOpenFailure = "libwhisper.so.1 is damaged."
        let speech = try wave((0..<16_000).map { Int16(($0 % 40) * 400 - 8_000) })
        do {
            _ = try await controller.transcribeLocally(speech, model: tiny.catalogueID, language: nil)
            XCTFail("A runtime that could not start transcribed")
        } catch {}
        let readiness = await controller.localReadiness(tiny.catalogueID)
        XCTAssertEqual(readiness, "The on-device speech runtime could not start: libwhisper.so.1 is damaged.")
        XCTAssertTrue(FakeLocalState.shared.status.hasPrefix("The on-device speech runtime could not start"))
    }

    func testTheGPUChoiceIsSaved() async throws {
        XCTAssertTrue(FakeLocalState.shared.useGPU, "The GPU is allowed until the user turns it off")
        await controller.setLocalUseGPU(false)
        XCTAssertFalse(FakeLocalState.shared.useGPU)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "GPU preference saved.")
        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("settings.json"))
        ) as? [String: Any]
        XCTAssertEqual(saved?["localUseGPU"] as? Bool, false)
    }
}
