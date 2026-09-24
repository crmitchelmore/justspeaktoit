import Foundation

/// One HTTP request received on the loopback sign-in callback.
public protocol DesktopLoopbackRequest: Sendable {
    /// The request target of the first line, such as `/cloudkit-sign-in?…`.
    var target: String? { get }
    /// Writes a complete response and closes the connection.
    func respond(_ bytes: Data)
}

/// A native listener on this computer's loopback address, open for one
/// sign-in. Nothing outside this computer can connect to it.
public protocol DesktopLoopbackListener: AnyObject, Sendable {
    associatedtype Request: DesktopLoopbackRequest
    /// Waits off the calling thread for one complete request, or returns
    /// `nil` once `timeout` has passed. Cancelling the task throws
    /// `CancellationError`.
    func nextRequest(within timeout: Duration) async throws -> Request?
    /// Stops listening. Only after every `nextRequest` has returned.
    func close()
}

extension DesktopCloudSyncSignIn {
    /// Waits for Apple's sign-in to redirect the browser to the callback and
    /// returns its web auth token. Any other request is answered with a 404
    /// and waiting goes on, until `window` has passed.
    public static func awaitCallback(
        on listener: some DesktopLoopbackListener,
        within window: Duration
    ) async throws -> String {
        let deadline = ContinuousClock.now + window
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let request = try await listener.nextRequest(within: remaining) else {
                throw DesktopCloudSyncError.signInTimedOut
            }
            if let target = request.target, let token = webAuthToken(fromRequestTarget: target) {
                request.respond(callbackPage(
                    "Signed in", "You are signed in to iCloud. You can close this tab and return to Just Speak to It."
                ))
                return token
            }
            request.respond(callbackPage("Not found", "This address only completes iCloud sign-in.", status: 404))
        }
    }

    /// A complete, uncached HTTP response with a short page for the browser.
    public static func callbackPage(_ title: String, _ message: String, status: Int = 200) -> Data {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><p>\(message)</p>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
