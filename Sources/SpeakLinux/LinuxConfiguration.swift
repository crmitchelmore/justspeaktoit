import Foundation
import SpeakCore
import CLinuxSupport

extension LinuxWindow {
    static func configureConfiguration(_ holder: LinuxEventContext) async throws {
        let preferences = try await holder.controller.configuration()
        holder.gestures.configureTiming(
            hold: preferences.number("holdThreshold"), doubleTap: preferences.number("doubleTapWindow")
        )
        let strings = Strings()
        let rows = zip(DesktopConfiguration.fields, preferences.entries).map { field, value in
            JSTIConfigurationField(
                title: strings.add(field.title), value: strings.add(value), group: strings.add(field.group),
                is_boolean: { if case .boolean = field.kind { return 1 }; return 0 }()
            )
        }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer {
                jsti_window_set_configuration(
                    $0.baseAddress, $0.count, linuxConfigurationEvent,
                    Unmanaged.passUnretained(holder).toOpaque()
                )
            }
        }
        guard result == 0 else { throw DesktopConfigurationError.invalidField("Native preferences") }
    }
}

func linuxConfigurationEvent(
    _ action: Int32, _ entries: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let context, let entries else { return -1 }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let values = UnsafeBufferPointer(start: entries, count: count).map { $0.map(String.init(cString:)) ?? "" }
    do {
        if action == 0 { _ = try DesktopConfiguration().applying(values) }
        else if !(action == 1 || action == 2) || values.count != 1 {
            throw DesktopConfigurationError.invalidField("Configuration action")
        }
        holder.enqueueSettings {
            do {
                switch action {
                case 0: try await holder.controller.saveConfiguration(values)
                case 1: try await holder.controller.importConfiguration(path: values[0])
                case 2: try await holder.controller.exportConfiguration(path: values[0])
                default: return
                }
                try await LinuxWindow.configureConfiguration(holder)
            } catch {
                LinuxHostPlatform.update(error.localizedDescription)
                do { try await LinuxWindow.configureConfiguration(holder) }
                catch { LinuxHostPlatform.update(error.localizedDescription) }
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
