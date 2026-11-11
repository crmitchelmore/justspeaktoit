import Foundation
import SpeakCore

/// Captured with the profile, not looked up again when queued admission starts.
/// Consent is device-local and is never inferred from imported preferences.
public struct DesktopLivePolishSelection: Equatable, Sendable {
    public let configuration: DesktopConfiguration?
    public let approved: Bool

    public init(configuration: DesktopConfiguration?, approved: Bool) {
        self.configuration = configuration
        self.approved = approved
    }
}
