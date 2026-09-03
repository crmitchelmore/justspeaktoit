import Foundation
import XCTest

@testable import SpeakCore

/// Network-facing behaviour of Meta's dedicated file-transcription endpoint:
/// key validation, result parsing, error mapping, and cancellation.
final class MetaMuseBatchClientTests: XCTestCase {
    override func tearDown() {
        MetaMuseMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testAPIKeyValidation_probesSpeechEndpointAndMapsAuthFailure() async throws {
        MetaMuseMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"message":"invalid token"}"#.utf8))
        }
        let result = await MetaMuseAPIKeyValidator(session: makeMockSession()).validate("invalid")

        guard case .failure(let message) = result.outcome else {
            return XCTFail("Expected key validation failure")
        }
        XCTAssertTrue(message.contains("rejected the API key"))
    }

    func testBatchClient_convertsSupportedFileUploadsAndDecodesTurns() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/asr/transcribe")
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                #"""
                {
                  "sessionId":"session-1",
                  "transcript":"Hello world.",
                  "audioDurationMs":100,
                  "turns":[
                    {"turnId":1,"startMs":0,"endMs":100,"transcript":"Hello world.","speaker":null}
                  ]
                }
                """#.utf8
            )
            return (response, body)
        }

        let result = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
            at: audioURL,
            apiKey: "valid",
            language: "en-GB",
            keywords: ["JustSpeakToIt"]
        )

        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.duration, 0.1, accuracy: 0.001)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.startTime, 0)
        XCTAssertEqual(result.segments.first?.endTime, 0.1)
    }

    func testBatchClient_honoursCancellationBeforeUpload() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task {
            try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
                at: audioURL,
                apiKey: "valid",
                language: nil
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }
    func testBatchClient_requiresAPIKeyBeforeTouchingTheNetwork() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { _ in
            XCTFail("A blank key must never reach the network")
            throw URLError(.badServerResponse)
        }

        do {
            _ = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
                at: audioURL,
                apiKey: "   ",
                language: nil
            )
            XCTFail("Expected a missing-key failure")
        } catch let error as MetaMuseError {
            XCTAssertEqual(error, .missingAPIKey)
        }
    }

    func testBatchClient_mapsRateLimitResponse() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"message":"too many streams"}"#.utf8))
        }

        do {
            _ = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
                at: audioURL,
                apiKey: "valid",
                language: nil
            )
            XCTFail("Expected a rate-limit failure")
        } catch let error as MetaMuseError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testBatchClient_mapsMalformedSuccessBodyToInvalidResponse() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"unexpected":true}"#.utf8))
        }

        do {
            _ = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
                at: audioURL,
                apiKey: "valid",
                language: nil
            )
            XCTFail("Expected an invalid-response failure")
        } catch let error as MetaMuseError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testBatchClient_fallsBackToASingleSegmentWhenNoTurnsAreReturned() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                #"{"sessionId":"s","transcript":"Hello.","audioDurationMs":250,"turns":[]}"#.utf8
            )
            return (response, body)
        }

        let result = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
            at: audioURL,
            apiKey: "valid",
            language: nil
        )

        XCTAssertEqual(result.text, "Hello.")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.endTime, 0.25)
        XCTAssertEqual(result.modelIdentifier, MetaMuseVoiceTranscribe.batchCatalogID)
    }

    func testBatchClient_labelsDiarizedTurnsWithTheirSpeaker() async throws {
        let audioURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        MetaMuseMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                #"""
                {
                  "sessionId":"s","transcript":"Hi. Hello.","audioDurationMs":900,
                  "turns":[
                    {"turnId":1,"startMs":0,"endMs":400,"transcript":"Hi.","speaker":"A"},
                    {"turnId":2,"startMs":500,"endMs":900,"transcript":"Hello.","speaker":"B"}
                  ]
                }
                """#.utf8
            )
            return (response, body)
        }

        let result = try await MetaMuseBatchClient(session: makeMockSession()).transcribeFile(
            at: audioURL,
            apiKey: "valid",
            language: nil
        )

        XCTAssertEqual(result.segments.map(\.text), ["Speaker A: Hi.", "Speaker B: Hello."])
    }
    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetaMuseMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryWAV(sampleRate: Int = 16_000) throws -> URL {
        let pcm = Data(repeating: 0, count: sampleRate / 5)
        let data = MetaMuseAudioPreparer.wavData(pcm: pcm, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-muse-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private class MetaMuseMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task {
            do {
                guard let handler = Self.handler else {
                    throw URLError(.badServerResponse)
                }
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
