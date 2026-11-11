import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopAutomationConsent {
    package static func allowed(
        desired: Bool, localGrant: Bool?, legacyGrant: Bool?, requiresLocalGrant: Bool
    ) -> Bool {
        desired && (localGrant == true || (localGrant == nil && !requiresLocalGrant && legacyGrant == true))
    }
}

extension DesktopHostController {
    var automationUsesLocalConsent: Bool { Platform.self is any DesktopHostAutomationPlatform.Type }

    func importingAutomationPreferences(_ preferences: DesktopConfiguration) throws -> DesktopConfiguration {
        guard automationUsesLocalConsent else { return preferences }
        let key = ApplicationPreferenceKey.enableAutomationServer.rawValue
        var imported = preferences.values
        imported.removeValue(forKey: "automationLocalConsent")
        imported.removeValue(forKey: "automationEnabled")
        if let requested = imported[key] {
            guard case .bool = requested.storage else {
                throw DesktopConfigurationError.invalidField("Automation")
            }
        } else {
            imported[key] = settings.configuration?.values[key]
        }
        return try DesktopConfiguration(values: imported)
    }

    func applyingAutomationRevocation(to changed: inout Settings) {
        guard automationUsesLocalConsent else { return }
        if changed.configuration?.values["enableAutomationServer"]?.storage == .bool(false) {
            changed.automationLocalConsent = false
            changed.automationEnabled = nil
        }
    }

    func persistAutomationAwareSettings(_ changed: Settings) async throws {
        let revokes = automationUsesLocalConsent
            && changed.configuration?.values["enableAutomationServer"]?.storage == .bool(false)
        if revokes {
            settings = try automationSettings(enabled: false)
            await automationPreferenceChanged?()
            guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        }
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
        } catch {
            if revokes { throw automationRevocationPersistenceError(error) }
            throw error
        }
        settings = changed
        if !revokes { await automationPreferenceChanged?() }
    }

    func automationImportNotice() -> String {
        guard automationUsesLocalConsent else { return "" }
        return automationDesired && !automationEnabled()
            ? " Automation requested on, but local access remains off until enabled on this computer."
            : (automationEnabled() ? "" : " Automation access is off on this computer.")
    }
}
