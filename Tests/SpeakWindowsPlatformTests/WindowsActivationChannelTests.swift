import CWindowsAutomation
import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakWindowsPlatform

/// Loopback coverage of single-instance link forwarding: the first window owns
/// the activation pipe, a second launch finds it in use and hands its link over
/// on the same framing, and nothing else reaches the handler.
final class WindowsActivationChannelTests: XCTestCase {
    func testASecondLaunchForwardsItsLinkToTheFirstWindow() throws {
        let name = try pipeName()
        let received = LinkRecorder()
        let first = WindowsActivationServer(pipeName: name)
        XCTAssertEqual(try first.start { link in
            received.append(link)
            return .accepted
        }, .listening)
        defer { first.stop() }

        let second = WindowsActivationServer(pipeName: name)
        XCTAssertEqual(try second.start { _ in .accepted }, .anotherInstanceIsRunning)
        XCTAssertFalse(second.isRunning)

        let link = "justspeaktoit://cloudkit-sign-in?ckWebAuthToken=abc%2Bdef"
        XCTAssertEqual(try WindowsActivationServer.forward(link, pipeName: name), .accepted)
        XCTAssertEqual(try WindowsActivationServer.forward("justspeaktoit://start", pipeName: name), .accepted)
        XCTAssertEqual(received.links, [link, "justspeaktoit://start"], "links arrive whole and in order")
    }

    func testTheWindowsAnswerReachesTheLaunch() throws {
        let name = try pipeName()
        let server = WindowsActivationServer(pipeName: name)
        _ = try server.start { _ in .refused }
        defer { server.stop() }
        XCTAssertEqual(try WindowsActivationServer.forward("justspeaktoit://openclaw", pipeName: name), .refused)
    }

    func testAForgedFrameIsRefusedWithoutReachingTheHandler() throws {
        let name = try pipeName()
        let received = LinkRecorder()
        let server = WindowsActivationServer(pipeName: name)
        _ = try server.start { link in
            received.append(link)
            return .accepted
        }
        defer { server.stop() }

        var connection: OpaquePointer?
        XCTAssertEqual(jsti_automation_pipe_connect(name, 5_000, &connection, nil, 0), JSTI_AUTOMATION_PIPE_OK.rawValue)
        let pipe = try XCTUnwrap(connection)
        defer { jsti_automation_pipe_close(pipe) }
        var forged: [UInt8] = Array("JSTB".utf8) + [1, 0, 0, 0, 4] + Array("open".utf8)
        XCTAssertEqual(jsti_automation_pipe_write(pipe, &forged, forged.count, 5_000, nil, 0),
                       JSTI_AUTOMATION_PIPE_OK.rawValue)
        var reply: UInt8 = 0
        XCTAssertEqual(jsti_automation_pipe_read(pipe, &reply, 1, 5_000, nil, 0), JSTI_AUTOMATION_PIPE_OK.rawValue)
        XCTAssertEqual(reply, DesktopActivationFrame.Reply.malformed.rawValue)
        XCTAssertEqual(received.links, [])
    }

    func testForwardingWithNoWindowRunningFailsVisibly() throws {
        let name = try pipeName()
        XCTAssertThrowsError(try WindowsActivationServer.forward("justspeaktoit://", pipeName: name,
                                                                 timeoutMilliseconds: 500)) { error in
            XCTAssertEqual((error as? WindowsActivationError)?.status, JSTI_AUTOMATION_PIPE_NOT_FOUND.rawValue)
        }
    }

    func testAStoppedWindowReleasesThePipe() throws {
        let name = try pipeName()
        let first = WindowsActivationServer(pipeName: name)
        _ = try first.start { _ in .accepted }
        first.stop()
        first.stop()
        let next = WindowsActivationServer(pipeName: name)
        XCTAssertEqual(try next.start { _ in .accepted }, .listening)
        next.stop()
    }

    func testTheDefaultPipeIsThisUsersActivationPipe() throws {
        let name = try WindowsActivationServer.defaultPipeName(environment: [:])
        XCTAssertTrue(name.hasPrefix(#"\\.\pipe\JustSpeakToIt-"#))
        XCTAssertTrue(name.contains("-activation-S-1-"))
    }

    private func pipeName() throws -> String {
        try WindowsActivationServer.defaultPipeName(environment: [
            DesktopActivationEndpoint.environmentKey: "jsti-activation-test-\(UUID().uuidString)"
        ])
    }
}

private final class LinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ link: String) { lock.withLock { stored.append(link) } }
    var links: [String] { lock.withLock { stored } }
}
