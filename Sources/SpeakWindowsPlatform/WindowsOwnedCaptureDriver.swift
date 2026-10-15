import CWindowsSupport
import Foundation
import SpeakDesktop

package struct WindowsOwnedCaptureDriverFactory: DesktopOwnedCaptureDriverFactory {
    private let fixtureFaults: UInt32?

    package init(fixtureFaults: UInt32? = nil) { self.fixtureFaults = fixtureFaults }

    package func makeDriver() -> WindowsOwnedCaptureDriver {
        WindowsOwnedCaptureDriver(fixtureFaults: fixtureFaults)
    }
}

/// Non-Sendable; created, used and retained exclusively by DesktopOwnedCaptureWorker.
package final class WindowsOwnedCaptureDriver: DesktopOwnedCaptureDriver {
    private let fixtureFaults: UInt32?
    private var owner: OpaquePointer?
    private var bridge: DesktopOwnedCaptureCallbackBridge?
    private var acquiredOwner = false

    init(fixtureFaults: UInt32?) { self.fixtureFaults = fixtureFaults }

    package func open(bridge: DesktopOwnedCaptureCallbackBridge) throws {
        guard self.bridge == nil, owner == nil else { throw DesktopPressCaptureError.occupied }
        self.bridge = bridge
        var receipt = makeReceipt()
        var error = [CChar](repeating: 0, count: 1024)
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        let audio: JSTIAudioCallback = { samples, count, value in
            guard let value else { return }
            Unmanaged<DesktopOwnedCaptureCallbackBridge>.fromOpaque(value).takeUnretainedValue()
                .receivePCM(samples, count: count)
        }
        let failed: JSTIAudioErrorCallback = { message, value in
            guard let value else { return }
            let bridge = Unmanaged<DesktopOwnedCaptureCallbackBridge>.fromOpaque(value).takeUnretainedValue()
            bridge.fail(message.map { String(cString: $0) } ?? "Native capture failed without a diagnostic.")
        }
        let result: Int32 = bridge.id.uuidString.withCString { id in
            if let faults = fixtureFaults {
                return jsti_owned_capture_open_fixture(
                    &owner, id, faults, UInt32(bridge.identity.sampleRate), UInt32(bridge.identity.frameMilliseconds),
                    audio, failed, context, &receipt, &error, error.count
                )
            }
            return bridge.identity.deviceID.withCString { device in
                jsti_owned_capture_open(
                    &owner, id, device, UInt32(bridge.identity.sampleRate), UInt32(bridge.identity.frameMilliseconds),
                    audio, failed, context, &receipt, &error, error.count
                )
            }
        }
        acquiredOwner = owner != nil
        if result != 0 { throw DesktopPressCaptureError.openFailed(String(cString: error)) }
        guard owner != nil else { throw DesktopPressCaptureError.openFailed("Native open returned no owned handle.") }
    }

    package func quiesce() throws -> DesktopOwnedCaptureReceipt {
        guard let bridge, let owner else { throw DesktopPressCaptureError.notReady }
        var receipt = makeReceipt()
        var error = [CChar](repeating: 0, count: 1024)
        let result = bridge.id.uuidString.withCString {
            jsti_owned_capture_quiesce(owner, $0, &receipt, &error, error.count)
        }
        let value = try copied(receipt)
        if let failure = value.audioFailure { bridge.fail(failure) }
        if result != 0 { throw DesktopPressCaptureError.captureFailed(String(cString: error)) }
        return value
    }

    package func retire() throws -> DesktopOwnedCaptureReceipt {
        // A known empty slot has never acquired resources (e.g. validation/allocation failure).
        guard let bridge else { throw DesktopPressCaptureError.invalidPhase }
        guard owner != nil else {
            guard !acquiredOwner else {
                throw DesktopPressCaptureError.cleanupFailed("Native retirement returned no valid ownership receipt.")
            }
            self.bridge = nil
            return .init(producerQuiesced: true, callbacksDrained: true, resourcesRetired: true)
        }
        var receipt = makeReceipt()
        var error = [CChar](repeating: 0, count: 1024)
        let result = bridge.id.uuidString.withCString {
            jsti_owned_capture_retire(&owner, $0, &receipt, &error, error.count)
        }
        let value = try copied(receipt)
        if let failure = value.audioFailure { bridge.fail(failure) }
        if result != 0 { throw DesktopPressCaptureError.cleanupFailed(String(cString: error)) }
        guard owner == nil, value.resourcesRetired else {
            throw DesktopPressCaptureError.cleanupFailed("Native retirement did not release its owner.")
        }
        acquiredOwner = false
        self.bridge = nil
        return value
    }

    private func makeReceipt() -> JSTIOwnedCaptureReceipt {
        var receipt = JSTIOwnedCaptureReceipt()
        receipt.size = UInt32(MemoryLayout<JSTIOwnedCaptureReceipt>.size)
        receipt.version = UInt32(JSTI_OWNED_CAPTURE_VERSION)
        return receipt
    }

    private func copied(_ receipt: JSTIOwnedCaptureReceipt) throws -> DesktopOwnedCaptureReceipt {
        guard receipt.size == UInt32(MemoryLayout<JSTIOwnedCaptureReceipt>.size),
              receipt.version == UInt32(JSTI_OWNED_CAPTURE_VERSION) else {
            throw DesktopPressCaptureError.cleanupFailed("Native capture returned an unsupported ownership receipt.")
        }
        let failure = try withUnsafeBytes(of: receipt.first_audio_error) {
            guard let value = String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) else {
                throw DesktopPressCaptureError.cleanupFailed("Native capture returned an invalid UTF-8 diagnostic.")
            }
            return value
        }
        return .init(
            producerQuiesced: receipt.flags & UInt32(JSTI_OWNED_PRODUCER_QUIESCED) != 0,
            callbacksDrained: receipt.flags & UInt32(JSTI_OWNED_CALLBACKS_DRAINED) != 0,
            resourcesRetired: receipt.flags & UInt32(JSTI_OWNED_RESOURCES_RETIRED) != 0,
            audioFailure: failure.isEmpty ? nil : failure
        )
    }

}
