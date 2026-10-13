import Foundation
import SpeakCore
import CWindowsSupport

extension WindowsNative {
    final class ConfigurationStrings {
        private var owned: [UnsafeMutablePointer<CChar>] = []
        func add(_ value: String) -> UnsafePointer<CChar> {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            owned.append(pointer)
            return UnsafePointer(pointer)
        }
        deinit { owned.forEach { $0.deallocate() } }
    }

    static func configureConfiguration(_ holder: WindowsEventContext) async throws {
        let preferences = try await holder.controller.configuration()
        holder.hotKeys.configureTiming(
            hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
        )
        let strings = ConfigurationStrings()
        let rows = zip(DesktopConfiguration.fields, preferences.entries).map { field, value in
            JSTIConfigurationField(
                title: strings.add(field.title), value: strings.add(value), group: strings.add(field.group),
                is_boolean: { if case .boolean = field.kind { return 1 }; return 0 }(),
                requires_hud_overlay: field.requiresHUDOverlay ? 1 : 0
            )
        }
        let recovered: [UnsafePointer<CChar>?] = preferences.recoveredKeywords.map { strings.add($0) }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { fields in
                recovered.withUnsafeBufferPointer { recovery in
                    jsti_window_set_configuration(
                        fields.baseAddress, fields.count, recovery.baseAddress, recovery.count,
                        windowsConfigurationEvent, Unmanaged.passUnretained(holder).toOpaque()
                    )
                }
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not display dictation preferences.") }
    }

    static func performConfigurationAction(
        _ action: Int32, values: [String], holder: WindowsEventContext
    ) async throws {
        switch action {
        case 0: try await holder.controller.saveConfiguration(values)
        case 1: try await holder.controller.importConfiguration(path: values[0])
        case 2: try await holder.controller.exportConfiguration(path: values[0])
        case 3:
            guard let selected = values.last else {
                throw DesktopConfigurationError.invalidField("Recovered keyword selection")
            }
            try await holder.controller.recoverConfigurationKeywords(Array(values.dropLast()), selected: selected)
        default: throw DesktopConfigurationError.invalidField("Configuration action")
        }
        try await configureConfiguration(holder)
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func windowsConfigurationEvent(
    _ action: Int32, _ entries: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let context, let entries else { return -1 }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let values = UnsafeBufferPointer(start: entries, count: count).map { $0.map(String.init(cString:)) ?? "" }
    do {
        if action == 0 { try DesktopConfiguration.validateEntries(values) } else if action == 3 {
            guard values.count == DesktopConfiguration.fields.count + 1 else {
                throw DesktopConfigurationError.invalidField("Recovered keyword selection")
            }
            try DesktopConfiguration.validateEntries(Array(values.dropLast()))
        } else if
            !(action == 1 || action == 2) || values.count != 1 {
            throw DesktopConfigurationError.invalidField("Configuration action")
        }
        holder.enqueueSettings {
            do {
                try await WindowsNative.performConfigurationAction(action, values: values, holder: holder)
            } catch {
                WindowsNative.update(error.localizedDescription)
                do { try await WindowsNative.configureConfiguration(holder) } catch {
                    WindowsNative.update(error.localizedDescription)
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
