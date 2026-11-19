import Foundation

/// Central runtime check for the shared App Group capability.
///
/// `UserDefaults(suiteName:)` can return a non-nil object even when the signed
/// product lacks the App Group entitlement; writes then land outside the
/// intended shared container and never reach the counterpart process. The
/// effective capability is therefore verified by probing
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, which
/// reflects the entitlement of the running binary.
///
/// Every App Group construction site shares one failure behaviour: log a
/// fault and construct the store without defaults, so it reports itself
/// unavailable (`isAvailable == false`, throwing or no-op writes) instead of
/// silently operating on divergent shared state.
public enum AppGroupAvailability {
    /// Returns the shared defaults suite only when the effective App Group
    /// capability is present at runtime; `nil` (after logging a fault)
    /// otherwise.
    ///
    /// `containerURL` and `makeDefaults` are injectable for deterministic
    /// tests; production callers use the defaults.
    public static func verifiedDefaults(
        groupIdentifier: String = KeyboardHandoffStore.appGroupIdentifier,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        },
        makeDefaults: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults? {
        guard containerURL(groupIdentifier) != nil else {
            SpeakLogger.logger(category: "AppGroupAvailability").fault(
                """
                App Group \(groupIdentifier, privacy: .public) has no container; the signed \
                product is missing the entitlement. Shared state is disabled.
                """
            )
            return nil
        }
        guard let defaults = makeDefaults(groupIdentifier) else {
            SpeakLogger.logger(category: "AppGroupAvailability").fault(
                """
                App Group \(groupIdentifier, privacy: .public) defaults suite could not be \
                created. Shared state is disabled.
                """
            )
            return nil
        }
        return defaults
    }
}
