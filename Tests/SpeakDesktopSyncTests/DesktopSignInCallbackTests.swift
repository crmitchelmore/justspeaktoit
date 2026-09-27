import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopSync

final class DesktopSignInCallbackTests: XCTestCase {
    func testTheCallbackModeDefaultsToLoopbackAndRefusesUnknownModes() throws {
        XCTAssertEqual(try DesktopCloudSyncSignIn.callbackMode(build: "loopback", processEnvironment: [:]), .loopback)
        XCTAssertEqual(
            try DesktopCloudSyncSignIn.callbackMode(build: "custom-scheme", processEnvironment: [:]), .customScheme
        )
        XCTAssertEqual(
            try DesktopCloudSyncSignIn.callbackMode(
                build: "loopback", processEnvironment: [DesktopCloudSyncSignIn.callbackModeVariable: "custom-scheme"]
            ),
            .customScheme
        )
        XCTAssertEqual(
            try DesktopCloudSyncSignIn.callbackMode(
                build: "loopback", processEnvironment: [DesktopCloudSyncSignIn.callbackModeVariable: "  "]
            ),
            .loopback
        )
        XCTAssertThrowsError(try DesktopCloudSyncSignIn.callbackMode(build: "https", processEnvironment: [:]))
        XCTAssertThrowsError(try DesktopCloudSyncSignIn.callbackMode(
            build: "loopback", processEnvironment: [DesktopCloudSyncSignIn.callbackModeVariable: "Loopback"]
        ))
    }

    /// The two URLs the owner registers in CloudKit Console, one per mode.
    func testEachModeNamesTheExactURLToRegister() throws {
        XCTAssertEqual(
            DesktopCloudSyncSignIn.callbackURL(for: .loopback), "http://127.0.0.1:47823/cloudkit-sign-in"
        )
        XCTAssertEqual(
            DesktopCloudSyncSignIn.callbackURL(for: .customScheme, scheme: ReleaseTrain.stable.urlScheme),
            "justspeaktoit://cloudkit-sign-in"
        )
        XCTAssertEqual(
            DesktopCloudSyncSignIn.callbackURL(for: .customScheme, scheme: ReleaseTrain.alpha.urlScheme),
            "justspeaktoit-alpha://cloudkit-sign-in"
        )
        // Apple appends ?ckWebAuthToken=… to whichever URL is registered; both
        // forms yield the same token.
        let loopback = DesktopCloudSyncSignIn.callbackURL(for: .loopback) + "?ckWebAuthToken=abc%2B1"
        let target = String(loopback.dropFirst("http://127.0.0.1:47823".count))
        XCTAssertEqual(DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: target), "abc+1")
        let custom = DesktopCloudSyncSignIn.callbackURL(for: .customScheme, scheme: "justspeaktoit")
            + "?ckWebAuthToken=abc%2B1"
        XCTAssertEqual(
            try DesktopActivationLink.parse(custom, scheme: "justspeaktoit"), .cloudKitSignIn(webAuthToken: "abc+1")
        )
    }

    func testATokenReachesTheWaitingSignIn() async throws {
        let inbox = DesktopSignInCallbackInbox()
        let ticket = inbox.open()
        XCTAssertTrue(inbox.isWaiting)
        async let token = inbox.wait(for: ticket, timeout: .seconds(30))
        try await waitUntilWaiting(inbox)
        XCTAssertTrue(inbox.deliver("first"))
        let received = try await token
        XCTAssertEqual(received, "first")
        XCTAssertFalse(inbox.isWaiting)
        XCTAssertFalse(inbox.deliver("late"), "a finished sign-in accepts nothing more")
    }

    func testACallbackBeforeTheWaitIsKeptForIt() async throws {
        let inbox = DesktopSignInCallbackInbox()
        let ticket = inbox.open()
        XCTAssertTrue(inbox.deliver("early"))
        XCTAssertFalse(inbox.deliver("second"), "only the first callback of a sign-in counts")
        let received = try await inbox.wait(for: ticket, timeout: .seconds(30))
        XCTAssertEqual(received, "early")
    }

    func testACallbackWithNoSignInWaitingIsRefused() async throws {
        let inbox = DesktopSignInCallbackInbox()
        XCTAssertFalse(inbox.deliver("unrequested"))
        let ticket = inbox.open()
        inbox.close(ticket)
        XCTAssertFalse(inbox.deliver("after close"))
        do {
            _ = try await inbox.wait(for: ticket, timeout: .seconds(30))
            XCTFail("a closed ticket must not wait")
        } catch let failure as DesktopSignInCallbackInbox.Failure {
            XCTAssertEqual(failure, .superseded)
        }
    }

    func testTheWaitEndsAtItsDeadline() async throws {
        let inbox = DesktopSignInCallbackInbox()
        let ticket = inbox.open()
        do {
            _ = try await inbox.wait(for: ticket, timeout: .milliseconds(50))
            XCTFail("the wait must time out")
        } catch let failure as DesktopSignInCallbackInbox.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        XCTAssertFalse(inbox.deliver("too late"))
    }

    func testANewSignInEndsTheEarlierWait() async throws {
        let inbox = DesktopSignInCallbackInbox()
        let first = inbox.open()
        let earlier = Task { try await inbox.wait(for: first, timeout: .seconds(30)) }
        try await waitUntilWaiting(inbox)
        let second = inbox.open()
        do {
            _ = try await earlier.value
            XCTFail("the earlier wait must end")
        } catch let failure as DesktopSignInCallbackInbox.Failure {
            XCTAssertEqual(failure, .superseded)
        }
        XCTAssertTrue(inbox.deliver("for the second"))
        let received = try await inbox.wait(for: second, timeout: .seconds(30))
        XCTAssertEqual(received, "for the second")
    }

    func testCancellingTheSignInEndsTheWait() async throws {
        let inbox = DesktopSignInCallbackInbox()
        let ticket = inbox.open()
        let waiting = Task { try await inbox.wait(for: ticket, timeout: .seconds(30)) }
        try await waitUntilWaiting(inbox)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("cancellation must end the wait")
        } catch is CancellationError {
        }
        XCTAssertFalse(inbox.isWaiting)
        XCTAssertFalse(inbox.deliver("after cancel"))
    }

    /// Waits until `wait(for:timeout:)` has registered, so a delivery exercises
    /// the waiting path rather than the early-callback one.
    private func waitUntilWaiting(_ inbox: DesktopSignInCallbackInbox) async throws {
        for _ in 0..<2_000 where !inbox.hasWaiter {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(inbox.hasWaiter)
    }
}
