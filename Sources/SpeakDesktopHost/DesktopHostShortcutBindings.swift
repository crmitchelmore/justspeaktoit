import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostPlatform {
    /// Configuration keys whose shortcut bindings this host applies. Hosts
    /// without action shortcuts keep the Mac bindings as preserved entries.
    package static var shortcutConfigurationKeys: Set<String> { [] }
}

extension DesktopHostController {
    /// The Mac-compatible action shortcuts stored with the portable settings.
    /// Missing or malformed values fall back to the shared defaults.
    package var shortcutBindings: DesktopShortcutBindings {
        DesktopShortcutBindings(configuration: settings.configuration)
    }

    /// Persists every binding under the Mac `customShortcutBindings` key, so
    /// export, import and the Mac app read the same value. Bindings for
    /// actions this host cannot run are kept unchanged.
    package func saveShortcutBindings(_ bindings: DesktopShortcutBindings) throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        var changed = settings
        let base = try settings.configuration ?? DesktopConfiguration()
        changed.configuration = try base.replacingShortcutBindings(bindings)
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        settings = changed
    }
}
