import Foundation
import SpeakCore
import XCTest
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

@testable import SpeakApp

@MainActor
final class LocalModelStreamingLeaseTests: XCTestCase {
    func testStoppedCapture_keepsFilesAvailableForTailDecodingUntilStreamIsReleased() async throws {
        let fixture = try self.makeFixture()
        let decoder = MockWhisperKitStream()
        var stream: LeasedWhisperKitStream? = try await self.makeStream(decoder: decoder, fixture: fixture)
        var capture: Task<Void, Error>? = Task { [stream = try XCTUnwrap(stream)] in try await stream.startStream() }
        await decoder.waitUntilStarted(after: 0)
        XCTAssertFalse(fixture.manager.delete(fixture.model))

        await stream?.stopStream()
        try await capture?.value
        capture = nil
        XCTAssertFalse(fixture.manager.delete(fixture.model), "Stopped capture still needs a tail decode")
        _ = try await stream?.decodeTail(after: 0)
        stream = nil

        await waitUntilWhisperKit { fixture.manager.canDelete(fixture.model) }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    func testTimedOutTail_retainsFilesAfterTheControllerDropsItsStream() async throws {
        let fixture = try self.makeFixture()
        let decoder = MockWhisperKitStream()
        let gate = TestGate()
        decoder.tailGate = gate
        var stream: LeasedWhisperKitStream? = try await self.makeStream(decoder: decoder, fixture: fixture)

        let result = await self.timeOutTail(on: try XCTUnwrap(stream))
        XCTAssertNil(result)
        stream = nil
        XCTAssertFalse(fixture.manager.delete(fixture.model), "A timed-out decode still owns its model files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.base.path))

        await gate.open()
        await waitUntilWhisperKit { fixture.manager.canDelete(fixture.model) }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    func testStreamConstructionFailure_releasesPreparedPipelineLease() async throws {
        let fixture = try self.makeFixture()
        do {
            _ = try await fixture.manager.makeWhisperKitStream(
                request: WhisperKitStreamRequest(batchModelID: fixture.model.id, language: nil), onEvent: { _ in }
            )
            XCTFail("An unloaded fixture has no tokenizer and cannot construct a live stream")
        } catch {
            XCTAssertEqual(error as? TranscriptionManagerError, .localLiveStreamingUnsupported)
        }
        await waitUntilWhisperKit { fixture.manager.canDelete(fixture.model) }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    private func timeOutTail(on stream: LeasedWhisperKitStream) async -> Result<String, any Error>? {
        await BoundedOperation.run(timeout: .milliseconds(30)) {
            try await stream.decodeTail(after: 0)
        }
    }

    private func makeStream(
        decoder: MockWhisperKitStream, fixture: StreamingLeaseFixture
    ) async throws -> LeasedWhisperKitStream {
        let lease = try await fixture.manager.makeReadyPipelineLease(modelID: fixture.model.id)
        return LeasedWhisperKitStream(stream: decoder, lease: lease)
    }

    private func makeFixture() throws -> StreamingLeaseFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("downloads"))
        let base = try storage.prepare(for: model.id)
        let folder = base.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("weights"))
        try storage.recordModelFolder(folder, for: model.id)
        let marker = directory.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_") + ".installed")
        try Data("installed-managed-v1\n".utf8).write(to: marker)
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: storage, pipelineLoader: { config in
            try await WhisperKit(WhisperKitConfig(modelFolder: config.modelFolder, load: false, download: false))
        })
        return StreamingLeaseFixture(manager: manager, model: model, base: base)
    }
}

private struct StreamingLeaseFixture {
    let manager: LocalModelManager
    let model: LocalTranscriptionModel
    let base: URL
}
