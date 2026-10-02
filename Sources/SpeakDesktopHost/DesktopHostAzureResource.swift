import Foundation
import SpeakCore
import SpeakDesktop

/// The Azure Speech resource endpoint a desktop host keeps with its other
/// device settings, under the key the Apple apps use for the same device-local
/// value. The key itself stays in the platform credential store as
/// `key:region`. Azure live transcription connects only to this resource;
/// recorded audio uses it when it is set and the credential's region otherwise.
package enum DesktopHostAzureResource {
    package static let invalidEndpoint = "Use the HTTPS endpoint from your resource\u{2019}s Keys and Endpoint page, "
        + "ending in cognitiveservices.azure.com or services.ai.azure.com, with no path."
    package static let missingForLive = "Azure live transcription needs your Azure Speech resource endpoint. "
        + "Add it in Settings \u{2192} Azure Speech resource\u{2026}, or choose another model."

    /// Shown when an Azure model is selected: the credential format, and for
    /// the live routes, which have no regional fallback, where the endpoint goes.
    package static func selectionHint(for model: String) -> String {
        let credential = " Enter Azure credentials as key:region (for example, your key followed by :uksouth)."
        guard DesktopLiveTranscription.route(forID: model)?.provider == .azure else { return credential }
        return credential + " Live transcription also needs Settings \u{2192} Azure Speech resource\u{2026}."
    }

    /// The entry as it is saved: trimmed, with an empty entry clearing the
    /// endpoint. Anything else must be a resource origin the shared clients
    /// accept, so a saved endpoint can never fail their check later.
    package static func normalized(_ entry: String) throws -> String {
        let endpoint = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.isEmpty || (try? AzureSpeechConfiguration.resourceURL(endpoint)) != nil else {
            throw DesktopHostError(message: invalidEndpoint)
        }
        return endpoint
    }
}

extension DesktopHostController {
    /// The saved resource endpoint, or empty when none is set.
    package func azureResourceEndpoint() -> String { settings.azureSpeechResourceEndpoint ?? "" }

    /// Azure live transcription has no regional fallback, so without a saved
    /// endpoint the recording is refused before its audio file, History record
    /// or socket exists.
    package func requireAzureResource(forLive model: String) throws {
        guard DesktopLiveTranscription.route(forID: model)?.provider == .azure,
              azureResourceEndpoint().isEmpty else { return }
        throw DesktopHostError(message: DesktopHostAzureResource.missingForLive)
    }

    /// Saves an entry `DesktopHostAzureResource.normalized` accepted.
    package func saveAzureResourceEndpoint(_ endpoint: String) {
        guard !closed else { return }
        var changed = settings
        changed.azureSpeechResourceEndpoint = endpoint.isEmpty ? nil : endpoint
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update(endpoint.isEmpty
                ? "Azure Speech resource endpoint cleared. Recorded audio uses the region in your Azure key."
                : "Azure Speech resource endpoint saved.")
        } catch { update("Could not save the Azure Speech resource endpoint: \(error.localizedDescription)") }
    }
}
