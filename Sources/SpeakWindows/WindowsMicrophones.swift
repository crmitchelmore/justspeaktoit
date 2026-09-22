import Foundation
import CWindowsSupport

private final class MicrophoneList {
    var devices: [(id: String, name: String)] = [("", "Default communications microphone")]
}

private func microphoneFound(
    _ identifier: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?,
    _ isDefault: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard let identifier, let name, let context else { return }
    let list = Unmanaged<MicrophoneList>.fromOpaque(context).takeUnretainedValue()
    let label = String(cString: name) + (isDefault != 0 ? " (system default)" : "")
    list.devices.append((String(cString: identifier), label))
}

/// One native worker owns subscription, enumeration and notification coalescing.
/// The callback is stateless: no Swift context pointer can outlive its owner.
final class WindowsMicrophoneMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init() throws {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = jsti_audio_device_monitor_create(microphonesChanged, nil, &error, error.count) else {
            throw WindowsNativeError(message: String(cString: error))
        }
        self.handle = handle
    }

    deinit { stop() }

    /// Nonblocking; called on UI close before the window disappears.
    func cancel() {
        lock.withLock { if let handle { jsti_audio_device_monitor_cancel(handle) } }
    }

    /// Drains the native worker outside the UI/controller actor.
    func stop() {
        let owned = lock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        if let owned { _ = jsti_audio_device_monitor_destroy(owned, nil, 0) }
    }
}

private func microphonesChanged(
    _ devices: UnsafePointer<JSTIAudioDevice>?, _ count: Int,
    _ error: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    // Copies into the window's latest-only mailbox before this callback returns;
    // it neither reads settings nor changes the session's captured endpoint.
    _ = jsti_window_refresh_microphones(devices, count, error)
}

extension WindowsNative {
    static func createCapture(
        context: WindowsCaptureContext, deviceID: String, sampleRate: Int = 16_000
    ) throws -> OpaquePointer {
        guard sampleRate == 16_000 || sampleRate == 24_000 else {
            throw WindowsNativeError(message: "This transcription model requires an unsupported recording rate.")
        }
        var error = [CChar](repeating: 0, count: 1024)
        let native = deviceID.withCString { device in
            jsti_capture_create_with_format(
                device, UInt32(sampleRate), captureAudio, captureError,
                Unmanaged.passUnretained(context).toOpaque(), &error, error.count
            )
        }
        guard let native else { throw WindowsNativeError(message: String(cString: error)) }
        return native
    }

    static func configureMicrophones(selected: String, smokeTest: Bool) throws -> String? {
        let list = MicrophoneList()
        var warning: String?
        if smokeTest {
            list.devices.append(("jsti-synthetic-smoke-input", "Synthetic test microphone"))
        } else {
            do {
                try checked {
                    jsti_audio_devices_enumerate(microphoneFound, Unmanaged.passUnretained(list).toOpaque(), $0, $1)
                }
            } catch { warning = "Microphone list unavailable: \(error.localizedDescription)" }
        }
        if !list.devices.contains(where: { $0.id == selected }) {
            list.devices.append((selected, "Previously selected microphone (unavailable)"))
        }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { $0.deallocate() } }
        func pointer(_ value: String) -> UnsafePointer<CChar>? {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            owned.append(pointer)
            return UnsafePointer(pointer)
        }
        let ids = list.devices.map { pointer($0.id) }
        let names = list.devices.map { pointer($0.name) }
        let result = ids.withUnsafeBufferPointer { ids in
            names.withUnsafeBufferPointer { names in
                selected.withCString { jsti_window_set_microphones(ids.baseAddress, names.baseAddress, ids.count, $0) }
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure microphone choices.") }
        return warning
    }
}

extension WindowsAppController {
    func selectedMicrophone() -> String { settings.microphoneDeviceID ?? "" }
    func setMicrophoneWarning(_ warning: String?) { microphoneWarning = warning }

    func selectMicrophone(_ identifier: String) {
        guard canUseHistory else { return }
        var changed = settings
        changed.microphoneDeviceID = identifier.isEmpty ? nil : identifier
        do {
            try JSONEncoder().encode(changed).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            settings = changed
        } catch { update("Could not save the microphone choice: \(error.localizedDescription)") }
    }
}
