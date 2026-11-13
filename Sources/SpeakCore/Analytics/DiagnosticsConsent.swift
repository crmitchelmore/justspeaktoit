import Foundation

/// The user's answer to "Send crash reports and diagnostics".
public enum DiagnosticsConsentDecision: String, Sendable, CaseIterable {
    /// Not asked yet. Collection stays off until the user agrees.
    case undecided
    case granted
    case declined
}

/// Pre-collection consent for crash reports and diagnostics (Sentry) on macOS
/// and iOS, separate from product analytics.
///
/// Off until the user agrees (App Review Guideline 5.1.1): nothing starts the
/// crash reporter unless `permitsCollection` is true. The decision is
/// per device and is never migrated or synced, because consent given on one
/// device is not consent for another.
public final class DiagnosticsConsent: @unchecked Sendable {
    public static let defaultsKey = "diagnosticsConsent"
    /// Posted after every recorded decision; the object is the store.
    public static let didChangeNotification = Notification.Name("DiagnosticsConsentDidChange")
    public static let shared = DiagnosticsConsent()

    public static let title = "Send crash reports and diagnostics"
    public static let explanation = "Sends crash reports, errors, app sessions and sampled performance timings "
        + "to Sentry in the EU so problems can be fixed. They are linked to a random installation ID and never "
        + "include transcripts, audio, prompts, clipboard text or API keys. Off until you turn it on; turning "
        + "it off stops reporting at once and deletes reports not yet sent."

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    public init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    public var decision: DiagnosticsConsentDecision {
        defaults.string(forKey: Self.defaultsKey).flatMap(DiagnosticsConsentDecision.init(rawValue:)) ?? .undecided
    }

    public var permitsCollection: Bool { decision == .granted }
    public var needsDecision: Bool { decision == .undecided }

    public func record(granted: Bool) {
        defaults.set((granted ? DiagnosticsConsentDecision.granted : .declined).rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }
}
