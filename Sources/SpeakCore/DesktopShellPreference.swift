import Foundation

/// Where the app appears in the system shell. The raw values are the Mac's
/// `appVisibility` values so settings transfer unchanged: the Mac's Dock is a
/// desktop taskbar button and its menu bar extra is the notification-area icon.
public enum DesktopAppVisibility: String, CaseIterable, Sendable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly

    public static let defaultValue = DesktopAppVisibility.dockAndMenuBar

    public var displayName: String {
        switch self {
        case .dockAndMenuBar: return "Taskbar and notification area"
        case .menuBarOnly: return "Notification area only"
        case .dockOnly: return "Taskbar only"
        }
    }

    public var showsTaskbarButton: Bool { self != .menuBarOnly }
    public var showsNotificationIcon: Bool { self != .dockOnly }
}

/// App-shell preferences in General. `appVisibility` and the compact icon are
/// applied by hosts with a notification-area shell (Windows); other hosts keep
/// and transfer them. The analytics choice is a Mac preference: desktop hosts
/// send no analytics or crash reports whatever it says.
///
/// Apple-only shell values are deliberately not fields, so they stay preserved
/// and transfer untouched: `showStatusBarIconInDockOnly` (the Mac's Dock-only
/// menu bar extra), `paidAccessRoutingEnabled` (Mac/iOS paid routing; no desktop
/// route exists) and `recordingsDirectory` (a device path that imports must
/// never execute; desktop folders are chosen locally).
public enum ShellPreference {
    public static let appVisibilityKey = ApplicationPreferenceKey.appVisibility.rawValue
    public static let compactIconKey = ApplicationPreferenceKey.compactStatusBarIcon.rawValue
    public static let analyticsKey = ApplicationPreferenceKey.analyticsEnabled.rawValue

    public static let fields: [DesktopConfiguration.Field] = [
        .init(key: appVisibilityKey,
              title: "Show the app in (Windows taskbar and notification area)",
              group: "General", kind: .choice(DesktopAppVisibility.allCases.map {
                  .init(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(DesktopAppVisibility.defaultValue.rawValue))),
        .init(key: compactIconKey,
              title: "Compact notification-area icon (state shown by the icon only)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(false))),
        .init(key: analyticsKey,
              title: "Share anonymous usage analytics (Mac only; this desktop app sends none)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(false)))
    ]
    public static let keys = Set(fields.map(\.key))
    /// Shell values only the Apple apps apply; preserved, never fields.
    public static let appleOnlyKeys: Set<String> = [
        ApplicationPreferenceKey.showStatusBarIconInDockOnly.rawValue,
        ApplicationPreferenceKey.paidAccessRoutingEnabled.rawValue,
        ApplicationPreferenceKey.recordingsDirectory.rawValue
    ]
}

/// The shell presentation a host applies.
public struct DesktopShellPreferences: Equatable, Sendable {
    public var visibility: DesktopAppVisibility
    public var compactIcon: Bool

    public init(visibility: DesktopAppVisibility = .defaultValue, compactIcon: Bool = false) {
        self.visibility = visibility
        self.compactIcon = compactIcon
    }
}

extension DesktopConfiguration {
    public var shellPreferences: DesktopShellPreferences {
        guard let visibility = DesktopAppVisibility(rawValue: text(ShellPreference.appVisibilityKey)) else {
            preconditionFailure("Validated app visibility is invalid.")
        }
        return DesktopShellPreferences(visibility: visibility, compactIcon: enabled(ShellPreference.compactIconKey))
    }
}
