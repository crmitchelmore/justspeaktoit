import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class HuggingFaceGGUFTests: XCTestCase {
    func testRecommendationsKeepCanonicalMacIdentitiesAndFriendlyNames() throws {
        XCTAssertFalse(ModelCatalog.localPostProcessing.isEmpty)
        for recommendation in ModelCatalog.localPostProcessing {
            let model = try LocalLLMFixture.model(
                repository: recommendation.repoID, filename: recommendation.filename
            )
            XCTAssertEqual(model.model, recommendation)
            XCTAssertEqual(model.id, recommendation.id)
            XCTAssertEqual(ModelCatalog.friendlyName(for: model.id), recommendation.displayName)
            XCTAssertEqual(model.model.backend, .llamaCppGGUF)
        }
    }

    func testImportRetainsExactMetadataAndHistoryNamesWithoutConferringExecutionAuthority() throws {
        let model = try LocalLLMFixture.model()
        XCTAssertEqual(model.id, LocalPostProcessingModel.huggingFaceModelID(
            repoID: model.repository, filename: model.filename
        ))
        XCTAssertTrue(model.artifact.url.absoluteString.contains("/resolve/\(model.revision)/"))
        XCTAssertEqual(model.storageIdentifier, "local/llamacpp/sha256/" + model.sha256)
        DesktopLocalLLMModels.remember([model])
        XCTAssertEqual(DesktopLocalLLMModels.displayName(for: model.id), model.model.displayName)
        XCTAssertTrue(ModelCatalog.friendlyName(for: model.id).contains("example/cleanup"))
        XCTAssertFalse(ModelCatalog.friendlyName(for: model.id).contains("Downloaded Local Model"))
    }

    func testGGUFAdmissionRejectsTraversalMultipartAndWhisperWithoutWeakeningWhisperGuard() throws {
        for filename in [
            "../evil.gguf", "a/b.gguf", "a\\b.gguf", "two-00001-of-00002.gguf", ".hidden.gguf",
            "x..gguf", "ggml-tiny.bin", "model.gguf?download=true", "part-00001-of-00002.GGUF"
        ] {
            XCTAssertThrowsError(try LocalLLMFixture.model(filename: filename), filename)
        }
        XCTAssertThrowsError(try HuggingFaceWhisperModel.validateInput(
            repository: LocalLLMFixture.repository, filename: LocalLLMFixture.filename
        ))
        XCTAssertNoThrow(try HuggingFaceWhisperModel.validateInput(
            repository: LocalLLMFixture.repository, filename: "ggml-tiny.bin"
        ))
    }

    func testForgedCodableMetadataCannotBypassInitializerValidation() throws {
        let model = try LocalLLMFixture.model()
        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(HuggingFaceGGUFModel.self, from: encoded)
        XCTAssertEqual(decoded, model)
        for (key, value) in [
            ("filename", "../bad.gguf"), ("revision", "main"),
            ("sha256", String(repeating: "z", count: 64)), ("license", "MIT\ninjected")
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(
                HuggingFaceGGUFModel.self, from: JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testDiscoveryReadsMainThenExactImmutableRevision() async throws {
        let model = try LocalLLMFixture.model()
        let metadata = try LocalLLMFixture.metadata(model)
        let transport = LocalLLMMetadataSpy(responses: [metadata, metadata])
        let discovered = try await HuggingFaceGGUFDiscovery(transport: transport).discover(
            repository: model.repository, filename: model.filename
        )
        XCTAssertEqual(discovered, model)
        let urls = await transport.requests()
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].absoluteString.hasSuffix("/revision/main?blobs=true"))
        XCTAssertTrue(urls[1].absoluteString.hasSuffix("/revision/\(model.revision)?blobs=true"))
    }

    func testMetadataDigestDriftFailsInsteadOfChangingThePinnedPayload() async throws {
        let model = try LocalLLMFixture.model()
        let transport = LocalLLMMetadataSpy(responses: [
            try LocalLLMFixture.metadata(model),
            try LocalLLMFixture.metadata(model, digest: String(repeating: "0", count: 64))
        ])
        do {
            _ = try await HuggingFaceGGUFDiscovery(transport: transport).discover(
                repository: model.repository, filename: model.filename
            )
            XCTFail("Metadata changed between immutable reads")
        } catch let error as HuggingFaceWhisperError { XCTAssertEqual(error, .revisionChanged) }
    }

    func testOversizedMissingLFSAndCancellationRejectWithoutFurtherRequests() async throws {
        let model = try LocalLLMFixture.model()
        let oversized = Data(repeating: 32, count: HuggingFaceWhisperDiscovery.maximumMetadataBytes + 1)
        let missingLFS = try JSONSerialization.data(withJSONObject: [
            "id": model.repository, "sha": model.revision, "siblings": [["rfilename": model.filename]]
        ])
        for response in [oversized, missingLFS] {
            let transport = LocalLLMMetadataSpy(responses: [response])
            do {
                _ = try await HuggingFaceGGUFDiscovery(transport: transport).discover(
                    repository: model.repository, filename: model.filename
                )
                XCTFail("Invalid metadata accepted")
            } catch {}
            let urls = await transport.requests()
            XCTAssertEqual(urls.count, 1)
        }
        let transport = LocalLLMMetadataSpy(responses: [try LocalLLMFixture.metadata(model)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HuggingFaceGGUFDiscovery(transport: transport).discover(
                repository: model.repository, filename: model.filename
            )
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
        let urls = await transport.requests()
        XCTAssertTrue(urls.isEmpty)
    }

    func testPersistentStoreRoundTripsAndRejectsDuplicateOversizedAndCorruptState() throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try LocalLLMFixture.model()
        let store = HuggingFaceGGUFStore(directory: directory, prepareDirectory: LocalLLMFixture.prepare)
        try store.save([model])
        XCTAssertEqual(try store.load(), [model])
        XCTAssertThrowsError(try store.save([model, model]))
        XCTAssertEqual(try store.load(), [model])
        let many = try (0..<65).map { try LocalLLMFixture.model(filename: "model-\($0).gguf") }
        XCTAssertThrowsError(try store.save(many))
        try Data(repeating: 32, count: 128 * 1_024 + 1).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try Data("not JSON".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testMetadataReferenceDoesNotMarkAModelAsDownloaded() async throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try LocalLLMFixture.model()
        let service = try LocalLLMFixture.store(directory, models: [model])
        let rows = await service.rows()
        let row = try XCTUnwrap(rows.first { $0.model.id == model.id })
        XCTAssertEqual(row.state, .notInstalled)
        do {
            _ = try await service.complete(
                modelIdentifier: model.id, systemPrompt: "System", userPrompt: "User", temperature: 0
            )
            XCTFail("A reference executed without an installed model")
        } catch let error as LocalModelInstallError {
            guard case .notInstalled = error else { return XCTFail("Wrong error") }
        }
        await service.close()
    }
}
