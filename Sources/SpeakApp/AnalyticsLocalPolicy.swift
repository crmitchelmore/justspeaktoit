#if !APP_STORE
import Foundation

/// Device-local operator policy. Consent remains owned by ProductAnalyticsController.
/// The same synchronized gate is read by controller and transport admission.
final class AnalyticsLocalPolicy: @unchecked Sendable {
    static let defaultsKey = "posthog.forceDisabled"
    private let lock = NSLock()
    private let defaults: UserDefaults
    let isBuildDisabled: Bool
    private var localDisabled: Bool

    init(
        defaults: UserDefaults = .standard,
        buildDisabled: Bool = Bundle.main.object(forInfoDictionaryKey: "PostHogForceDisabled") as? Bool ?? false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        let environmentDisabled = ["1", "true", "yes"].contains(environment["POSTHOG_DISABLED"]?.lowercased() ?? "")
        self.isBuildDisabled = buildDisabled || environmentDisabled
        self.localDisabled = defaults.bool(forKey: Self.defaultsKey)
    }

    var isDisabled: Bool { lock.withLock { isBuildDisabled || localDisabled } }
    var isLocallyDisabled: Bool { lock.withLock { localDisabled } }

    func setLocallyDisabled(_ value: Bool) {
        lock.withLock {
            localDisabled = value
            defaults.set(value, forKey: Self.defaultsKey)
        }
    }
}
#endif
