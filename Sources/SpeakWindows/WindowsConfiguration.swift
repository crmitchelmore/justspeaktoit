import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

extension WindowsNative {
    static func configureVoiceLanguageTitle(
        _ settings: WindowsVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) -> Bool {
        guard let index = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceOutputLanguagePreference.key
        }) else { return false }
        return settings.languageTitle(accountInventory: accountInventory).withCString {
            jsti_window_set_configuration_field_title(index, $0) >= 0
        } && configureVoiceQualityTitle(settings, accountInventory: accountInventory)
    }

    private static func configureVoiceQualityTitle(
        _ settings: WindowsVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) -> Bool {
        guard let index = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceSynthesisPreference.quality.key.rawValue
        }) else { return false }
        return settings.qualityTitle(accountInventory: accountInventory).withCString {
            jsti_window_set_configuration_field_title(index, $0) >= 0
        } && jsti_window_set_configuration_field_enabled(index,
            settings.qualityControlsAvailable(accountInventory: accountInventory) ? 1 : 0) >= 0
    }

    static func configureConfiguration(_ holder: WindowsEventContext) async throws {
        let snapshot = try await holder.controller.nativeConfigurationEditorSnapshot()
        let preferences = snapshot.preferences
        guard jsti_window_set_escape_cancellation(preferences.cancelRecordingOnEscape ? 1 : 0) == 0 else {
            throw WindowsNativeError(message: "Could not apply Escape cancellation.")
        }
        holder.hotKeys.configureTiming(
            hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
        )
        let strings = DesktopNativeStrings()
        let rows = zip(DesktopConfiguration.fields, snapshot.entries).map { field, value in
            JSTIConfigurationField(
                title: strings.add(field.key == VoiceOutputLanguagePreference.key ? snapshot.languageTitle
                    : field.key == VoiceSynthesisPreference.quality.key.rawValue ? snapshot.qualityTitle : field.title),
                value: strings.add(value), group: strings.add(field.group),
                is_boolean: { if case .boolean = field.kind { return 1 }; return 0 }(),
                requires_hud_overlay: field.requiresHUDOverlay ? 1 : 0,
                choices: preferences.serializedChoices(for: field).map { strings.add($0) },
                requires_hands_free_guard: field.requiresHandsFreeGuard ? 1 : 0,
                enabled_by_field: field.enabledBy.flatMap { key in
                    DesktopConfiguration.fields.firstIndex { $0.key == key }.map { Int32($0 + 1) }
                } ?? 0
            )
        }
        let recovered: [UnsafePointer<CChar>?] = preferences.recoveredKeywords.map { strings.add($0) }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { fields in
                recovered.withUnsafeBufferPointer { recovery in
                    snapshot.id.withCString {
                        jsti_window_set_configuration_revision(
                            fields.baseAddress, fields.count, recovery.baseAddress, recovery.count,
                            windowsConfigurationEvent, holder.callbackContext, $0
                        )
                    }
                }
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not display dictation preferences.") }
        guard let qualityIndex = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceSynthesisPreference.quality.key.rawValue
        }), jsti_window_set_configuration_field_enabled(qualityIndex, snapshot.qualityEnabled ? 1 : 0) >= 0 else {
            throw WindowsNativeError(message: "Could not display Voice quality availability.")
        }
        try configureConfigurationLayout(preferences, strings: strings)
    }

    private static func configureConfigurationLayout(
        _ preferences: DesktopConfiguration, strings: DesktopNativeStrings
    ) throws {
        let density = preferences.visualDensity
        let layout = JSTIVisualDensity(
            compact: density.isCompact ? 1 : 0,
            page_padding: Int32(density.pagePadding), section_spacing: Int32(density.sectionSpacing),
            card_padding: Int32(density.cardPadding), content_spacing: Int32(density.cardContentSpacing),
            inline_spacing: Int32(density.inlineSpacing), group_spacing: Int32(density.groupSpacing),
            minimum_row_height: Int32(density.minimumListRowHeight)
        )
        guard jsti_window_set_visual_density(layout) == 0 else {
            throw WindowsNativeError(message: "Could not apply layout density.")
        }
        let bindings = DesktopSidebarShortcut.allCases.map {
            JSTISidebarShortcut(
                destination: strings.add($0.rawValue), digit: Int32($0.digit), hint: strings.add($0.chord)
            )
        }
        let sidebar = withExtendedLifetime(strings) {
            bindings.withUnsafeBufferPointer {
                jsti_window_set_sidebar_shortcuts(
                    $0.baseAddress, $0.count, preferences.enabled("showSidebarShortcutHints") ? 1 : 0
                )
            }
        }
        guard sidebar == 0 else { throw WindowsNativeError(message: "Could not display sidebar shortcuts.") }
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
    guard let context, let entries else { return -1 }
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return -1 }
    let received = UnsafeBufferPointer(start: entries, count: count).map { $0.map(String.init(cString:)) ?? "" }
    do {
        switch try DesktopHostConfigurationEditorEvent(action: action, values: received) {
        case .rendered(let id):
            holder.enqueueSettings {
                do { try await holder.controller.activateConfigurationEditorSnapshot(id) } catch {
                    WindowsNative.update(error.localizedDescription)
                }
            }
        case .action(let action, let values, let editorID):
            holder.enqueueSettings {
                do {
                    try await WindowsNative.performConfigurationAction(
                        action, values: values, holder: holder, editorID: editorID
                    )
                } catch {
                    WindowsNative.update(error.localizedDescription)
                    do { try await WindowsNative.configureConfiguration(holder) } catch {
                        WindowsNative.update(error.localizedDescription)
                    }
                }
            }
        }
        return 0
    } catch {
        DesktopNativeStrings.copy(error.localizedDescription, into: errorBuffer, capacity: capacity)
        return -1
    }
}
