import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

enum LocalLLMFixture {
    static let revision = String(repeating: "a", count: 40)
    static let repository = "example/cleanup"
    static let filename = "cleanup-Q4_K_M.gguf"
    static let bytes = Data(Array("GGUF".utf8) + [3, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 87))
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func model(
        repository: String = repository, filename: String = filename,
        revision: String = revision, bytes: Data = bytes
    ) throws -> HuggingFaceGGUFModel {
        try .init(
            repository: repository, filename: filename, revision: revision, byteCount: Int64(bytes.count),
            sha256: TestSHA256.hex(bytes), license: "MIT"
        )
    }
    static func metadata(_ model: HuggingFaceGGUFModel, digest: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": model.repository, "sha": model.revision, "cardData": ["license": model.license],
            "siblings": [[
                "rfilename": model.filename, "size": model.byteCount,
                "lfs": ["size": model.byteCount, "sha256": digest ?? model.sha256]
            ]]
        ])
    }
    static func store(
        _ directory: URL, models: [HuggingFaceGGUFModel],
        transport: FakeModelTransport = FakeModelTransport(body: bytes),
        runtime: LocalLLMRuntimeSpy = LocalLLMRuntimeSpy()
    ) throws -> DesktopLocalLLMStore {
        try HuggingFaceGGUFStore(directory: directory, prepareDirectory: prepare).save(models)
        return try .init(
            directory: directory, digests: TestSHA256.provider, transport: transport,
            metadataTransport: LocalLLMMetadataSpy(responses: try models.prefix(1).map { try metadata($0) }),
            runtime: runtime, prepareDirectory: prepare
        )
    }
}

actor LocalLLMMetadataSpy: HuggingFaceModelMetadataTransport {
    private let responses: [Data]
    private let failure: Bool
    private var urls: [URL] = []
    init(responses: [Data], failure: Bool = false) { self.responses = responses; self.failure = failure }
    func metadata(at url: URL) async throws -> Data {
        urls.append(url)
        try Task.checkCancellation()
        if failure { throw URLError(.cannotConnectToHost) }
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return responses[min(urls.count - 1, responses.count - 1)]
    }
    func requests() -> [URL] { urls }
}

actor LocalLLMEngineSpy: DesktopLocalLLMEngine {
    struct Request: Sendable {
        let model: String
        let system: String
        let user: String
        let temperature: Double
    }
    private var values: [Request] = []
    private let output: String
    private let failure: LocalLLMError?
    init(output: String = "Cleaned transcript.", failure: LocalLLMError? = nil) {
        self.output = output; self.failure = failure
    }
    func complete(
        modelIdentifier: String, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        values.append(.init(model: modelIdentifier, system: systemPrompt, user: userPrompt, temperature: temperature))
        if let failure { throw failure }
        return output
    }
    func requests() -> [Request] { values }
}

/// Cancellation deliberately does not release this fake worker. Tests must
/// prove that a cancelled owner retains its file lease until actual teardown.
actor LocalLLMRuntimeSpy: DesktopLocalLLMRuntime {
    let entered = XCTestExpectation(description: "native worker admitted")
    let cancelled = XCTestExpectation(description: "native cancellation forwarded")
    private let held: Bool
    private let failure: LocalModelInstallError?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(held: Bool = false, failure: LocalModelInstallError? = nil) { self.held = held; self.failure = failure }
    func complete(
        model: HuggingFaceGGUFModel, file: URL, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        XCTAssertEqual(try Data(contentsOf: file), LocalLLMFixture.bytes)
        entered.fulfill()
        if held {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { gate = continuation }
                }
            } onCancel: { cancelled.fulfill() }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        return "Cleaned transcript."
    }
    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
