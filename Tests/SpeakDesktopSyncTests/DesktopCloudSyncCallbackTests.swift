import Foundation
import SpeakDesktopSync
import XCTest

/// The loopback sign-in callback cannot carry a per-attempt value (Apple
/// appends only `ckWebAuthToken`), so it is accepted only from this user's
/// processes and only as the top-level browser navigation Apple's redirect is.
final class DesktopCloudSyncCallbackTests: XCTestCase {
    private typealias SignIn = DesktopCloudSyncSignIn
    private let target = "/cloudkit-sign-in?ckWebAuthToken=abc%2Bdef%3D"

    private func head(
        _ fields: [(String, String)] = [("Host", "127.0.0.1:47823")],
        method: String = "GET",
        target: String? = nil
    ) -> DesktopLoopbackRequestHead {
        DesktopLoopbackRequestHead(
            method: method, target: target ?? self.target,
            fields: fields.map { DesktopLoopbackRequestHead.Field(name: $0.0, value: $0.1) }
        )
    }

    /// What Chromium and Firefox send when Apple's page redirects the tab.
    private var browserRedirect: [(String, String)] {
        [
            ("Host", "127.0.0.1:47823"), ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate"),
            ("Sec-Fetch-Dest", "document"), ("Upgrade-Insecure-Requests", "1")
        ]
    }

    // MARK: - Request head

    func testTheRequestHeadIsParsedAndMalformedHeadsAreRejected() throws {
        let raw = "GET /cloudkit-sign-in?ckWebAuthToken=t HTTP/1.1\r\nHost: 127.0.0.1:47823\r\n"
            + "sec-fetch-mode:navigate\r\nReferer:  https://idmsa.apple.com/ \r\nReferer: https://x.example\r\n\r\nbody"
        let parsed = try XCTUnwrap(DesktopLoopbackRequestHead(parsing: Data(raw.utf8)))
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.target, "/cloudkit-sign-in?ckWebAuthToken=t")
        XCTAssertEqual(parsed.values("host"), ["127.0.0.1:47823"])
        XCTAssertEqual(parsed.values("Sec-Fetch-Mode"), ["navigate"])
        XCTAssertEqual(parsed.values("REFERER"), ["https://idmsa.apple.com/", "https://x.example"])
        XCTAssertEqual(parsed.values("Origin"), [])

        for malformed in [
            "GET /cloudkit-sign-in HTTP/1.1 extra\r\n\r\n", "GET /cloudkit-sign-in\r\n\r\n", "\r\n\r\n",
            "GET /cloudkit-sign-in FTP/1.0\r\n\r\n", "GET /cloudkit-sign-in HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n",
            "GET /cloudkit-sign-in HTTP/1.1\r\nReferer: https://a.example\r\n folded\r\n\r\n",
            "GET /cloudkit-sign-in HTTP/1.1\r\nBad Name: x\r\n\r\n"
        ] {
            XCTAssertNil(DesktopLoopbackRequestHead(parsing: Data(malformed.utf8)), malformed)
        }
    }

    // MARK: - Accepted

    func testApplesRedirectFromThisUsersBrowserIsAccepted() {
        let accepted = SignIn.CallbackDecision.accept(webAuthToken: "abc+def=")
        XCTAssertEqual(SignIn.evaluateCallback(head(browserRedirect), peer: .currentUser), accepted)
        // No fetch metadata (older Safari, or a non-browser client of this user).
        XCTAssertEqual(SignIn.evaluateCallback(head(), peer: .currentUser), accepted)
        XCTAssertEqual(SignIn.evaluateCallback(head([("host", "127.0.0.1")]), peer: .currentUser), accepted)
        // The address typed or pasted into the browser.
        XCTAssertEqual(
            SignIn.evaluateCallback(
                head([("Host", "127.0.0.1:47823"), ("Sec-Fetch-Site", "none"), ("Sec-Fetch-Mode", "navigate")]),
                peer: .currentUser
            ),
            accepted
        )
        // Apple's pages as the initiator, if its referrer policy sends one.
        for initiator in [("Referer", "https://idmsa.apple.com/"), ("Origin", "https://appleid.apple.com"),
                          ("Referer", "https://www.icloud.com/x?y"), ("referer", "https://apple.com")] {
            XCTAssertEqual(
                SignIn.evaluateCallback(head(browserRedirect + [initiator]), peer: .currentUser), accepted,
                "\(initiator)"
            )
        }
    }

    // MARK: - Not the callback

    func testAnythingButTheCallbackWithATokenIsNotFound() {
        XCTAssertEqual(SignIn.evaluateCallback(nil, peer: .currentUser), .notFound)
        XCTAssertEqual(SignIn.evaluateCallback(head(target: "/favicon.ico"), peer: .currentUser), .notFound)
        XCTAssertEqual(SignIn.evaluateCallback(head(target: "/cloudkit-sign-in"), peer: .currentUser), .notFound)
        XCTAssertEqual(
            SignIn.evaluateCallback(head(target: "/cloudkit-sign-in?ckWebAuthToken="), peer: .currentUser), .notFound
        )
        XCTAssertEqual(
            SignIn.evaluateCallback(head(target: "/other?ckWebAuthToken=abc"), peer: .otherUser), .notFound
        )
    }

    // MARK: - Refused

    func testACallbackFromAnotherAccountOrAnUnknownOwnerIsRefused() {
        XCTAssertEqual(SignIn.evaluateCallback(head(browserRedirect), peer: .otherUser), .refuse(.otherUser))
        XCTAssertEqual(SignIn.evaluateCallback(head(browserRedirect), peer: .unknown), .refuse(.unverifiedPeer))
    }

    func testOnlyAGetAddressedTo127001IsTheCallback() {
        XCTAssertEqual(
            SignIn.evaluateCallback(head(browserRedirect, method: "POST"), peer: .currentUser), .refuse(.method)
        )
        XCTAssertEqual(SignIn.evaluateCallback(head(method: "HEAD"), peer: .currentUser), .refuse(.method))
        for hosts in [
            [], [("Host", "attacker.example:47823")], [("Host", "localhost:47823")], [("Host", "127.0.0.1:port")],
            [("Host", "127.0.0.10:47823")], [("Host", "127.0.0.1:47823"), ("Host", "attacker.example")]
        ] {
            XCTAssertEqual(SignIn.evaluateCallback(head(hosts), peer: .currentUser), .refuse(.host), "\(hosts)")
        }
    }

    func testAFetchFrameSubresourceOrLocalPageRequestIsRefused() {
        let host = ("Host", "127.0.0.1:47823")
        let cases: [[(String, String)]] = [
            // fetch() and XMLHttpRequest, with or without CORS.
            [host, ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "no-cors"), ("Sec-Fetch-Dest", "empty")],
            [host, ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")],
            // An image or script tag.
            [host, ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "no-cors"), ("Sec-Fetch-Dest", "image")],
            // A frame navigated to the callback.
            [host, ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "iframe")],
            // A navigation started by another page on this computer's loopback address.
            [host, ("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")],
            [host, ("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")],
            // Fetch metadata without a mode is not a navigation.
            [host, ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Dest", "document")],
            [host, ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Mode", "cors")]
        ]
        for fields in cases {
            XCTAssertEqual(
                SignIn.evaluateCallback(head(fields), peer: .currentUser), .refuse(.notTopLevelNavigation), "\(fields)"
            )
        }
    }

    func testAnInitiatorThatIsNotAnAppleSignInPageIsRefused() {
        for initiator in [
            [("Referer", "https://attacker.example/")], [("Origin", "https://attacker.example")],
            [("Origin", "null")], [("Referer", "http://idmsa.apple.com/")],
            [("Referer", "https://apple.com.attacker.example/")], [("Referer", "http://127.0.0.1:8080/")],
            [("Referer", "not a url")], [("Referer", "")],
            [("Referer", "https://idmsa.apple.com/"), ("Referer", "https://attacker.example/")],
            [("Referer", "https://idmsa.apple.com/"), ("Origin", "https://attacker.example")]
        ] {
            XCTAssertEqual(
                SignIn.evaluateCallback(head(browserRedirect + initiator), peer: .currentUser),
                .refuse(.untrustedInitiator),
                "\(initiator)"
            )
        }
    }

    // MARK: - Waiting for the callback

    func testRefusedCallbacksAreAnswered403AndTheSignInWaitsForTheBrowser() async throws {
        let listener = QueuedListener()
        listener.queue(QueuedListener.Request(head: head(browserRedirect), peer: .otherUser, listener: listener))
        listener.queue(QueuedListener.Request(
            head: head(browserRedirect + [("Referer", "https://attacker.example/")]), peer: .currentUser,
            listener: listener
        ))
        listener.queue(QueuedListener.Request(head: head(target: "/favicon.ico"), peer: .otherUser, listener: listener))
        listener.queue(QueuedListener.Request(head: head(browserRedirect), peer: .currentUser, listener: listener))

        let token = try await SignIn.awaitCallback(on: listener, within: .seconds(5))

        XCTAssertEqual(token, "abc+def=")
        let statuses = listener.responses.map { $0.components(separatedBy: "\r\n").first ?? "" }
        XCTAssertEqual(statuses, [
            "HTTP/1.1 403 Forbidden", "HTTP/1.1 403 Forbidden", "HTTP/1.1 404 Not Found", "HTTP/1.1 200 OK"
        ])
        XCTAssertTrue(listener.responses[0].contains("so it was not used"))
    }

    func testOnlyRefusedCallbacksLetTheSignInTimeOut() async throws {
        let listener = QueuedListener()
        listener.queue(QueuedListener.Request(head: head(browserRedirect), peer: .unknown, listener: listener))
        do {
            _ = try await SignIn.awaitCallback(on: listener, within: .milliseconds(200))
            XCTFail("A refused callback must never sign in")
        } catch {
            XCTAssertEqual(error as? DesktopCloudSyncError, .signInTimedOut)
        }
        XCTAssertEqual(listener.responses.count, 1)
    }
}

/// Hands out queued requests, then waits out the timeout.
private final class QueuedListener: DesktopLoopbackListener, @unchecked Sendable {
    struct Request: DesktopLoopbackRequest {
        let head: DesktopLoopbackRequestHead?
        let peer: DesktopLoopbackPeer
        let listener: QueuedListener
        func respond(_ bytes: Data) { listener.record(bytes) }
    }

    private let lock = NSLock()
    private var queued: [Request] = []
    private var answered: [String] = []

    var responses: [String] { lock.withLock { answered } }

    func queue(_ request: Request) { lock.withLock { queued.append(request) } }

    fileprivate func record(_ bytes: Data) {
        lock.withLock { answered.append(String(bytes: bytes, encoding: .utf8) ?? "") }
    }

    func nextRequest(within timeout: Duration) async throws -> Request? {
        if let next = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) { return next }
        try await Task.sleep(for: timeout)
        return nil
    }

    func close() {}
}
