import Foundation

/// Local previews without a feed and signing key cannot receive Sparkle updates.
enum SelfUpdateConfiguration {
    static let unavailableMessage =
        "Updates are unavailable in this local build. Install a published build to receive updates."

    static func isConfigured(info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }
}
