import Foundation
import XCTest
@testable import SpeakCore

final class SonioxTTSAPIContractTests: XCTestCase {
    override func tearDown() {
        SonioxTTSMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSynthesis_UsesSelectedRegionalRESTHostAndBearerHeader() async throws {
        let recorder = SonioxTTSRequestRecorder()
        SonioxTTSMockURLProtocol.handler = { request in
            await recorder.record(request)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("audio".utf8)
            )
        }
        let request = SonioxTTSRequest(
            language: "en",
            voice: SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel),
            audioFormat: .mp3
        )

        _ = try await SonioxTTSAPI(session: mockSession(), region: .europe)
            .synthesize(text: "Hello", apiKey: "placeholder", request: request)

        let captured = await recorder.request()
        XCTAssertEqual(captured?.url?.host, "tts-rt.eu.soniox.com")
        XCTAssertEqual(captured?.url?.path, "/tts")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// A gateway can refuse the key with a body the app cannot classify. The
    /// status code must still reach the caller so it can name the real cause.
    func testRefusedKey_ReportsTheStatusCodeWithAnUnrecognisedBody() async {
        SonioxTTSMockURLProtocol.handler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("<html>Forbidden</html>".utf8)
            )
        }
        let request = SonioxTTSRequest(
            language: "en",
            voice: SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel),
            audioFormat: .mp3
        )

        do {
            _ = try await SonioxTTSAPI(session: mockSession())
                .synthesize(text: "Hello", apiKey: "placeholder", request: request)
            XCTFail("Expected the refused key to raise an error")
        } catch let SonioxTTSAPIError.apiFailure(failure) {
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertEqual(failure.type, .unknown("unknown"))
            XCTAssertTrue(failure.isAuthenticationFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidation_UsesSelectedRegionalAPIHost() async {
        let recorder = SonioxTTSRequestRecorder()
        SonioxTTSMockURLProtocol.handler = { request in
            await recorder.record(request)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"models":[]}"#.utf8)
            )
        }

        _ = await SonioxTTSAPI(session: mockSession(), region: .japan).validateAPIKey("placeholder")

        let captured = await recorder.request()
        XCTAssertEqual(captured?.url?.host, "api.jp.soniox.com")
        XCTAssertEqual(captured?.url?.path, "/v1/tts-models")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder")
    }

    func testAccountVoiceDiscovery_FollowsCursorAndUsesRegionalAPIHost() async throws {
        let recorder = SonioxTTSRequestRecorder()
        SonioxTTSMockURLProtocol.handler = { request in
            await recorder.record(request)
            let cursor = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            let body = cursor == nil
                ? #"{"voices":[],"next_page_cursor":"next"}"#
                : #"{"voices":[],"next_page_cursor":null}"#
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(body.utf8)
            )
        }

        _ = try await SonioxTTSAPI(session: mockSession(), region: .europe)
            .listAccountVoices(apiKey: "placeholder")

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.eu.soniox.com" })
        let finalURL = try XCTUnwrap(requests.last?.url)
        XCTAssertEqual(
            URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value,
            "next"
        )
    }

    func testAccountVoiceDiscovery_StopsWhenCursorRepeats() async throws {
        let recorder = SonioxTTSRequestRecorder()
        SonioxTTSMockURLProtocol.handler = { request in
            await recorder.record(request)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"voices":[],"next_page_cursor":"repeated"}"#.utf8)
            )
        }

        _ = try await SonioxTTSAPI(session: mockSession())
            .listAccountVoices(apiKey: "placeholder")

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SonioxTTSMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor SonioxTTSRequestRecorder {
    private var recorded: [URLRequest] = []

    func record(_ request: URLRequest) { recorded.append(request) }
    func request() -> URLRequest? { recorded.last }
    func requests() -> [URLRequest] { recorded }
}

private final class SonioxTTSMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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
