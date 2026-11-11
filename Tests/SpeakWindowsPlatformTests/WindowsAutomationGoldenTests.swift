import Foundation
import SpeakAutomationKit
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakWindowsPlatform

/// The named-pipe transport against the golden frames every client shares.
final class WindowsAutomationGoldenTests: XCTestCase {
    private static func request(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationRequest {
        try AutomationCoding.decoder().decode(AutomationRequest.self, from: Data(exchange.request.utf8))
    }

    private static func response(_ exchange: AutomationWireFixtures.Exchange) throws -> AutomationResponse {
        try AutomationWireExchange.decodeResponse(Data(exchange.response.utf8))
    }

    /// Windows Foundation must encode the frames byte for byte as Darwin and
    /// Linux do, including numbers, escapes and dates.
    func testFrames_matchTheGoldenBytes() throws {
        for exchange in AutomationWireFixtures.exchanges {
            XCTAssertEqual(
                try AutomationWireExchange.requestFrame(for: Self.request(exchange)),
                AutomationWireFixtures.frame(exchange.request), exchange.name
            )
            XCTAssertEqual(
                AutomationWireExchange.responseFrame(for: try Self.response(exchange)),
                AutomationWireFixtures.frame(exchange.response), exchange.name
            )
        }
    }

    func testClient_exchangesTheGoldenFramesThroughThePipe() throws {
        let name = AutomationPipeEndpoint.localPrefix + "speak-golden-\(UUID().uuidString)"
        let environment = [AutomationPipeEndpoint.environmentKey: name]
        let server = WindowsAutomationPipeServer(pipeName: try WindowsAutomationPipeServer.defaultPipeName(
            environment: environment
        ))
        try server.start { request in
            let exchange = AutomationWireFixtures.exchanges.first { $0.request.contains("\"\(request.id)\"") }
            guard let exchange, let reply = try? Self.response(exchange) else {
                return .failure(id: request.id, command: request.command, error: .init(code: .internalError,
                                                                                       message: "No golden reply."))
            }
            return reply
        }
        defer { server.stop() }
        let client = WindowsPipeAutomationClient(environment: environment)
        for exchange in AutomationWireFixtures.exchanges {
            XCTAssertEqual(try client.send(Self.request(exchange)), try Self.response(exchange), exchange.name)
        }
    }
}
