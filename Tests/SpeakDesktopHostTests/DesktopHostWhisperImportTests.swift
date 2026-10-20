import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostWhisperImportTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakeLocalPlatform>!
    private var transport: HostWhisperDownload!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeLocalState.shared.reset()
        FakeLocalState.shared.pinnedDigest = HostWhisperImportFixture.digest
        FakeLocalState.shared.importPayload = HostWhisperImportFixture.body
        FakeLocalState.shared.metadataTransport = HostWhisperMetadata()
        transport = HostWhisperDownload()
        FakeLocalState.shared.transport = transport
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        DesktopHostModels.setLocalLabels([:])
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hf-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController(directory: directory, effects: LocalEffects())
        await controller.markReadyForSelfTest()
        await controller.configureLocalModels()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
        FakeLocalState.shared.reset()
        DesktopHostModels.configure(streamingQualified: true, local: [])
        DesktopHostModels.setLocalLabels([:])
    }

    func testExplicitImportListsPinnedMetadataWithoutInstallingOrSelecting() async throws {
        let before = DesktopHostModels.all.map(\.id)
        let selected = await controller.selectedIndex()
        try await importReference()
        XCTAssertEqual(transport.count, 0)
        XCTAssertEqual(FakeLocalState.shared.rows.count, 5)
        XCTAssertEqual(FakeLocalState.shared.rows.last?.state, .notDownloaded)
        XCTAssertTrue(FakeLocalState.shared.rows.last?.about.contains(HostWhisperImportFixture.revision) == true)
        XCTAssertEqual(Array(DesktopHostModels.all.prefix(before.count)).map(\.id), before)
        let after = await controller.selectedIndex()
        XCTAssertEqual(after, selected)
    }

    func testInstalledSelectionUsesRealHostDispatchLanguageAndFriendlyHistory() async throws {
        try await installReference()
        let model = try HostWhisperImportFixture.model
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model.id })
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        let audio = directory.appendingPathComponent("speech.wav")
        let samples = [Int16](repeating: 4_000, count: 16_000)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)).write(to: audio)
        let result = try await controller.transcribePreparedAudio(
            audio, model: model.id, key: "", duration: 1, language: "fr-FR"
        )
        XCTAssertEqual(result.modelIdentifier, model.id)
        XCTAssertEqual(FakeLocalState.shared.runtime.request?.model, model.id)
        XCTAssertEqual(FakeLocalState.shared.runtime.request?.language, "fr")
        XCTAssertEqual(result.text, "Local words from \(model.displayName).")
        await controller.importAudio(path: audio.path, modelIndex: index)
        let records = try await controller.store.recoverInterruptedRecordings().records
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.modelIdentifier, model.id)
        XCTAssertNotNil(record.result)
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: model.id), model.displayName + " (on-device)")
        XCTAssertEqual(transport.count, 1, "Recognition never downloads weights")
    }

    func testSelectionMetadataReadinessAndFriendlyNameSurviveRestart() async throws {
        try await installReference()
        let model = try HostWhisperImportFixture.model
        let slot = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model.id })
        let selected = await controller.selectModel(slot)
        XCTAssertTrue(selected)
        await controller.close()
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        controller = try DesktopHostController(directory: directory, effects: LocalEffects())
        await controller.markReadyForSelfTest()
        await controller.configureLocalModels()
        let current = await controller.settingsModelForTests
        let readiness = await controller.localReadiness(model.id)
        XCTAssertEqual(current, model.id)
        XCTAssertNil(readiness)
        XCTAssertEqual(FakeLocalState.shared.rows.last?.state, .downloaded)
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: current), model.displayName + " (on-device)")
    }

    func testCancelAndCloseOwnMetadataWorkWithoutInstalling() async throws {
        let metadata = HostWhisperMetadata(held: true)
        FakeLocalState.shared.metadataTransport = metadata
        await controller.importLocalModel(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        try await waitFor("metadata request") { metadata.count == 1 }
        await controller.cancelLocalModelImport()
        try await waitFor("cancel owner") {
            let running = await self.controller.localImportInProgressForTests
            return !running
        }
        XCTAssertTrue(FakeLocalState.shared.status.contains("cancelled"))
        let imports = await controller.localImportModelsForTests
        XCTAssertTrue(imports.isEmpty)
        await controller.importLocalModel(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        let report = await controller.close()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(transport.count, 0)
        let active = await controller.activeLocalOperationsForTests
        XCTAssertEqual(active, 0)
    }

    func testDiscoveryAndPersistenceFailuresDoNotPublishSuccessOrCapability() async throws {
        FakeLocalState.shared.metadataTransport = HostWhisperMetadata(invalid: true)
        await controller.importLocalModel(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        try await waitFor("failed discovery") {
            let running = await self.controller.localImportInProgressForTests
            return !running
        }
        XCTAssertTrue(FakeLocalState.shared.status.contains("Model import failed"))
        XCTAssertEqual(FakeLocalState.shared.rows.count, 4)
        let destination = directory.appendingPathComponent("LocalModels/imported-whispercpp-models.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        FakeLocalState.shared.metadataTransport = HostWhisperMetadata()
        await controller.importLocalModel(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        try await waitFor("failed persistence") {
            let running = await self.controller.localImportInProgressForTests
            return !running
        }
        XCTAssertTrue(FakeLocalState.shared.status.contains("Model import failed"))
        let imports = await controller.localImportModelsForTests
        XCTAssertTrue(imports.isEmpty)
        XCTAssertEqual(DesktopHostModels.local.count, 4)
    }

    func testImportedModelRemovalRespectsInferenceLeaseAndRetainsReference() async throws {
        try await installReference()
        let model = try HostWhisperImportFixture.model
        let audio = try wave()
        let runtime = FakeLocalState.shared.runtime
        runtime.hold()
        let transcribing = Task {
            try await self.controller.transcribeLocally(audio, model: model.id, language: "de-DE")
        }
        defer { runtime.release() }
        try await waitFor("held imported recognition") { runtime.recognitions == 1 }
        await controller.localModelAction(.remove, index: 4)
        let held = await controller.ownershipForTests
        XCTAssertTrue(held.isInUse(model.id))
        XCTAssertFalse(held.isRemoving(model.id))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("is in use") == true)
        runtime.release()
        _ = try await transcribing.value
        await controller.localModelAction(.remove, index: 4)
        try await waitFor("imported weights removed") { FakeLocalState.shared.rows.last?.state == .notDownloaded }
        let readiness = await controller.localReadiness(model.id)
        XCTAssertTrue(readiness?.contains("not downloaded") == true)
        let metadata = try HuggingFaceWhisperStore(directory: directory.appendingPathComponent("LocalModels")) {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }.load()
        XCTAssertEqual(metadata, [model])
        XCTAssertEqual(runtime.releasedPaths.count, 1)
    }

    func testImportedRuntimeFailureIsVisibleAndDoesNotInventReadinessOrTranscript() async throws {
        try await installReference()
        let model = try HostWhisperImportFixture.model
        let audio = try wave()
        FakeLocalState.shared.runtimeMissing = "The runtime is not bundled."
        let missing = await controller.localReadiness(model.id)
        XCTAssertEqual(missing, "The runtime is not bundled.")
        FakeLocalState.shared.runtimeMissing = nil
        FakeLocalState.shared.runtimeOpenFailure = "Synthetic runtime refusal."
        do {
            _ = try await controller.transcribeLocally(audio, model: model.id, language: nil)
            XCTFail("A refused runtime returned a transcript")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Synthetic runtime refusal"))
        }
        XCTAssertTrue(FakeLocalState.shared.status.contains("Synthetic runtime refusal"))
        XCTAssertEqual(FakeLocalState.shared.runtime.recognitions, 0)
        FakeLocalState.shared.runtimeOpenFailure = nil
        let result = try await controller.transcribeLocally(audio, model: model.id, language: "de-DE")
        XCTAssertEqual(result.modelIdentifier, model.id)
        XCTAssertEqual(FakeLocalState.shared.runtime.request?.language, "de")
    }

    func testDownloadCancellationFailureAndCloseReleaseOwnedWorkWithoutReadiness() async throws {
        try await importReference()
        let model = try HostWhisperImportFixture.model
        let held = HostWhisperDownload(held: true)
        FakeLocalState.shared.transport = held
        await controller.localModelAction(.download, index: 4)
        try await waitFor("held weight request") { held.count == 1 }
        await controller.localModelAction(.cancel, index: 4)
        try await waitFor("cancelled weight owner") {
            await self.controller.activeLocalOperationsForTests == 0
        }
        XCTAssertTrue(FakeLocalState.shared.status.contains("paused"))
        var readiness = await controller.localReadiness(model.id)
        XCTAssertNotNil(readiness)
        FakeLocalState.shared.transport = HostWhisperDownload(failure: true)
        await controller.localModelAction(.download, index: 4)
        try await waitFor("failed weight owner") {
            await self.controller.activeLocalOperationsForTests == 0
        }
        XCTAssertNotEqual(FakeLocalState.shared.rows.last?.state, .downloaded)
        readiness = await controller.localReadiness(model.id)
        XCTAssertNotNil(readiness)
        let closing = HostWhisperDownload(held: true)
        FakeLocalState.shared.transport = closing
        await controller.localModelAction(.download, index: 4)
        try await waitFor("closing weight owner") { closing.count == 1 }
        let report = await controller.close()
        XCTAssertTrue(report.isComplete)
        let operations = await controller.activeLocalOperationsForTests
        XCTAssertEqual(operations, 0)
        let owned = await controller.ownershipForTests
        XCTAssertFalse(owned.isDownloading(model.id))
    }
}

private extension DesktopHostWhisperImportTests {
    func waitFor(_ description: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out: \(description)")
    }

    func importReference() async throws {
        await controller.importLocalModel(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        try await waitFor("metadata owner to finish") {
            let running = await self.controller.localImportInProgressForTests
            return !running
        }
        let imported = await controller.localImportModelsForTests
        XCTAssertEqual(imported, [try HostWhisperImportFixture.model])
    }

    func installReference() async throws {
        try await importReference()
        await controller.localModelAction(.download, index: 4)
        try await waitFor("imported model download") { FakeLocalState.shared.rows.last?.state == .downloaded }
    }

    func wave() throws -> URL {
        let audio = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let samples = [Int16](repeating: 4_000, count: 16_000)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)).write(to: audio)
        return audio
    }
}
