@preconcurrency import AVFoundation
import CAppleAudioSupport
import Foundation

/// AVFAudio rejects a tap by raising an Objective-C exception, which Swift
/// cannot catch: the process aborts. That happens when the tap format no longer
/// matches the hardware (Bluetooth profile switch, sleep, sample-rate change),
/// the bus already has a tap, or the node has left its engine. Capture code
/// must use `installTapSafely` so a rejected tap becomes a recoverable error.
public struct AudioTapInstallationError: LocalizedError, Equatable, Sendable {
    public let exceptionName: String
    public let reason: String

    public init(exceptionName: String, reason: String) {
        self.exceptionName = exceptionName
        self.reason = reason
    }

    public var errorDescription: String? {
        "The microphone could not be opened. \(reason)"
    }
}

extension AVAudioNode {
    /// Installs a tap like `installTap(onBus:bufferSize:format:block:)`, but
    /// throws `AudioTapInstallationError` instead of aborting the app when
    /// AVFAudio rejects the tap.
    public func installTapSafely(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        var error: NSError?
        guard SPKInstallAudioTap(self, UInt(bus), bufferSize, format, block, &error) else {
            throw AudioTapInstallationError(
                exceptionName: error?.userInfo[SPKAudioTapExceptionNameKey] as? String ?? "unknown",
                reason: error?.localizedFailureReason ?? "The audio input rejected the tap."
            )
        }
    }
}
