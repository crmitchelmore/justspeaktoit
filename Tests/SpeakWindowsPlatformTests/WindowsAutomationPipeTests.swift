import CWindowsAutomation
import Foundation
import SpeakAutomationKit
import SpeakCore
import XCTest
@testable import SpeakWindowsPlatform

/// Loopback coverage of the `speak` named pipe: the CLI's client and the app's
/// server agree on the name, the framing and the reply.
final class WindowsAutomationPipeTests: XCTestCase {
    func testNativePipeSelfTestPasses() {
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_automation_pipe_self_test(&error, error.count)
        XCTAssertEqual(status, 0, String(cString: error))
    }

    func testClientRoundTripsThroughTheServer() throws {
        let environment = [AutomationPipeEndpoint.environmentKey: uniquePipeName()]
        let server = WindowsAutomationPipeServer(pipeName: try WindowsAutomationPipeServer.defaultPipeName(
            environment: environment
        ))
        try server.start { request in
            AutomationResponse.success(id: request.id, command: request.command, result: AutomationResult(
                sessionActive: true
            ))
        }
        defer { server.stop() }
        XCTAssertTrue(server.isRunning)

        let client = WindowsPipeAutomationClient(environment: environment)
        XCTAssertEqual(client.pipeName, server.pipeName)
        let request = AutomationRequest(id: "loopback", command: .status, timeout: 5)
        let response = try client.send(request)
        XCTAssertEqual(response.id, "loopback")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.sessionActive, true)
    }

    func testClientReportsAppUnavailableWhenNothingListens() {
        let client = WindowsPipeAutomationClient(environment: [
            AutomationPipeEndpoint.environmentKey: uniquePipeName()
        ])
        XCTAssertThrowsError(try client.send(AutomationRequest(command: .status, timeout: 1))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
        }
    }

    func testStoppedServerReleasesTheName() throws {
        let name = try WindowsAutomationPipeServer.defaultPipeName(environment: [
            AutomationPipeEndpoint.environmentKey: uniquePipeName()
        ])
        let first = WindowsAutomationPipeServer(pipeName: name)
        try first.start { AutomationResponse.success(id: $0.id, command: $0.command, result: AutomationResult()) }
        first.stop()
        XCTAssertFalse(first.isRunning)
        let second = WindowsAutomationPipeServer(pipeName: name)
        XCTAssertNoThrow(try second.start {
            AutomationResponse.success(id: $0.id, command: $0.command, result: AutomationResult())
        })
        second.stop()
    }

    private func uniquePipeName() -> String {
        AutomationPipeEndpoint.localPrefix + "speak-test-\(UUID().uuidString)"
    }
}
