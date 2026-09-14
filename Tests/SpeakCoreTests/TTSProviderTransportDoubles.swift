import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

/// Shared stubs for the September 2026 speech-provider transport tests.
/// Counts how many times a stub was asked for a response, so a retry is visible.
final class TTSTransportCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

func XCTAssertTTSThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

/// Request stubbing shared by the speech-provider transport suites.
enum TTSTransportStub {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func stub(statusCode: Int, body: Data) {
        StubURLProtocol.respond {  request in
            (response(for: request, statusCode: statusCode), body)
        }
    }

    static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? GroqTTSAPI.speechEndpoint,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    static func body(of request: URLRequest) throws -> [String: Any] {
        // URLSession hands the protocol a body stream rather than `httpBody`,
        // so the bytes are read back through the shared stub's accessor.
        let data = StubURLProtocol.body(of: request)
        XCTAssertFalse(data.isEmpty, "Expected a request body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One interaction response carrying headerless 24 kHz mono PCM.
    static func geminiAudioResponse() -> Data {
        let pcm = Data(repeating: 0x02, count: 32).base64EncodedString()
        return Data(
            """
            {"steps":[{"content":[{"type":"audio","data":"\(pcm)",\
            "mime_type":"audio/l16","sample_rate":24000,"channels":1}]}]}
            """.utf8
        )
    }
}
