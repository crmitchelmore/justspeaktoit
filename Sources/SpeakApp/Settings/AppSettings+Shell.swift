import AppKit
import Foundation
import SpeakCore

/// Where the app shows itself: the Dock, the menu bar and the status bar
/// icon's style. It owns applying the Dock presence, so a visibility change
/// and its activation-policy side effect cannot be separated.
@MainActor
final class ShellPreferences: ObservableObject {
    private let persistence: AppSettingsPersistence
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    @Published var appVisibility: AppSettings.AppVisibility {
        didSet {
            persistence.store(appVisibility.rawValue, key: .appVisibility)
            applyAppVisibility()
        }
    }

    /// Whether the menu bar (status bar) icon is shown while running in
    /// Dock Only mode. Only user-configurable in that mode; the menu bar modes
    /// always require the icon as their primary access point.
    @Published var showStatusBarIconInDockOnly: Bool {
        didSet { persistence.store(showStatusBarIconInDockOnly, key: .showStatusBarIconInDockOnly) }
    }

    /// Whether the status bar icon uses the compact, icon-only style. When on,
    /// the "Speak"/status label is hidden and recording state is conveyed purely
    /// through iconography and colour, keeping the menu bar footprint minimal.
    /// When off (default) the icon shows the Labelled style with status text.
    @Published var compactStatusBarIcon: Bool {
        didSet { persistence.store(compactStatusBarIcon, key: .compactStatusBarIcon) }
    }

    init(
        persistence: AppSettingsPersistence,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void
    ) {
        self.persistence = persistence
        self.setActivationPolicy = setActivationPolicy
        appVisibility = persistence.choice(.appVisibility, default: .dockAndMenuBar)
        showStatusBarIconInDockOnly = persistence.flag(.showStatusBarIconInDockOnly, default: true)
        compactStatusBarIcon = persistence.flag(.compactStatusBarIcon, default: false)
    }

    /// Applies the current app visibility setting to show/hide dock icon
    func applyAppVisibility() {
        setActivationPolicy(appVisibility.showInDock ? .regular : .accessory)
    }

    func reload(from restored: ShellPreferences) {
        appVisibility = restored.appVisibility
        showStatusBarIconInDockOnly = restored.showStatusBarIconInDockOnly
        compactStatusBarIcon = restored.compactStatusBarIcon
    }
}

extension AppSettings {
    var appVisibility: AppVisibility {
        get { shell.appVisibility }
        set { shell.appVisibility = newValue }
    }

    var showStatusBarIconInDockOnly: Bool {
        get { shell.showStatusBarIconInDockOnly }
        set { shell.showStatusBarIconInDockOnly = newValue }
    }

    var compactStatusBarIcon: Bool {
        get { shell.compactStatusBarIcon }
        set { shell.compactStatusBarIcon = newValue }
    }

    /// Applies the current app visibility setting to show/hide dock icon
    func applyAppVisibility() {
        shell.applyAppVisibility()
    }
}
