import Foundation
import SpeakDesktopHost
import CWindowsSupport

// The native API Keys dialog over the shared host workflow
// (DesktopHostAPIKeys.swift): the same Windows Credential Manager entries the
// Transcription, Post-processing and Voice editors read and write.
extension WindowsNative {
    /// Rows carry status text and a masked suffix only, never a stored key.
    @discardableResult
    static func presentAPIKeys(_ rows: [DesktopAPIKeyRow], status: String, context: UnsafeMutableRawPointer) -> Bool {
        let strings = rows.flatMap { [$0.identifier, $0.label, $0.uses, $0.status, $0.keyPageURL, $0.entryHint] }
        return withCStrings(strings + [status]) { pointers in
            let native = rows.indices.map { index in
                JSTIAPIKeyRow(
                    identifier: pointers[index * 6], label: pointers[index * 6 + 1], uses: pointers[index * 6 + 2],
                    status: pointers[index * 6 + 3], url: pointers[index * 6 + 4], hint: pointers[index * 6 + 5],
                    saved: rows[index].isSaved ? 1 : 0
                )
            }
            return native.withUnsafeBufferPointer {
                jsti_window_set_api_keys($0.baseAddress, $0.count, pointers[rows.count * 6], apiKeyEvent, context) == 0
            }
        }
    }

    /// The entry hook for settings, onboarding or any later caller: opens the
    /// dialog over the main window once it is idle. Thread safe.
    static func openAPIKeys() {
        jsti_window_request_api_keys()
    }
}

extension WindowsEventContext {
    /// Reads every row again and hands the dialog the latest status line.
    func refreshAPIKeys(status: String) async {
        let rows = await controller.apiKeyRows()
        if !WindowsNative.presentAPIKeys(rows, status: status, context: Unmanaged.passUnretained(self).toOpaque()) {
            WindowsNative.update("The API keys page could not be shown. Reopen it and try again.")
        }
    }
}

extension SpeakWindowsMain {
    static func configureAPIKeys(_ holder: WindowsEventContext) async {
        await holder.refreshAPIKeys(status: "")
        WindowsOnboardingHooks.shared.openAPIKeys = { _ in
            WindowsNative.openAPIKeys()
            return true
        }
    }
}

/// An action from the native API Keys dialog, on the UI thread. The key is
/// copied here before the dialog wipes its buffer; it is never logged.
func apiKeyEvent(
    _ action: Int32, _ identifier: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let name = identifier.map { String(cString: $0) } ?? ""
    let typed = key.map { String(cString: $0) } ?? ""
    holder.enqueueSettings {
        let controller = holder.controller
        let status: String
        switch action {
        case Int32(JSTI_API_KEY_SAVE.rawValue): status = await controller.saveAPIKey(identifier: name, key: typed)
        case Int32(JSTI_API_KEY_REMOVE.rawValue): status = await controller.removeAPIKey(identifier: name)
        case Int32(JSTI_API_KEY_VALIDATE.rawValue):
            status = await controller.validateAPIKey(identifier: name, typed: typed)
        default: status = ""
        }
        await holder.refreshAPIKeys(status: status)
    }
}
