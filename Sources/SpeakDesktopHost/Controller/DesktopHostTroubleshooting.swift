import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopHostTroubleshootingConfiguration: Sendable {
    package let processing: DesktopPostProcessing.Options
    package let findings: [DesktopTroubleshooting.Finding]
}

extension DesktopHostController {
    package func troubleshootingConfiguration(
        shortcutName: String, shortcutInstructions: String, restoreClipboard: Bool
    ) -> DesktopHostTroubleshootingConfiguration {
        let processing = postProcessingOptions()
        let enabled = processing.mode != .disabled
        var credential = DesktopTroubleshooting.Credential.available
        if DesktopTroubleshooting.requiresCredential(enabled: enabled, model: processing.modelIdentifier) {
            do {
                let key = try effects.apiKey(name: postProcessingCredential(for: processing.modelIdentifier))
                credential = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .available
            } catch { credential = .unavailable }
        }
        return DesktopHostTroubleshootingConfiguration(
            processing: processing,
            findings: DesktopTroubleshooting.findings(.init(
                postProcessing: .init(enabled: enabled, model: processing.modelIdentifier, credential: credential),
                shortcutName: shortcutName, shortcutInstructions: shortcutInstructions,
                restoreClipboard: restoreClipboard
            ))
        )
    }

    package func disablePostProcessingForTroubleshooting(expected: DesktopPostProcessing.Options) async throws {
        guard !closed, canUseHistory else {
            throw DesktopHostError(message: "Wait for the current operation before applying a fix.")
        }
        guard postProcessingOptions() == expected,
              DesktopTroubleshooting.requiresCredential(
                enabled: expected.mode != .disabled, model: expected.modelIdentifier
              ) else {
            throw DesktopHostError(message: "Post-processing changed. Check again before applying this fix.")
        }
        let key: String
        do {
            key = try effects.apiKey(name: postProcessingCredential(for: expected.modelIdentifier))
        } catch {
            throw DesktopHostError(message: "The saved credential could not be read. No setting was changed.")
        }
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopHostError(message: "A key is now available. Check again before changing post-processing.")
        }
        await savePostProcessing(
            enabled: false, modelIdentifier: expected.modelIdentifier, prompt: expected.customPrompt ?? "", key: ""
        )
        guard postProcessingOptions().mode == .disabled else {
            throw DesktopHostError(message: "Post-processing could not be disabled. Check the app status.")
        }
    }
}
