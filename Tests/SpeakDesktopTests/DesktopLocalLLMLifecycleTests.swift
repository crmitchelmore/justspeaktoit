import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopLocalLLMLifecycleTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try LocalModelTestFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testInstallAndRestartUseTheSharedVerifiedReceipt() async throws {
        let model = try LocalLLMFixture.model()
        let service = try LocalLLMFixture.store(directory, models: [model])
        try await service.install(model.id)
        let rows = await service.rows()
        XCTAssertEqual(rows.first { $0.model.id == model.id }?.state, .installed)
        await service.close()
        let restarted = try LocalLLMFixture.store(directory, models: [model])
        let result = try await restarted.complete(
            modelIdentifier: model.id, systemPrompt: "Exact system", userPrompt: "Exact user", temperature: 0
        )
        XCTAssertEqual(result, "Cleaned transcript.")
        await restarted.close()
    }

    func testInterruptedDownloadResumesOnlyPinnedBytes() async throws {
        let model = try LocalLLMFixture.model()
        let transport = FakeModelTransport(body: LocalLLMFixture.bytes)
        transport.failure = .dropAfter(14)
        let service = try LocalLLMFixture.store(directory, models: [model], transport: transport)
        do { try await service.install(model.id); XCTFail("Transport failure hidden") } catch {}
        let partial = await service.rows()
        XCTAssertEqual(partial.first { $0.model.id == model.id }?.state, .partial(
            received: 14, total: Int64(LocalLLMFixture.bytes.count)
        ))
        transport.failure = .none
        try await service.install(model.id)
        XCTAssertEqual(transport.requests.map(\.resumeOffset), [0, 14])
        let complete = await service.rows()
        XCTAssertEqual(complete.first { $0.model.id == model.id }?.state, .installed)
        await service.close()
    }

    func testWrongDigestAndNonGGUFNeverBecomeInstalled() async throws {
        let model = try LocalLLMFixture.model()
        let transport = FakeModelTransport(body: Data(repeating: 0, count: LocalLLMFixture.bytes.count))
        let service = try LocalLLMFixture.store(directory, models: [model], transport: transport)
        do { try await service.install(model.id); XCTFail("Wrong bytes accepted") } catch {
            XCTAssertEqual(error as? LocalModelInstallError, .checksumMismatch)
        }
        let rows = await service.rows()
        XCTAssertEqual(rows.first { $0.model.id == model.id }?.state, .notInstalled)
        await service.close()
        let bad = Data(repeating: 0, count: LocalLLMFixture.bytes.count)
        let badModel = try LocalLLMFixture.model(bytes: bad)
        let invalid = try LocalLLMFixture.store(
            directory, models: [badModel], transport: FakeModelTransport(body: bad)
        )
        do { try await invalid.install(badModel.id); XCTFail("A digest-valid non-GGUF was admitted") } catch {
            XCTAssertEqual(error as? LocalLLMError, .unsupportedArtifact)
        }
        let invalidRows = await invalid.rows()
        XCTAssertNotEqual(invalidRows.first { $0.model.id == badModel.id }?.state, .installed)
        await invalid.close()
    }

    func testModelCannotBeRemovedOrReinstalledUntilCancelledWorkerActuallyEnds() async throws {
        let model = try LocalLLMFixture.model()
        let runtime = LocalLLMRuntimeSpy(held: true)
        let service = try LocalLLMFixture.store(directory, models: [model], runtime: runtime)
        try await service.install(model.id)
        let task = Task {
            try await service.complete(
                modelIdentifier: model.id, systemPrompt: "System", userPrompt: "User", temperature: 0.5
            )
        }
        let entered = await runtime.entered
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let cancelled = await runtime.cancelled
        await fulfillment(of: [cancelled], timeout: 2)
        let held = await service.rows()
        XCTAssertEqual(held.first { $0.model.id == model.id }?.inUse, true)
        do { try await service.remove(model.id); XCTFail("Removal raced an unretired worker") } catch {
            XCTAssertEqual(error as? LocalLLMError, .busy)
        }
        do { try await service.install(model.id); XCTFail("Download raced an unretired worker") } catch {
            XCTAssertEqual(error as? LocalLLMError, .busy)
        }
        await runtime.release()
        do { _ = try await task.value; XCTFail("Cancellation became success") } catch is CancellationError {}
        try await service.remove(model.id)
        let removed = await service.rows()
        XCTAssertEqual(removed.first { $0.model.id == model.id }?.state, .notInstalled)
        XCTAssertEqual(removed.first { $0.model.id == model.id }?.metadata, model)
        await service.close()
    }

    func testCloseCancelsOwnedWorkerAndRejectsNewAdmission() async throws {
        let model = try LocalLLMFixture.model()
        let runtime = LocalLLMRuntimeSpy(held: true)
        let service = try LocalLLMFixture.store(directory, models: [model], runtime: runtime)
        try await service.install(model.id)
        let task = Task {
            try await service.complete(
                modelIdentifier: model.id, systemPrompt: "System", userPrompt: "User", temperature: 0
            )
        }
        let entered = await runtime.entered
        await fulfillment(of: [entered], timeout: 2)
        await service.close()
        let cancelled = await runtime.cancelled
        await fulfillment(of: [cancelled], timeout: 2)
        do { try await service.install(model.id); XCTFail("Closed store admitted download") } catch {
            XCTAssertEqual(error as? LocalLLMError, .closed)
        }
        let held = await service.rows()
        XCTAssertEqual(held.first { $0.model.id == model.id }?.inUse, true)
        await runtime.release()
        do { _ = try await task.value; XCTFail("Closed worker published success") } catch is CancellationError {}
    }

    func testAliasesShareDigestStorageAndOwnershipRatherThanClobberingReceipts() async throws {
        let first = try LocalLLMFixture.model()
        let alias = try LocalLLMFixture.model(repository: "another/mirror", filename: "same-weights.gguf")
        let transport = FakeModelTransport(body: LocalLLMFixture.bytes)
        let runtime = LocalLLMRuntimeSpy(held: true)
        let service = try LocalLLMFixture.store(
            directory, models: [first, alias], transport: transport, runtime: runtime
        )
        try await service.install(first.id)
        try await service.install(alias.id)
        XCTAssertEqual(transport.requests.count, 1)
        let task = Task {
            try await service.complete(
                modelIdentifier: first.id, systemPrompt: "System", userPrompt: "User", temperature: 0
            )
        }
        let entered = await runtime.entered
        await fulfillment(of: [entered], timeout: 2)
        do { try await service.remove(alias.id); XCTFail("Alias removed an in-use digest") } catch {
            XCTAssertEqual(error as? LocalLLMError, .busy)
        }
        await runtime.release()
        _ = try await task.value
        try await service.remove(alias.id)
        let rows = await service.rows()
        XCTAssertEqual(rows.first { $0.model.id == first.id }?.state, .notInstalled)
        XCTAssertEqual(rows.first { $0.model.id == alias.id }?.state, .notInstalled)
        await service.close()
    }

    func testRuntimeDigestMismatchDiscardsBytesAndReceipt() async throws {
        let model = try LocalLLMFixture.model()
        let service = try LocalLLMFixture.store(
            directory, models: [model], runtime: LocalLLMRuntimeSpy(failure: .checksumMismatch)
        )
        try await service.install(model.id)
        do {
            _ = try await service.complete(
                modelIdentifier: model.id, systemPrompt: "System", userPrompt: "User", temperature: 0
            )
            XCTFail("Runtime mismatch hidden")
        } catch { XCTAssertEqual(error as? LocalModelInstallError, .checksumMismatch) }
        let rows = await service.rows()
        XCTAssertEqual(rows.first { $0.model.id == model.id }?.state, .notInstalled)
        await service.close()
    }

    func testExistingReferenceCannotSilentlyMoveToAnotherRevision() async throws {
        let model = try LocalLLMFixture.model()
        let changed = try LocalLLMFixture.model(revision: String(repeating: "b", count: 40))
        try HuggingFaceGGUFStore(directory: directory, prepareDirectory: LocalLLMFixture.prepare).save([model])
        let service = try DesktopLocalLLMStore(
            directory: directory, digests: TestSHA256.provider,
            transport: FakeModelTransport(body: LocalLLMFixture.bytes),
            metadataTransport: LocalLLMMetadataSpy(responses: [try LocalLLMFixture.metadata(changed)]),
            runtime: LocalLLMRuntimeSpy(), prepareDirectory: LocalLLMFixture.prepare
        )
        do {
            _ = try await service.resolve(repository: model.repository, filename: model.filename)
            XCTFail("Pinned reference replaced")
        } catch let error as LocalLLMError {
            guard case .inference = error else { return XCTFail("Wrong error") }
        }
        let restored = try HuggingFaceGGUFStore(
            directory: directory, prepareDirectory: LocalLLMFixture.prepare
        ).load()
        XCTAssertEqual(restored, [model])
        await service.close()
    }
}
