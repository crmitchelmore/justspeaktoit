import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// The settings surfaces' copied MCP entry must name the server `speak mcp` reports.
final class AutomationClientSetupParityTests: XCTestCase {
    func testMCPServerName_MatchesTheCopiedClientConfiguration() {
        XCTAssertEqual(MCPRequestHandler.serverName, AutomationClientSetup.mcpServerName)
        XCTAssertTrue(
            AutomationClientSetup.mcpConfiguration(command: "speak").contains("\"\(MCPRequestHandler.serverName)\"")
        )
    }
}
