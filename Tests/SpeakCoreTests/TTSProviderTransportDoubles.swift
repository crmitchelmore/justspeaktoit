import Foundation
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

final class TTSTransportMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var recorded: URLRequest?
    private static let lock = NSLock()

    static var requestHandler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            handler = newValue
        }
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        recorded = nil
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` is stripped from the request the protocol receives, so the
        // body stream is read back before the request is recorded.
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.readBody(from: stream)
        }
        Self.lock.lock()
        Self.recorded = request
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
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
        configuration.protocolClasses = [TTSTransportMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func stub(statusCode: Int, body: Data) {
        TTSTransportMockURLProtocol.requestHandler = { request in
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
        let data = try XCTUnwrap(request.httpBody)
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
