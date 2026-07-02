import Foundation
import XCTest

@testable import SpeakCore

final class ElevenLabsSTTAPIKeyValidatorTests: XCTestCase {
    override func tearDown() {
        ElevenLabsSTTValidationMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testValidate_probesUserThenScribeAndSucceedsOnMissingAudioResponse() async throws {
        let recorder = ElevenLabsSTTValidationRequestRecorder()
        ElevenLabsSTTValidationMockURLProtocol.handler = { request in
            await recorder.record(request)
            let path = request.url?.path
            let statusCode = path == "/v1/speech-to-text" ? 422 : 200
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let validator = ElevenLabsSTTAPIKeyValidator(session: makeMockSession())
        let result = await validator.validate("full-access-key")

        guard case .success = result.outcome else {
            return XCTFail("Expected validation success for a key with Scribe access, got \(result)")
        }

        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/user", "/v1/speech-to-text"])
        XCTAssertEqual(requests.last?.method, "POST")
        XCTAssertEqual(requests.last?.apiKeyHeader, "full-access-key")
        XCTAssertTrue(requests.last?.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertTrue(requests.last?.body?.contains(#"name="model_id""#) == true)
        XCTAssertTrue(requests.last?.body?.contains("\r\nscribe_v1\r\n") == true)
        XCTAssertFalse(requests.last?.body == "{}")
    }

    func testValidate_rejectsTTSOnlyKeyWhenScribeAccessIsForbidden() async {
        ElevenLabsSTTValidationMockURLProtocol.handler = { request in
            let statusCode = request.url?.path == "/v1/speech-to-text" ? 403 : 200
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let validator = ElevenLabsSTTAPIKeyValidator(session: makeMockSession())
        let result = await validator.validate("tts-only-key")

        guard case .failure(let message) = result.outcome else {
            return XCTFail("Expected validation failure for a TTS-only key, got \(result)")
        }
        XCTAssertTrue(message.contains("Scribe"), "Expected Scribe access guidance, got: \(message)")
        XCTAssertEqual(result.debug?.statusCode, 403)
    }

    func testValidate_acceptsUnsupportedMediaTypeAfterUserCheck() async {
        ElevenLabsSTTValidationMockURLProtocol.handler = { request in
            let statusCode = request.url?.path == "/v1/speech-to-text" ? 415 : 200
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let validator = ElevenLabsSTTAPIKeyValidator(session: makeMockSession())
        let result = await validator.validate("full-access-key")

        guard case .success = result.outcome else {
            return XCTFail("Expected validation success for a post-auth Scribe probe response, got \(result)")
        }
        XCTAssertEqual(result.debug?.statusCode, 415)
    }

    func testValidate_doesNotProbeScribeWhenUserCheckRejectsKey() async throws {
        let recorder = ElevenLabsSTTValidationRequestRecorder()
        ElevenLabsSTTValidationMockURLProtocol.handler = { request in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: request.url?.path == "/v1/user" ? 401 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let validator = ElevenLabsSTTAPIKeyValidator(session: makeMockSession())
        let result = await validator.validate("invalid-key")

        guard case .failure = result.outcome else {
            return XCTFail("Expected validation failure for an invalid key, got \(result)")
        }

        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/user"])
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevenLabsSTTValidationMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor ElevenLabsSTTValidationRequestRecorder {
    private var recordedRequests: [RecordedRequest] = []

    func record(_ request: URLRequest) {
        recordedRequests.append(
            RecordedRequest(
                path: request.url?.path,
                method: request.httpMethod,
                apiKeyHeader: request.value(forHTTPHeaderField: "xi-api-key"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: requestBody(for: request).flatMap { String(data: $0, encoding: .utf8) }
            )
        )
    }

    func requests() -> [RecordedRequest] {
        recordedRequests
    }

    private func requestBody(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data.isEmpty ? nil : data
    }
}

private struct RecordedRequest: Equatable {
    let path: String?
    let method: String?
    let apiKeyHeader: String?
    let contentType: String?
    let body: String?
}

private final class ElevenLabsSTTValidationMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("ElevenLabsSTTValidationMockURLProtocol.handler was not set")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
