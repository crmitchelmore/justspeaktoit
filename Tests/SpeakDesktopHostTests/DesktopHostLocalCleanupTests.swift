import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostLocalCleanupTests: XCTestCase {
    func testLocalDispatchNeverReadsRemoteKeysAndPreservesOriginalOnUnavailableAdapter() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Local cleanup looked up a remote credential") }
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = .init(
            text: "Raw words", segments: [], confidence: nil, duration: 1,
            modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
        )
        let model = try XCTUnwrap(ModelCatalog.localPostProcessing.first)
        let result = await controller.postProcess(record, options: .init(mode: .localLLM, modelIdentifier: model.id))
        XCTAssertEqual(result.result?.text, "Raw words")
        XCTAssertNil(result.processedText)
        XCTAssertTrue(result.postProcessingFailure?.contains("native llama.cpp adapter") == true)
        XCTAssertNil(result.postProcessingModelIdentifier)
        FakeLog.shared.reset()
        await controller.close()
    }

    func testSilentHostRecordNeverExecutesOrSynthesizesCleanupText() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Silent input read a key") }
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = .init(
            text: "[BLANK_AUDIO]", segments: [], confidence: nil, duration: 1,
            modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.correctedText = "This placeholder must not reach the model."
        let result = await controller.postProcess(
            record, options: .init(mode: .localLLM, modelIdentifier: "local/post-processing/not-imported")
        )
        XCTAssertEqual(result.processedText, "")
        XCTAssertNil(result.postProcessingFailure)
        XCTAssertNil(result.postProcessingModelIdentifier)
        FakeLog.shared.reset()
        await controller.close()
    }

    func testSavingLocalOnUnsupportedHostDoesNotWriteATypedRemoteKeyOrEnableAFallback() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        FakeLog.shared.installKeyWriteHook { _, _ in XCTFail("A Local selection wrote a remote key") }
        let localModel = try XCTUnwrap(ModelCatalog.localPostProcessing.first {
            LocalPostProcessingModel.isDownloadedModelID($0.id)
        })
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: localModel.id, prompt: "Exact system", key: "must-not-save"
        )
        let options = await controller.postProcessingOptions()
        XCTAssertEqual(options.mode, .disabled)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("no downloaded-model cleanup adapter") == true)
        FakeLog.shared.reset()
        await controller.close()
    }
}
