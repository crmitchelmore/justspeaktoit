import Foundation
import SpeakDesktop
import CLinuxSupport

/// One microphone capture through libpulse (PipeWire's pulse server on
/// current desktops), created stopped. Frames of mono PCM16 arrive on the
/// audio thread. `destroy` runs once; no callback runs after it returns.
public final class LinuxAudioCapture: @unchecked Sendable {
    /// Borrowed by the native callbacks until destroy has joined them.
    fileprivate final class Sink {
        let audio: (UnsafeBufferPointer<Int16>) -> Void
        let failure: (String) -> Void
        init(audio: @escaping (UnsafeBufferPointer<Int16>) -> Void, failure: @escaping (String) -> Void) {
            self.audio = audio
            self.failure = failure
        }
    }

    private let native: OpaquePointer
    private let callbacks: NativeCallbackContext<Sink>
    private let lock = NSLock()
    private var destroyed = false

    public init(
        device: String, sampleRate: Int, frameMilliseconds: Int,
        audio: @escaping (UnsafeBufferPointer<Int16>) -> Void, failure: @escaping (String) -> Void
    ) throws {
        let callbacks = NativeCallbackContext(Sink(audio: audio, failure: failure))
        var error = [CChar](repeating: 0, count: 1024)
        let created = device.withCString {
            jsti_capture_create(
                $0, UInt32(sampleRate), UInt32(frameMilliseconds), linuxCaptureAudio, linuxCaptureError,
                callbacks.pointer, &error, error.count
            )
        }
        guard let created else {
            callbacks.release()
            throw LinuxNativeError(message: String(cString: error))
        }
        self.native = created
        self.callbacks = callbacks
    }

    deinit { destroy() }

    public func start() throws { try LinuxNative.call { jsti_capture_start(native, $0, $1) } }

    /// Delivers the remaining buffered audio before returning.
    public func stop() throws { try LinuxNative.call { jsti_capture_stop(native, $0, $1) } }

    public func destroy() {
        let first = lock.withLock { () -> Bool in
            defer { destroyed = true }
            return !destroyed
        }
        guard first else { return }
        jsti_capture_destroy(native)
        callbacks.release()
    }

    public struct Device: Equatable, Sendable {
        public let id: String
        public let name: String
        public let isDefault: Bool
    }

    /// Microphones the sound server offers now; speaker monitors are excluded.
    public static func devices() throws -> [Device] {
        let list = DeviceList()
        try NativeCallbackContext.withScoped(list) { context in
            try LinuxNative.call { jsti_audio_devices_enumerate(linuxDeviceFound, context, $0, $1) }
        }
        return list.devices
    }
}

/// Devices enumerated synchronously on the calling thread.
private final class DeviceList {
    var devices: [LinuxAudioCapture.Device] = []
}

private func linuxCaptureAudio(_ samples: UnsafePointer<Int16>?, _ count: Int, _ context: UnsafeMutableRawPointer?) {
    guard let samples, let sink = NativeCallbackContext<LinuxAudioCapture.Sink>.resolve(context) else { return }
    sink.audio(UnsafeBufferPointer(start: samples, count: count))
}

private func linuxCaptureError(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    let sink = NativeCallbackContext<LinuxAudioCapture.Sink>.resolve(context)
    sink?.failure(message.map(String.init(cString:)) ?? "Microphone capture failed.")
}

private func linuxDeviceFound(
    _ id: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?, _ isDefault: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard let id, let name, let list = NativeCallbackContext<DeviceList>.resolve(context) else { return }
    list.devices.append(
        .init(id: String(cString: id), name: String(cString: name), isDefault: isDefault != 0)
    )
}
