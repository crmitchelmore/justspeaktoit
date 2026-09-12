import Foundation

/// The published privacy policy the App Store listing points at. App Review
/// expects the same document to be reachable from inside the app; the macOS
/// About pane has linked it for several releases and iOS did not, which is what
/// this constant closes.
enum PrivacyPolicy {
    static let address = "https://justspeaktoit.com/privacy"

    /// Force-unwrapped deliberately: `address` is a compile-time literal, and a
    /// silent `nil` here would drop the link App Review looks for.
    static let url = URL(string: address)!
}
