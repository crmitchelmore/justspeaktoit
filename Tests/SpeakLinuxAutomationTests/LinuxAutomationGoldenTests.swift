import CLinuxAutomation
import Foundation
import SpeakAutomationKit
import SpeakCore
import SpeakLinuxAutomation
import SpeakTestSupport
import XCTest

/// The Linux socket transport against the golden frames every client shares.
final class LinuxAutomationGoldenTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("automation.sock").path }
    private var server: LinuxAutomationServer!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/jsti-golden-\(UUID().uuidString.prefix(12))")
        server = LinuxAutomationServer(socketPath: path, requestMilliseconds: 2_000)
        try server.start { request in
            let exchange = AutomationWireFixtures.exchanges.first { $0.request.contains("\"\(request.id)\"") }
            guard let exchange, let reply = try? Self.response(exchange) else {
                return .failure(id: request.id, command: request.command, error: .init(code: .internalError,
                                                                                       message: "No golden reply."))
            }
            return reply
        }
    }

    override func tearDownWithError() throws {
        server.stop()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func request(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationRequest {
        try AutomationCoding.decoder().decode(AutomationRequest.self, from: Data(exchange.request.utf8))
    }

    private static func response(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationResponse {
        try AutomationWireExchange.decodeResponse(Data(exchange.response.utf8))
    }

    func testGoldenRequestFrame_getsTheGoldenReplyFrameByteForByte() throws {
        for exchange in AutomationWireFixtures.exchanges {
            var connection: OpaquePointer?
            try LinuxAutomationStream.check(jsti_automation_connect(path, jsti_automation_deadline(1_000), &connection))
            let open = try XCTUnwrap(connection)
            defer { jsti_automation_close(open) }
            let stream = LinuxAutomationStream(connection: open, deadline: jsti_automation_deadline(3_000))
            try stream.writeAll(AutomationWireFixtures.frame(exchange.request))
            let prefix = try stream.readExactly(AutomationFraming.prefixLength)
            let body = try stream.readExactly(AutomationFraming.payloadLength(from: prefix))
            XCTAssertEqual(prefix + body, AutomationWireFixtures.frame(exchange.response), exchange.name)
        }
    }

    func testClient_sendsTheGoldenRequestsAndDecodesTheGoldenReplies() throws {
        let client = UnixSocketAutomationClient(socketPath: path)
        for exchange in AutomationWireFixtures.exchanges {
            let request = try Self.request(exchange)
            XCTAssertEqual(
                try AutomationWireExchange.requestFrame(for: request), AutomationWireFixtures.frame(exchange.request),
                exchange.name
            )
            XCTAssertEqual(try client.send(request), try Self.response(exchange), exchange.name)
        }
    }
}
