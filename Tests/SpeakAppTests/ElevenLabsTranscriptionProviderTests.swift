import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class ElevenLabsTranscriptionProviderTests: XCTestCase {

    // MARK: - Registry

    func testTranscriptionProviderRegistry_includesElevenLabs() async {
        let provider = await TranscriptionProviderRegistry.shared.provider(withID: "elevenlabs")
        XCTAssertNotNil(provider)
        XCTAssertEqual(provider?.metadata.id, "elevenlabs")
    }

    func testProvider_apiKeyIdentifier_reusesElevenLabsKey() async {
        let provider = await TranscriptionProviderRegistry.shared.provider(withID: "elevenlabs")
        // Must reuse the same keychain identifier as TTS so no second credential is needed
        XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "elevenlabs.apiKey")
    }

    func testProvider_requiresAPIKey_isTrue() {
        let provider = ElevenLabsTranscriptionProvider()
        XCTAssertTrue(provider.requiresAPIKey(for: "elevenlabs/scribe_v1"))
        XCTAssertTrue(provider.requiresAPIKey(for: "elevenlabs/scribe_v1_experimental"))
    }

    // MARK: - Supported Models

    func testSupportedModels_returnsBothScribeVariants() {
        let provider = ElevenLabsTranscriptionProvider()
        let models = provider.supportedModels()
        let ids = models.map(\.id)
        XCTAssertTrue(ids.contains("elevenlabs/scribe_v1"))
        XCTAssertTrue(ids.contains("elevenlabs/scribe_v1_experimental"))
    }

    func testSupportedModels_haveNonEmptyDisplayNames() {
        let provider = ElevenLabsTranscriptionProvider()
        for model in provider.supportedModels() {
            XCTAssertFalse(model.displayName.isEmpty, "\(model.id) should have a display name")
        }
    }

    func testSupportedModels_haveEstimatedLatency() {
        let provider = ElevenLabsTranscriptionProvider()
        for model in provider.supportedModels() {
            XCTAssertNotNil(model.estimatedLatencyMs, "\(model.id) should have an estimated latency")
        }
    }

    // MARK: - ModelCatalog

    func testModelCatalog_batchTranscription_includesElevenLabsScribeV1() {
        let ids = ModelCatalog.batchTranscription.map(\.id)
        XCTAssertTrue(ids.contains("elevenlabs/scribe_v1"))
    }

    func testModelCatalog_batchTranscription_includesElevenLabsScribeV1Experimental() {
        let ids = ModelCatalog.batchTranscription.map(\.id)
        XCTAssertTrue(ids.contains("elevenlabs/scribe_v1_experimental"))
    }

    func testModelCatalog_batchTranscription_hasUniqueIDsAfterAddingElevenLabs() {
        let ids = ModelCatalog.batchTranscription.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count, "batchTranscription should have unique model IDs")
    }

    // MARK: - Transcription Request

    func testTranscribeFile_sendsCorrectAuthHeader() async throws {
        let requestObserver = RequestObserver()
        MockURLProtocol.requestHandler = { request in
            await requestObserver.store(request: request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let json = #"{"text":"hello world","language_code":"en","words":[{"text":"hello","type":"word","start":0.0,"end":0.5},{"text":"world","type":"word","start":0.6,"end":1.0}]}"#
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)

        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Use try? because AVURLAsset may fail to determine duration for synthetic test audio
        _ = try? await provider.transcribeFile(at: audioURL, apiKey: "test-key", model: "elevenlabs/scribe_v1", language: nil)

        let capturedRequest = await requestObserver.capturedRequest()
        let captured = try XCTUnwrap(capturedRequest, "Request should have been sent to ElevenLabs even when duration loading fails")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "xi-api-key"), "test-key")
    }

    func testTranscribeFile_includesLanguageCode_whenProvided() async throws {
        let requestObserver = RequestObserver()
        MockURLProtocol.requestHandler = { request in
            await requestObserver.store(request: request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let json = #"{"text":"bonjour","language_code":"fr","words":null}"#
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)

        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Use try? because AVURLAsset may fail to determine duration for synthetic test audio
        _ = try? await provider.transcribeFile(at: audioURL, apiKey: "test-key", model: "elevenlabs/scribe_v1", language: "fr_FR")

        let capturedRequest = await requestObserver.capturedRequest()
        _ = try XCTUnwrap(capturedRequest, "Request should have been sent to ElevenLabs even when duration loading fails")
        let capturedBody = await requestObserver.capturedBody()
        let body = try XCTUnwrap(capturedBody)
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("language_code"), "Body should contain language_code field")
        XCTAssertTrue(bodyString.contains("fr"), "Body should contain the extracted language code")
    }

    // MARK: - Error Paths

    func testTranscribeFile_throwsHttpError_onNon2xxResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"invalid_api_key"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)

        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await provider.transcribeFile(at: audioURL, apiKey: "bad-key", model: "elevenlabs/scribe_v1", language: nil)
            XCTFail("Expected a TranscriptionProviderError.httpError to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"), "Unexpected error: \(error)")
        }
    }

    func testTranscribeFile_throwsHttpError_on500Response() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"internal server error"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)

        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await provider.transcribeFile(at: audioURL, apiKey: "test-key", model: "elevenlabs/scribe_v1", language: nil)
            XCTFail("Expected httpError to be thrown for 500 response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"), "Unexpected error: \(error)")
        }
    }

    // MARK: - API Key Validation

    func testValidateAPIKey_returnsSuccess_on200() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)
        let result = await provider.validateAPIKey("valid-key")

        if case .success = result.outcome {
            // pass
        } else {
            XCTFail("Expected validation success for 200 response")
        }
    }

    func testValidateAPIKey_returnsFailure_onEmptyKey() async {
        let provider = ElevenLabsTranscriptionProvider()
        let result = await provider.validateAPIKey("")
        if case .failure = result.outcome {
            // pass
        } else {
            XCTFail("Expected validation failure for empty key")
        }
    }

    func testValidateAPIKey_returnsFailure_on401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let session = makeMockSession()
        let provider = ElevenLabsTranscriptionProvider(session: session)
        let result = await provider.validateAPIKey("invalid-key")

        if case .failure = result.outcome {
            // pass
        } else {
            XCTFail("Expected validation failure for 401 response")
        }
    }

    // MARK: - Helpers

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSilentAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audio_\(UUID().uuidString).m4a")
        // Write minimal valid-looking data so Data(contentsOf:) succeeds
        try Data("fakeaudiodata".utf8).write(to: url)
        return url
    }
}

// MARK: - Test Infrastructure

private actor RequestObserver {
    private(set) var request: URLRequest?
    private(set) var body: Data?

    func store(request: URLRequest) {
        self.request = request
        body = request.httpBody ?? readBody(from: request.httpBodyStream)
    }

    func capturedRequest() -> URLRequest? {
        request
    }

    func capturedBody() -> Data? {
        body
    }

    private func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data.isEmpty ? nil : data
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MockURLProtocol.requestHandler was not set")
            return
        }

        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
