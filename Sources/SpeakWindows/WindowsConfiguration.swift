import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings
import CWindowsSupport

extension WindowsNative {
    static func configureVoiceLanguageTitle(
        _ settings: WindowsVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) -> Bool {
        let calls = DesktopNativeBindings.configuration
        guard let index = DesktopNativeConfiguration.languageFieldIndex else { return false }
        return calls.setFieldTitle(index, settings.languageTitle(accountInventory: accountInventory)) >= 0
            && configureVoiceQualityTitle(settings, accountInventory: accountInventory)
    }

    private static func configureVoiceQualityTitle(
        _ settings: WindowsVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) -> Bool {
        let calls = DesktopNativeBindings.configuration
        guard let index = DesktopNativeConfiguration.qualityFieldIndex else { return false }
        return calls.setFieldTitle(index, settings.qualityTitle(accountInventory: accountInventory)) >= 0
            && calls.setFieldEnabled(index,
                settings.qualityControlsAvailable(accountInventory: accountInventory) ? 1 : 0) >= 0
    }

    static func configureConfiguration(_ holder: WindowsEventContext) async throws {
        let snapshot = try await holder.controller.nativeConfigurationEditorSnapshot()
        let failed = DesktopNativeConfiguration.present(
            snapshot, calls: DesktopNativeBindings.configuration, callback: windowsConfigurationEvent,
            context: holder.callbackContext
        ) { preferences in
            holder.hotKeys.configureTiming(
                hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
            )
        }
        if let failed { throw WindowsNativeError(message: configurationFailure(failed)) }
        if let failed = DesktopNativeConfiguration.presentLayout(
            snapshot.preferences, calls: DesktopNativeBindings.layout
        ) {
            throw WindowsNativeError(message: configurationFailure(failed))
        }
    }

    private static func configurationFailure(_ step: DesktopNativeConfiguration.Step) -> String {
        switch step {
        case .escapeCancellation: return "Could not apply Escape cancellation."
        case .preferences: return "Could not display dictation preferences."
        case .qualityAvailability: return "Could not display Voice quality availability."
        case .layoutDensity: return "Could not apply layout density."
        case .sidebarShortcuts: return "Could not display sidebar shortcuts."
        }
    }

    static func performConfigurationAction(
        _ action: Int32, values: [String], holder: WindowsEventContext, editorID: String? = nil
    ) async throws {
        try await holder.controller.performConfigurationEditorAction(action, values: values, editorID: editorID)
        try await configureConfiguration(holder)
        guard configureVoiceOutput(await holder.controller.voiceOutputSettings(),
            context: holder.callbackContext,
            accountInventory: await holder.controller.selectedVoiceAccountInventory) else {
            throw WindowsNativeError(message: "Could not display the saved Voice quality and model.")
        }
        if action == 1 {
            try configurePostProcessing(
                await holder.controller.postProcessingOptions(), context: holder.callbackContext
            )
        }
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func windowsConfigurationEvent(
    _ action: Int32, _ entries: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let entries else { return -1 }
    let received = UnsafeBufferPointer(start: entries, count: count).map(String.init(nativeOrEmpty:))
    return WindowsEventContext.configurationEditorEvent(
        action: action, values: received, context: context, errorBuffer: errorBuffer, capacity: capacity
    )
}

extension WindowsEventContext {
    func performConfigurationAction(_ action: Int32, values: [String], editorID: String?) async throws {
        try await WindowsNative.performConfigurationAction(action, values: values, holder: self, editorID: editorID)
    }

    func configureConfiguration() async throws { try await WindowsNative.configureConfiguration(self) }
}
