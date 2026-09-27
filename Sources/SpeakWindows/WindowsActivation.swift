import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

/// `justspeaktoit://` links: the one this process was launched with and those
/// later launches forward to it through `WindowsActivationServer`.
///
/// Links that arrive before the window is ready wait (at most `pendingLimit`)
/// and run once it is, in arrival order. Each link does only what the window's
/// own controls do: bring the window forward, start or stop a recording like
/// Record with no captured field, or complete the iCloud sign-in the user
/// started.
final class WindowsActivationRouter: @unchecked Sendable {
    static let pendingLimit = 8

    private let lock = NSLock()
    private weak var holder: WindowsEventContext?
    private var pending: [String] = []
    private var closed = false

    /// Called on the activation accept thread for each forwarded link.
    func receive(_ link: String) async -> DesktopActivationFrame.Reply {
        let route = lock.withLock { () -> Route in
            if closed { return .refused }
            if let holder { return .perform(holder) }
            guard pending.count < Self.pendingLimit else { return .refused }
            pending.append(link)
            return .queued
        }
        switch route {
        case .queued: return .accepted
        case .refused: return .refused
        case .perform(let holder): return await Self.perform(link, holder: holder)
        }
    }

    private enum Route {
        case queued
        case refused
        case perform(WindowsEventContext)
    }

    /// The window is ready: links from now on run at once, and waiting ones run now.
    func attach(_ holder: WindowsEventContext) {
        let waiting = lock.withLock { () -> [String] in
            guard !closed else { return [] }
            self.holder = holder
            defer { pending = [] }
            return pending
        }
        guard !waiting.isEmpty else { return }
        Task {
            for link in waiting { _ = await Self.perform(link, holder: holder) }
        }
    }

    /// The window is closing: every later link is refused.
    func close() {
        lock.withLock {
            closed = true
            holder = nil
            pending = []
        }
    }

    static func perform(_ link: String, holder: WindowsEventContext) async -> DesktopActivationFrame.Reply {
        let request: DesktopActivationRequest
        do {
            request = try DesktopActivationLink.parse(link)
        } catch {
            WindowsNative.update(error.localizedDescription)
            return .refused
        }
        switch request {
        case .show:
            jsti_window_request_foreground()
            return .accepted
        case .capture(let command):
            jsti_window_request_foreground()
            return await capture(command, controller: holder.controller)
        case .cloudKitSignIn(let token):
            guard holder.cloudSync?.deliverSignInCallback(token) == true else {
                WindowsNative.update(
                    "An iCloud sign-in link arrived, but no sign-in with that callback was waiting; it was ignored."
                )
                return .refused
            }
            jsti_window_request_foreground()
            return .accepted
        }
    }

    /// The recorder verbs, through the same controller entry points as the
    /// `speak` CLI's `listen` and `stop`: no captured field, so the transcript
    /// is saved and offered for Copy rather than typed into another app.
    private static func capture(
        _ command: DesktopCaptureCommand, controller: WindowsAppController
    ) async -> DesktopActivationFrame.Reply {
        let recording = await controller.automationSessionActive()
        let start: Bool
        switch command {
        case .start:
            guard !recording else { return .accepted }
            start = true
        case .stop:
            guard recording else { return .accepted }
            start = false
        case .toggle: start = !recording
        }
        do {
            if start {
                _ = try await controller.automationStartDictation()
            } else {
                _ = try await controller.automationStopDictation()
            }
            return .accepted
        } catch {
            WindowsNative.update(error.localizedDescription)
            return .refused
        }
    }
}

/// What this launch does with its command line before any window opens.
enum WindowsActivationLaunch {
    /// The link MSIX protocol activation passes as the only argument, or one
    /// given by hand. Flags such as `--self-test` are never links.
    static func link(in arguments: [String]) -> String? {
        arguments.dropFirst().first { $0.contains("://") && !$0.hasPrefix("-") }
    }

    /// Owns the activation pipe for this window, or forwards this launch's link
    /// to the window that owns it. `nil` means another window received the
    /// link and this process should exit.
    static func begin(router: WindowsActivationRouter) -> WindowsActivation? {
        let link = self.link(in: CommandLine.arguments)
        do {
            let server = WindowsActivationServer(pipeName: try WindowsActivationServer.defaultPipeName())
            switch try server.start(handler: { await router.receive($0) }) {
            case .listening:
                if let link { Task { _ = await router.receive(link) } }
                return WindowsActivation(router: router, server: server)
            case .anotherInstanceIsRunning:
                // A plain launch keeps opening its own window, as before; only
                // a link is handed to the running one.
                guard let link else { return WindowsActivation(router: router, server: nil) }
                jsti_allow_foreground_handoff()
                do {
                    let reply = try WindowsActivationServer.forward(link, pipeName: server.pipeName)
                    if reply == .malformed { report("The running window could not read the link.") }
                } catch {
                    report("Could not pass the link to the running window: \(error.localizedDescription)")
                }
                return nil
            }
        } catch {
            // Links then work only in this window; everything else is unchanged.
            report("Links will not reach this window: \(error.localizedDescription)")
            if let link { Task { _ = await router.receive(link) } }
            return WindowsActivation(router: router, server: nil)
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// This window's link handling: the router, and the server when this window
/// owns the activation pipe.
final class WindowsActivation: @unchecked Sendable {
    let router: WindowsActivationRouter
    let server: WindowsActivationServer?

    init(router: WindowsActivationRouter, server: WindowsActivationServer?) {
        self.router = router
        self.server = server
    }

    /// `nil` when this launch forwarded its link to another window and must exit.
    static func begin() -> WindowsActivation? {
        WindowsActivationLaunch.begin(router: WindowsActivationRouter())
    }

    /// Refuses later links and stops listening; the pipe's accept thread is
    /// joined off the UI thread and the actor.
    func shutDown() async {
        router.close()
        let server = server
        await Task.detached { server?.stop() }.value
    }
}
