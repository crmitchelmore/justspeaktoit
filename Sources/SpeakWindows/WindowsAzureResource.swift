import Foundation
import SpeakCore
import CWindowsSupport

/// The Azure Speech resource endpoint Windows keeps with its other device
/// settings, under the key the Apple apps use for the same device-local value.
/// The key itself stays in Credential Manager as `key:region`. Azure live
/// transcription connects only to this resource; recorded audio uses it when
/// it is set and the credential's region otherwise.
enum WindowsAzureResource {
    static let invalidEndpoint = "Use the HTTPS endpoint from your resource\u{2019}s Keys and Endpoint page, "
        + "ending in cognitiveservices.azure.com or services.ai.azure.com, with no path."

    /// The entry as it is saved: trimmed, with an empty entry clearing the
    /// endpoint. Anything else must be a resource origin the shared clients
    /// accept, so a saved endpoint can never fail their check later.
    static func normalized(_ entry: String) throws -> String {
        let endpoint = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.isEmpty || (try? AzureSpeechConfiguration.resourceURL(endpoint)) != nil else {
            throw WindowsNativeError(message: invalidEndpoint)
        }
        return endpoint
    }
}

extension WindowsAppController {
    /// The saved resource endpoint, or empty when none is set.
    func azureResourceEndpoint() -> String { settings.azureSpeechResourceEndpoint ?? "" }

    /// Saves an entry `WindowsAzureResource.normalized` accepted.
    func saveAzureResourceEndpoint(_ endpoint: String) {
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

extension WindowsNative {
    static func configureAzureResource(_ endpoint: String, context: UnsafeMutableRawPointer) -> Bool {
        endpoint.withCString { jsti_window_set_azure_resource($0, azureResourceEvent, context) == 0 }
    }
}

/// Apply from the native Azure Speech resource dialog, on the UI thread. The
/// entry is checked here, synchronously; only an accepted one is saved, in
/// settings order, after which the dialog is refreshed with what was saved.
func azureResourceEvent(
    _ entry: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?,
    _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let context, let entry else { return -1 }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let endpoint: String
    do {
        endpoint = try WindowsAzureResource.normalized(String(cString: entry))
    } catch {
        copyAzureResourceProblem(error.localizedDescription, into: errorBuffer, capacity: capacity)
        return -1
    }
    holder.enqueueSettings {
        await holder.controller.saveAzureResourceEndpoint(endpoint)
        let saved = await holder.controller.azureResourceEndpoint()
        if !WindowsNative.configureAzureResource(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved Azure Speech resource could not be shown. Reopen it and try again.")
        }
    }
    return 0
}

/// Copies whole UTF-8 scalars only, so a shortened reason is still valid text.
private func copyAzureResourceProblem(_ message: String, into buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
    guard let buffer, capacity > 0 else { return }
    var bytes: [UInt8] = []
    for scalar in message.unicodeScalars {
        let encoded = Array(String(scalar).utf8)
        guard bytes.count + encoded.count < capacity else { break }
        bytes += encoded
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
}
