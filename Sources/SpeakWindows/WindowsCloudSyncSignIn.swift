import Foundation
import SpeakDesktopSync
import SpeakWindowsPlatform

/// The two ways Apple's web sign-in returns to the app: the loopback listener
/// (`http://127.0.0.1:47823/cloudkit-sign-in`) or a `justspeaktoit://` link a
/// launch forwards to this window. The build's `signInCallback` chooses one.
extension WindowsCloudSync {
    /// One sign-in's callback, opened before the browser so an early return
    /// is not missed.
    enum SignInCallback {
        case loopback(WindowsLoopbackListener)
        case customScheme(DesktopSignInCallbackInbox, DesktopSignInCallbackInbox.Ticket)

        init(mode: DesktopCloudSyncSignIn.CallbackMode, inbox: DesktopSignInCallbackInbox) throws {
            switch mode {
            case .loopback: self = .loopback(try WindowsLoopbackListener(port: DesktopCloudSyncSignIn.callbackPort))
            case .customScheme: self = .customScheme(inbox, inbox.open())
            }
        }

        func token(within window: Duration) async throws -> String {
            switch self {
            case .loopback(let listener): return try await WindowsCloudSync.awaitCallback(on: listener)
            case .customScheme(let inbox, let ticket): return try await inbox.wait(for: ticket, timeout: window)
            }
        }

        func close() {
            switch self {
            case .loopback(let listener): listener.close()
            case .customScheme(let inbox, let ticket): inbox.close(ticket)
            }
        }
    }

    static func awaitCallback(on listener: WindowsLoopbackListener) async throws -> String {
        let deadline = ContinuousClock.now + signInWindow
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw WindowsLoopbackListener.Failure.timedOut }
            let connection = try await listener.accept(timeout: remaining)
            if let target = connection.target,
               let token = DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: target) {
                connection.respond(callbackPage(
                    "Signed in", "You are signed in to iCloud. You can close this tab and return to Just Speak to It."
                ))
                return token
            }
            connection.respond(callbackPage("Not found", "This address only completes iCloud sign-in.", status: 404))
        }
    }

    private static func callbackPage(_ title: String, _ message: String, status: Int = 200) -> Data {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><p>\(message)</p>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
