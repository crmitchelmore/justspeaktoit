import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakAutomationKit

/// The golden frames every client transport is held to. Platform transports
/// replay the same fixtures through their own sockets and pipes.
final class AutomationWireGoldenTests: XCTestCase {
    func testGoldenRequests_areTheClientsExactFrames() throws {
        for exchange in AutomationWireFixtures.exchanges {
            let request = try AutomationWireGolden.request(exchange)
            XCTAssertEqual(
                try AutomationWireExchange.requestFrame(for: request), AutomationWireFixtures.frame(exchange.request),
                exchange.name
            )
        }
    }

    func testGoldenRequests_carryTheArgumentsTheyName() throws {
        var expected = AutomationRequest(id: "golden-say", command: .speakText, path: "/srv/out.wav", timeout: 30)
        expected.text = "Hello \"there\""
        expected.voice = "alloy"
        expected.provider = "openai"
        expected.speed = 1.25
        expected.pitch = -2
        expected.play = true
        XCTAssertEqual(try AutomationWireGolden.request(AutomationWireFixtures.speech), expected)
        let history = try AutomationWireGolden.request(AutomationWireFixtures.history)
        XCTAssertEqual(history, AutomationRequest(id: "golden-history", command: .history, limit: 2, timeout: 5))
    }

    func testGoldenReplies_areTheServersExactFrames() throws {
        for exchange in AutomationWireFixtures.exchanges {
            let response = try AutomationWireGolden.response(exchange)
            XCTAssertEqual(
                AutomationWireExchange.responseFrame(for: response), AutomationWireFixtures.frame(exchange.response),
                exchange.name
            )
        }
    }

    func testGoldenReplies_decodeFromTheStream() throws {
        for exchange in AutomationWireFixtures.exchanges {
            let stream = ReplayStream(AutomationWireFixtures.frame(exchange.response))
            let response = try AutomationWireExchange.readResponse(from: stream)
            XCTAssertEqual(response, try AutomationWireGolden.response(exchange), exchange.name)
            XCTAssertTrue(stream.isDrained, exchange.name)
        }
        let speech = try AutomationWireGolden.response(AutomationWireFixtures.speech)
        XCTAssertEqual(speech.error?.code, .invalidArgument)
        let history = try AutomationWireGolden.response(AutomationWireFixtures.history)
        XCTAssertEqual(history.result?.entries?.first?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testFutureSchemaReply_isRefused() {
        let stream = ReplayStream(AutomationWireFixtures.frame(AutomationWireFixtures.futureSchemaResponse))
        XCTAssertThrowsError(try AutomationWireExchange.readResponse(from: stream)) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .schemaMismatch)
        }
    }

    #if canImport(Darwin)
    /// The Mac client writes exactly the golden frame to a real socket and
    /// reads the golden reply back.
    func testUnixSocketClient_exchangesTheGoldenFrames() throws {
        for exchange in AutomationWireFixtures.exchanges {
            let server = try GoldenSocketServer(reply: AutomationWireFixtures.frame(exchange.response))
            defer { server.stop() }
            let client = UnixSocketAutomationClient(socketPath: server.path)
            let response = try client.send(try AutomationWireGolden.request(exchange))
            XCTAssertEqual(response, try AutomationWireGolden.response(exchange), exchange.name)
            XCTAssertEqual(server.received(), AutomationWireFixtures.frame(exchange.request), exchange.name)
        }
    }
    #endif
}

/// Decodes a golden body with the production decoder.
enum AutomationWireGolden {
    static func request(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationRequest {
        try AutomationCoding.decoder().decode(AutomationRequest.self, from: Data(exchange.request.utf8))
    }

    static func response(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationResponse {
        try AutomationWireExchange.decodeResponse(Data(exchange.response.utf8))
    }
}

/// A byte stream that replays one recorded reply.
private final class ReplayStream: AutomationByteStream {
    private var bytes: Data

    init(_ bytes: Data) { self.bytes = bytes }

    var isDrained: Bool { self.bytes.isEmpty }

    func readExactly(_ count: Int) throws -> Data {
        guard count <= self.bytes.count else { throw AutomationError(code: .internalError, message: "Short read.") }
        defer { self.bytes.removeFirst(count) }
        return Data(self.bytes.prefix(count))
    }

    func writeAll(_ data: Data) throws {}
}

#if canImport(Darwin)
/// One-shot UNIX socket server: records the request frame and writes `reply`.
private final class GoldenSocketServer: @unchecked Sendable {
    let path = NSTemporaryDirectory() + "speak-golden-\(UUID().uuidString.prefix(8)).sock"
    private let descriptor: Int32
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var request = Data()

    init(reply: Data) throws {
        self.descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, self.path, capacity) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(self.descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(self.descriptor, 1) == 0 else {
            close(self.descriptor)
            throw AutomationError(code: .internalError, message: "Golden socket could not listen.")
        }
        Thread.detachNewThread { [self] in self.serve(reply: reply) }
    }

    private func serve(reply: Data) {
        defer { self.done.signal() }
        let connection = accept(self.descriptor, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        guard let prefix = Self.read(connection, count: 4),
              let length = try? AutomationFraming.payloadLength(from: prefix),
              let body = Self.read(connection, count: length) else { return }
        self.lock.withLock { self.request = prefix + body }
        reply.withUnsafeBytes { _ = write(connection, $0.baseAddress, $0.count) }
    }

    private static func read(_ connection: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let received = Darwin.read(connection, &buffer, count - data.count)
            guard received > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(received))
        }
        return data
    }

    func received() -> Data {
        _ = self.done.wait(timeout: .now() + 5)
        return self.lock.withLock { self.request }
    }

    /// Wakes an accept that never received a client; never waits for it.
    func stop() {
        shutdown(self.descriptor, SHUT_RDWR)
        close(self.descriptor)
        unlink(self.path)
    }
}
#endif
