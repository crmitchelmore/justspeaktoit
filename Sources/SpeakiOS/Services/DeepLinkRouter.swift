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
///   justspeaktoit://keyboard?request=<uuid>       → validated keyboard capture
@MainActor
public final class DeepLinkRouter: ObservableObject {
    public static let shared = DeepLinkRouter()

    /// Which tab to select (0 = Transcribe, 1 = OpenClaw).
    @Published public var selectedTab: Int = 0

    /// When set, navigates to this conversation in the OpenClaw tab.
    @Published public var pendingConversationId: String?

    /// A validated keyboard request that the containing app should record for.
    @Published public var keyboardCaptureRequest: KeyboardCaptureRequest?

    private let keyboardStore: KeyboardHandoffStore

    public init(keyboardStore: KeyboardHandoffStore = .shared) {
        self.keyboardStore = keyboardStore
    }

    /// Handles an incoming deep link URL. Returns `true` if handled.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard url.scheme == "justspeaktoit" else { return false }

        switch url.host {
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

        case "keyboard":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let requestValue = components.queryItems?.first(where: { $0.name == "request" })?.value,
                  let requestID = UUID(uuidString: requestValue),
                  keyboardStore.record(matching: requestID)?.phase == .requested else {
                return false
            }
            selectedTab = 0
            pendingConversationId = nil
            keyboardCaptureRequest = KeyboardCaptureRequest(id: requestID)
            return true

        default:
            return false
        }
    }

    /// Consumes and returns the pending conversation ID (if any).
    public func consumePendingConversation() -> String? {
        let cid = pendingConversationId
        pendingConversationId = nil
        return cid
    }
}

public struct KeyboardCaptureRequest: Identifiable, Equatable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}
#endif
