#if os(macOS)
import Foundation
import SpeakCore

extension AppAutomationHandler: AutomationConfigurationHost {
    func automationConfiguration(keys: [String]?, prefix: String?) async throws -> AutomationResult {
        let configuration = try self.requireConfiguration()
        return AutomationConfiguration.getResult(await configuration.document(), keys: keys, prefix: prefix)
    }

    /// Validates every change; applies them all or none, and only when the user
    /// turned on "Allow automation to change settings". A dry run always works.
    func automationSetConfiguration(
        _ changes: [String: AnyCodable.JSONValue],
        dryRun: Bool
    ) async throws -> AutomationResult {
        try self.requireConfiguration()
            .automationSet(changes, dryRun: dryRun, writesAllowed: self.allowsConfigurationChanges())
    }

    private func requireConfiguration() throws -> AppSettingsConfiguration {
        guard let configuration = self.configuration else {
            throw AutomationError(code: .unsupportedCommand, message: "Configuration is not available in this app.")
        }
        return configuration
    }
}
#endif
