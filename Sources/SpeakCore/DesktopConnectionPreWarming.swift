import Foundation

/// Portable intent is distinct from the native editor's one-process approval.
public enum DesktopConnectionPreWarming {
    public static let preferenceKey = ApplicationPreferenceKey.connectionPreWarmingEnabled.rawValue
    /// An editor action projection, never a stored or transferable permission.
    public static let approvalProjectionKey = "nativeConnectionPreWarmingSessionApproval"

    public static func removingApproval(from configuration: DesktopConfiguration) throws -> DesktopConfiguration {
        try DesktopConfiguration(values: configuration.values.filter { $0.key != approvalProjectionKey })
    }
}
