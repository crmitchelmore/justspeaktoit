import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

extension LinuxWindow {
    static func voiceLanguageTitle(
        _ settings: LinuxVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) {
        guard let index = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceOutputLanguagePreference.key
        }) else {
            LinuxHostPlatform.update("The canonical Voice language field is unavailable.")
            return
        }
        let result = settings.languageTitle(accountInventory: accountInventory).withCString {
            jsti_window_set_configuration_field_title(index, $0)
        }
        if result < 0 { LinuxHostPlatform.update("The Voice language label could not be shown.") }
        guard let qualityIndex = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceSynthesisPreference.quality.key.rawValue
        }) else {
            LinuxHostPlatform.update("The canonical Voice quality field is unavailable.")
            return
        }
        let qualityResult = settings.qualityTitle(accountInventory: accountInventory).withCString {
            jsti_window_set_configuration_field_title(qualityIndex, $0)
        }
        if qualityResult < 0 { LinuxHostPlatform.update("The Voice quality label could not be shown.") }
        if jsti_window_set_configuration_field_enabled(qualityIndex,
            settings.qualityControlsAvailable(accountInventory: accountInventory) ? 1 : 0) < 0 {
            LinuxHostPlatform.update("The Voice quality availability could not be shown.")
        }
    }

    static func configureConfiguration(_ holder: LinuxEventContext) async throws {
        let snapshot = try await holder.controller.nativeConfigurationEditorSnapshot()
        let preferences = snapshot.preferences
        guard jsti_window_set_escape_cancellation(preferences.cancelRecordingOnEscape ? 1 : 0) == 0 else {
            throw DesktopConfigurationError.invalidField("Escape cancellation")
        }
        holder.gestures.configureTiming(
            hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
        )
        let strings = Strings()
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
                            linuxConfigurationEvent, Unmanaged.passUnretained(holder).toOpaque(), $0
                        )
                    }
                }
            }
        }
        guard result == 0 else { throw DesktopConfigurationError.invalidField("Native preferences") }
        guard let qualityIndex = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == VoiceSynthesisPreference.quality.key.rawValue
        }), jsti_window_set_configuration_field_enabled(qualityIndex, snapshot.qualityEnabled ? 1 : 0) >= 0 else {
            throw DesktopConfigurationError.invalidField("Voice quality availability")
        }
        try configureConfigurationLayout(preferences, strings: strings)
        try await configureActionShortcuts(holder)
    }

    private static func configureConfigurationLayout(_ preferences: DesktopConfiguration, strings: Strings) throws {
        let density = preferences.visualDensity
        let layout = JSTIVisualDensity(
            compact: density.isCompact ? 1 : 0,
            page_padding: Int32(density.pagePadding), section_spacing: Int32(density.sectionSpacing),
            card_padding: Int32(density.cardPadding), content_spacing: Int32(density.cardContentSpacing),
            inline_spacing: Int32(density.inlineSpacing), group_spacing: Int32(density.groupSpacing),
            minimum_row_height: Int32(density.minimumListRowHeight)
        )
        guard jsti_window_set_visual_density(layout) == 0 else {
            throw DesktopConfigurationError.invalidField("Layout density")
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
        guard sidebar == 0 else { throw DesktopConfigurationError.invalidField("Sidebar shortcuts") }
    }

    static func performConfigurationAction(
        _ action: Int32, values: [String], holder: LinuxEventContext, editorID: String? = nil
    ) async throws {
        switch action {
        case 0: try await holder.controller.saveConfiguration(values, intent: .apply, editorID: editorID)
        case 1: try await holder.controller.importConfiguration(path: values[0])
        case 2: try await holder.controller.exportConfiguration(path: values[0])
        case 3:
            guard let selected = values.last else {
                throw DesktopConfigurationError.invalidField("Recovered keyword selection")
            }
            try await holder.controller.recoverConfigurationKeywords(
                Array(values.dropLast()), selected: selected, editorID: editorID
            )
        case 4, 5:
            try await holder.controller.previewRecordingFeedback(
                action == 4 ? .start : .stop, configurationEntries: values, editorID: editorID
            )
        default: throw DesktopConfigurationError.invalidField("Configuration action")
        }
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
    guard let context, let entries else { return -1 }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let received = UnsafeBufferPointer(start: entries, count: count).map { $0.map(String.init(cString:)) ?? "" }
    do {
        switch try DesktopHostConfigurationEditorEvent(action: action, values: received) {
        case .rendered(let id):
            holder.enqueueSettings {
                do { try await holder.controller.activateConfigurationEditorSnapshot(id) } catch {
                    LinuxHostPlatform.update(error.localizedDescription)
                }
            }
        case .action(let action, let values, let editorID):
            holder.enqueueSettings {
                do {
                    try await LinuxWindow.performConfigurationAction(
                        action, values: values, holder: holder, editorID: editorID
                    )
                } catch {
                    LinuxHostPlatform.update(error.localizedDescription)
                    do { try await LinuxWindow.configureConfiguration(holder) } catch {
                        LinuxHostPlatform.update(error.localizedDescription)
                    }
                }
            }
        }
        return 0
    } catch {
        if let buffer = errorBuffer, capacity > 0 {
            let bytes = Array(error.localizedDescription.utf8CString.prefix(capacity - 1)) + [0]
            bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
        }
        return -1
    }
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
