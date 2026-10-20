import Foundation

/// One immutable run's borrowed native callback context; retained until real retirement.
package final class DesktopOwnedCaptureCallbackBridge: Sendable {
    package let id: UUID
    package let identity: DesktopPressCaptureIdentity
    private let receive: @Sendable (Data) -> Void
    private let onFailure: @Sendable (String) -> Void

    package init(
        id: UUID, identity: DesktopPressCaptureIdentity,
        receive: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.id = id
        self.identity = identity
        self.receive = receive
        self.onFailure = onFailure
    }

    package func receivePCM(_ samples: UnsafePointer<Int16>?, count: Int) {
        guard [16000, 24000].contains(identity.sampleRate), [20, 100].contains(identity.frameMilliseconds) else {
            fail("Native capture returned an unsupported PCM format.")
            return
        }
        let maximum = identity.sampleRate * identity.frameMilliseconds / 1000
        guard count > 0, count <= maximum, count <= 2400, let samples else {
            fail("Native capture returned an invalid PCM frame.")
            return
        }
        receive(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
    }

    package func fail(_ message: String) {
        onFailure(String(message.prefix(1024)))
    }
}
