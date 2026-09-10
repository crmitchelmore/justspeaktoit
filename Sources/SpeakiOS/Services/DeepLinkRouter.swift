#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

// MARK: - Deep Link Router

/// Centralised deep link handling for the app.
/// Supports URLs like:
///   justspeaktoit://openclaw                     → OpenClaw tab
///   justspeaktoit://openclaw/conversation/<id>   → specific conversation
///   justspeaktoit://transcribe                   → Transcribe tab
///   justspeaktoit://start                        → start recording
///   justspeaktoit://stop                         → stop recording
///   justspeaktoit://toggle                       → start, or stop if running
///   justspeaktoit://dictate                      → one-shot capture that
///                                                  returns the transcript
///   justspeaktoit://transcribe?action=start      → same, for surfaces that
///                                                  only own a tab link
///   justspeaktoit://x-callback-url/dictate?x-success=drafts://create?text=
///                                                → dictate, then open the
///                                                  caller's URL with the text
///
/// Capture verbs accept `?destination=clipboard|polish|history` to override the
/// configured hardware-trigger destination for one capture, and `?lang=`/
/// `?model=` to override the transcription language and model. `dictate` also
/// takes `?maxDuration=` and the `x-success` / `x-error` / `x-cancel` callbacks.
/// `CaptureDeepLink` documents which values are accepted and which fail the
/// link outright.
///
/// The router only records what was asked for. Capture commands are published
/// as `pendingCaptureAction` and performed by the app once the scene is active,
/// because a URL can arrive during a cold launch, before the app is foreground
/// enough to open a microphone.
@MainActor
public final class DeepLinkRouter: ObservableObject {
    public static let shared = DeepLinkRouter()

    /// Which tab to select (0 = Transcribe, 1 = OpenClaw).
    @Published public var selectedTab: Int = 0

    /// When set, navigates to this conversation in the OpenClaw tab.
    @Published public var pendingConversationId: String?

    /// Set when a capture deep link arrived and has not been performed yet.
    @Published public var pendingCaptureAction: CaptureDeepLink?

    public init() {}

    /// Handles an incoming deep link URL. Returns `true` if handled.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        // Case-insensitive to match `CaptureDeepLink.parse`, which lowercases
        // the scheme: otherwise JUSTSPEAKTOIT://start parses as a command and
        // is then dropped here.
        guard url.scheme?.lowercased() == CaptureDeepLink.scheme else { return false }

        // Capture verbs are checked first: `transcribe?action=start` is both a
        // tab link and a command, and the command is the point of it.
        if let capture = CaptureDeepLink.parse(url) {
            selectedTab = 0
            pendingConversationId = nil
            // Latest wins. Two capture links can only race inside the cold-launch
            // window before the scene is active, and the newer one is the better
            // guess at what the user last asked for; queueing both would replay a
            // superseded command seconds later.
            //
            // What may not be dropped silently is a *caller* waiting on the
            // command being replaced. A `dictate` carries x-callback-url return
            // addresses, and an app that opened one is blocked until one of them
            // fires; leaving it waiting forever is worse than any ordering
            // question. So the superseded command answers its caller before it
            // goes, and only then is it replaced.
            self.reportSupersededCaptureIfNeeded(replacing: pendingCaptureAction, with: capture)
            pendingCaptureAction = capture
            return true
        }

        switch url.host?.lowercased() {
        case "openclaw":
            selectedTab = 1
            // Check for /conversation/<id> path
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2,
               components[0] == "conversation" {
                pendingConversationId = components[1]
            } else {
                pendingConversationId = nil
            }
            return true

        case "transcribe":
            selectedTab = 0
            pendingConversationId = nil
            return true

        default:
            return false
        }
    }

    /// Tells a superseded `dictate`'s caller that its request was replaced,
    /// rather than leaving it waiting on a callback that will never fire.
    ///
    /// Only fires for a command that actually carried a return address, and
    /// only when a *different* command replaces it — a duplicate of the same
    /// link (a double-tap, a re-delivered URL) is not a supersession.
    private func reportSupersededCaptureIfNeeded(
        replacing previous: CaptureDeepLink?,
        with replacement: CaptureDeepLink
    ) {
        guard let previous, let callback = previous.callback, previous != replacement else { return }
        SpeakLogger.transcription.info(
            "Queued capture link superseded before the scene was active; answering its caller"
        )
        CaptureCommandRunner.reportSuperseded(to: callback)
    }

    /// Consumes and returns the pending conversation ID (if any).
    public func consumePendingConversation() -> String? {
        let cid = pendingConversationId
        pendingConversationId = nil
        return cid
    }

    /// Consumes and returns the pending capture command (if any), so a link can
    /// never be performed twice.
    public func consumePendingCaptureAction() -> CaptureDeepLink? {
        let action = pendingCaptureAction
        pendingCaptureAction = nil
        return action
    }
}
#endif
