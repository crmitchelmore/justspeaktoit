import Foundation

/// The destination intent shared by Mac and native desktop hosts.
public enum AppSwitchDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
    case originalApp
    case currentApp
    case onlyIfOriginalAppInFront

    public static let defaultValue: Self = .originalApp
    public static let preferenceKey = ApplicationPreferenceKey.appSwitchDelivery.rawValue
    public static let settingName = "If you switch apps before the transcript is ready"
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .originalApp: return "Insert into the app where you started"
        case .currentApp: return "Insert into the app you're in now"
        case .onlyIfOriginalAppInFront: return "Don't insert — copy to clipboard"
        }
    }

    public var explanation: String {
        switch self {
        case .originalApp:
            return "The transcript goes to the app and field where you started recording, "
                + "even if you've moved to another app. The app you're in now is left alone."
        case .currentApp:
            return "The transcript follows you: it goes into whichever app and field you're using "
                + "when it's ready."
        case .onlyIfOriginalAppInFront:
            return "The transcript is only inserted if the app where you started recording is still "
                + "in front. Otherwise nothing is typed anywhere and it's kept on the clipboard for you to paste."
        }
    }

    /// Empty is an editor-only migration choice, not a fourth delivery policy.
    /// Missing persisted intent preserves the host's pre-policy behavior.
    public static var desktopChoices: [DesktopConfiguration.Choice] {
        [.init(value: "", title: "Keep existing platform delivery (legacy)")]
            + allCases.map { .init(value: $0.rawValue, title: $0.displayName) }
    }

    public static var desktopLabels: String { desktopChoices.map(\.title).joined(separator: "\n") }
    public static func desktopSelection(_ policy: Self?) -> Int {
        guard let policy, let index = allCases.firstIndex(of: policy) else { return 0 }
        return index + 1
    }

    public static func desktopPolicy(selection: Int) throws -> Self? {
        guard desktopChoices.indices.contains(selection) else {
            throw DesktopConfigurationError.invalidField(settingName)
        }
        return selection == 0 ? nil : allCases[selection - 1]
    }

    public static func nativeHelp(canTargetApps: Bool) -> String {
        canTargetApps
            ? "Legacy keeps existing guarded delivery. Original-app background output requires a safely addressable "
                // swiftlint:disable:next line_length
                + "field; otherwise copy only. Current-app delivery is cancelled if its captured destination changes again."
            : "Wayland cannot identify or target another app. Explicit app-switch policies copy only; imported intent "
                + "is retained. Legacy keeps the existing consented focused-app paste behavior."
    }

    public static func linuxHelp(canTargetApps: Bool) -> String {
        canTargetApps
            ? "Legacy keeps existing guarded X11 paste. Explicit policies paste only while the captured app is still "
                + "in front and its identity is verified. Background output and a newly selected app/field cannot be "
                + "safely addressed on this route, so switching apps copies only. Imported intent is retained."
            : nativeHelp(canTargetApps: false)
    }
}
