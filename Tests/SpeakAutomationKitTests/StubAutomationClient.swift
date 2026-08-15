import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// Records what it was asked and replays a scripted reply, so CLI and MCP
/// behaviour can be asserted without a running app.
final class StubAutomationClient: AutomationRequesting {
    private(set) var sentRequests: [AutomationRequest] = []
    var responder: (AutomationRequest) throws -> AutomationResponse

    init(responder: @escaping (AutomationRequest) throws -> AutomationResponse) {
        self.responder = responder
    }

    convenience init(result: AutomationResult) {
        self.init { request in
            .success(id: request.id, command: request.command, result: result)
        }
    }

    convenience init(failure: AutomationError) {
        self.init { request in
            .failure(id: request.id, command: request.command, error: failure)
        }
    }

    convenience init(throwing error: AutomationError) {
        self.init { _ in throw error }
    }

    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        self.sentRequests.append(request)
        return try self.responder(request)
    }
}

extension StubAutomationClient {
    static let unavailable = AutomationError.appUnavailable(socketPath: "/tmp/speak-test.sock")
}
