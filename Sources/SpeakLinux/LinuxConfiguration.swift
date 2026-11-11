import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings
import CLinuxSupport

extension LinuxWindow {
    static func voiceLanguageTitle(
        _ settings: LinuxVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) {
        let calls = DesktopNativeBindings.configuration
        guard let index = DesktopNativeConfiguration.languageFieldIndex else {
            LinuxHostPlatform.update("The canonical Voice language field is unavailable.")
            return
        }
        if calls.setFieldTitle(index, settings.languageTitle(accountInventory: accountInventory)) < 0 {
            LinuxHostPlatform.update("The Voice language label could not be shown.")
        }
        guard let qualityIndex = DesktopNativeConfiguration.qualityFieldIndex else {
            LinuxHostPlatform.update("The canonical Voice quality field is unavailable.")
            return
        }
        if calls.setFieldTitle(qualityIndex, settings.qualityTitle(accountInventory: accountInventory)) < 0 {
            LinuxHostPlatform.update("The Voice quality label could not be shown.")
        }
        if calls.setFieldEnabled(qualityIndex,
            settings.qualityControlsAvailable(accountInventory: accountInventory) ? 1 : 0) < 0 {
            LinuxHostPlatform.update("The Voice quality availability could not be shown.")
        }
    }

    static func configureConfiguration(_ holder: LinuxEventContext) async throws {
        let snapshot = try await holder.controller.nativeConfigurationEditorSnapshot()
        let failed = DesktopNativeConfiguration.present(
            snapshot, calls: DesktopNativeBindings.configuration, callback: linuxConfigurationEvent,
            context: holder.callbackContext
        ) { preferences in
            holder.gestures.configureTiming(
                hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
            )
        }
        if let failed { throw configurationFailure(failed) }
        if let failed = DesktopNativeConfiguration.presentLayout(
            snapshot.preferences, calls: DesktopNativeBindings.layout
        ) {
            throw configurationFailure(failed)
        }
        try await configureActionShortcuts(holder)
    }

    private static func configurationFailure(_ step: DesktopNativeConfiguration.Step) -> DesktopConfigurationError {
        switch step {
        case .escapeCancellation: return .invalidField("Escape cancellation")
        case .preferences: return .invalidField("Native preferences")
        case .qualityAvailability: return .invalidField("Voice quality availability")
        case .layoutDensity: return .invalidField("Layout density")
        case .sidebarShortcuts: return .invalidField("Sidebar shortcuts")
        }
    }

    static func performConfigurationAction(
        _ action: Int32, values: [String], holder: LinuxEventContext, editorID: String? = nil
    ) async throws {
        try await holder.controller.performConfigurationEditorAction(action, values: values, editorID: editorID)
        try await configureConfiguration(holder)
        voiceOutput(await holder.controller.voiceOutputSettings(),
            accountInventory: await holder.controller.selectedVoiceAccountInventory)
        if action == 1 { postProcessing(await holder.controller.postProcessingOptions()) }
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func linuxConfigurationEvent(
    _ action: Int32, _ entries: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let entries else { return -1 }
    let received = UnsafeBufferPointer(start: entries, count: count).map(String.init(nativeOrEmpty:))
    return LinuxEventContext.configurationEditorEvent(
        action: action, values: received, context: context, errorBuffer: errorBuffer, capacity: capacity
    )
}

extension LinuxEventContext {
    func performConfigurationAction(_ action: Int32, values: [String], editorID: String?) async throws {
        try await LinuxWindow.performConfigurationAction(action, values: values, holder: self, editorID: editorID)
    }

    func configureConfiguration() async throws { try await LinuxWindow.configureConfiguration(self) }
}

func linuxPostProcessingEvent(_ value: String, slot: Int, holder: LinuxEventContext) {
    let enabled = slot >= 0
    let index = enabled ? slot : -1 - slot
    guard let model = LinuxWindow.postProcessingModelIdentifier(forSelection: index) else {
        _ = jsti_window_update("Could not save post-processing settings: invalid model selection.", nil, -1)
        return
    }
    let fields: DesktopPostProcessing.NativeFields
    do { fields = try DesktopPostProcessing.nativeFields(value) } catch {
        _ = jsti_window_update(error.localizedDescription, nil, -1)
        return
    }
    let controller = holder.controller
    holder.enqueueSettings {
        await controller.applyPostProcessingFromEditor(enabled: enabled, modelIdentifier: model, fields: fields) {
            let saved = await controller.postProcessingOptions()
            guard !Task.isCancelled else { return }
            LinuxWindow.postProcessing(saved)
        }
    }
}
