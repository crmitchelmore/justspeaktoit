import Foundation

/// Regions describe relay admission order at reserve, not physical sample or gesture timestamps.
package struct DesktopPressCapturePCMDelivery: Equatable, Sendable {
    package let token: DesktopPressCaptureToken
    package let identity: DesktopPressCaptureIdentity
    private let pcm: DesktopPressCapturePCMBuffer

    package var data: Data { pcm.data }
    package var beforeReservationSampleCount: Int { pcm.beforeReservationSampleCount }
    /// Mono PCM16 sample offsets within this payload, not Data collection indices.
    package var beforeReservationSamples: Range<Int> { 0..<beforeReservationSampleCount }
    package var afterReservationSamples: Range<Int> { beforeReservationSampleCount..<(data.count / 2) }

    init(token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity, pcm: DesktopPressCapturePCMBuffer) {
        self.token = token
        self.identity = identity
        self.pcm = pcm
    }
}

struct DesktopPressCapturePCMBuffer: Equatable, Sendable {
    let data: Data
    let beforeReservationSampleCount: Int

    /// Only the relay constructs this, after validating PCM and snapshotting its prefix under the state lock.
    init(data: Data, beforeReservationSampleCount: Int) {
        precondition(data.count.isMultiple(of: 2))
        precondition(beforeReservationSampleCount >= 0 && beforeReservationSampleCount <= data.count / 2)
        self.data = data
        self.beforeReservationSampleCount = beforeReservationSampleCount
    }
}
