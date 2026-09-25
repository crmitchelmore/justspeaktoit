import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

/// The shared Azure Speech resource rules under the name Windows call sites use.
typealias WindowsAzureResource = DesktopHostAzureResource

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
