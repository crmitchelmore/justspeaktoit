import Foundation
import SpeakDesktopHost
import CWindowsSupport

/// Owns one native idle preparation (WindowsCapturePrewarm.cpp). It resolves
/// the endpoint and keeps the device enumerator resident but never activates
/// an audio client, so the microphone stays closed.
final class WindowsCapturePreparation: DesktopCapturePreparation, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init?(deviceID: String, lifetimeMilliseconds: UInt32) {
        var error = [CChar](repeating: 0, count: 256)
        let capacity = error.count
        let native = deviceID.withCString { device in
            jsti_capture_prewarm_create(device, lifetimeMilliseconds, &error, capacity)
        }
        guard let native else { return nil }
        handle = native
    }

    deinit { release() }

    var isActive: Bool {
        lock.withLock {
            guard let handle else { return false }
            let state = jsti_capture_prewarm_state(handle)
            return state == 0 || state == 1
        }
    }

    func release() {
        let owned = lock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        if let owned { jsti_capture_prewarm_destroy(owned) }
    }
}
