import Foundation

/// The Windows and Linux opt-ins for product analytics and crash reports.
///
/// Like the connection pre-warming approval, these are native editor
/// projections, never stored or transferable preferences: the decision lives
/// in the device-local telemetry store, so a preferences import, a Mac export
/// or `speak config set` can never grant consent. Both start off.
public enum DesktopTelemetryConsent {
    // Distinct from the Apple and Android `analyticsConsent`/`diagnosticsConsent`
    // string preferences, which an older import may have preserved verbatim.
    public static let analyticsKey = "desktopAnalyticsConsent"
    public static let diagnosticsKey = "desktopDiagnosticsConsent"
    public static let projectionKeys: Set<String> = [analyticsKey, diagnosticsKey]

    public static let analyticsTitle =
        "Share anonymous usage analytics (off until you opt in; never transcripts, audio or keys)"
    public static let diagnosticsTitle =
        "Send crash reports and diagnostics (off until you opt in; never transcripts, audio, keys or file paths)"

    static let fields: [DesktopConfiguration.Field] = [
        .init(key: analyticsKey, title: analyticsTitle,
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(false))),
        .init(key: diagnosticsKey, title: diagnosticsTitle,
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(false)))
    ]
}

extension DesktopConfiguration {
    /// Editor-only values: shown and submitted by the native settings editor
    /// but never persisted, exported, imported or exposed to automation.
    public static let editorProjectionKeys: Set<String> =
        DesktopTelemetryConsent.projectionKeys.union([DesktopConnectionPreWarming.approvalProjectionKey])

    public func removingEditorProjections() throws -> DesktopConfiguration {
        try DesktopConfiguration(values: values.filter { !Self.editorProjectionKeys.contains($0.key) })
    }
}
