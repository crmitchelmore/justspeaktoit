#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation

/// Test-only transport gate. Unlike the common canned-response stub, it can
/// release a held final byte and EOF after actual decoder output is observed.
final class ProgressiveSpeechResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private let status: Int
    private let mime: String
    private let holdLastByte: Bool
    private let onStop: (@Sendable () -> Void)?
    private weak var connection: ProgressiveSpeechTestProtocol?
    private var released = false
    private var requests = 0

    init(bytes: Data, status: Int, mime: String, holdLastByte: Bool, onStop: (@Sendable () -> Void)?) {
        self.bytes = bytes
        self.status = status
        self.mime = mime
        self.holdLastByte = holdLastByte
        self.onStop = onStop
    }

    var requestCount: Int { lock.withLock { requests } }

    func start(_ connection: ProgressiveSpeechTestProtocol) {
        let held = lock.withLock {
            self.connection = connection
            requests += 1
            return holdLastByte && !released
        }
        let response = HTTPURLResponse(
            url: connection.request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": mime, "Content-Length": String(bytes.count)]
        )!
        connection.deliver(response, bytes: held ? Data(bytes.dropLast()) : bytes, finish: !held)
    }

    func release() {
        let owned: ProgressiveSpeechTestProtocol? = lock.withLock {
            guard holdLastByte, !released else { return nil }
            released = true
            return connection
        }
        owned?.deliver(nil, bytes: Data(bytes.suffix(1)), finish: true)
    }

    func stopped(_ connection: ProgressiveSpeechTestProtocol) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            guard self.connection === connection else { return nil }
            self.connection = nil
            return onStop
        }
        callback?()
    }
}

final class ProgressiveSpeechTestProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: ProgressiveSpeechResponse] = [:]
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    private var fixture: ProgressiveSpeechResponse?

    static func install(_ response: ProgressiveSpeechResponse, id: String) {
        registryLock.withLock { fixtures[id] = response }
    }

    static func remove(_ id: String) { _ = registryLock.withLock { fixtures.removeValue(forKey: id) } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.registryLock.withLock {
            request.value(forHTTPHeaderField: "X-Speech-Fixture").flatMap { Self.fixtures[$0] }
        }
        let admitted = deliveryLock.withLock {
            guard !stopped else { return false }
            fixture = response
            return true
        }
        guard admitted else { return }
        guard let response else {
            deliveryLock.withLock {
                guard !stopped else { return }
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            }
            return
        }
        response.start(self)
    }

    override func stopLoading() {
        let response = deliveryLock.withLock { () -> ProgressiveSpeechResponse? in
            guard !stopped else { return nil }
            stopped = true
            return fixture
        }
        response?.stopped(self)
    }

    func deliver(_ response: URLResponse?, bytes: Data, finish: Bool) {
        deliveryLock.withLock {
            guard !stopped else { return }
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            guard !stopped else { return }
            if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
            guard !stopped else { return }
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }
}
#endif
