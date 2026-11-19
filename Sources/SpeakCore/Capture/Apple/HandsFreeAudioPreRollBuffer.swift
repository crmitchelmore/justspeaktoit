@preconcurrency import AVFoundation
import Foundation

/// A short, memory-only rolling audio window used to preserve speech that
/// arrives while capture is starting. Buffers are never written or forwarded
/// until a speech boundary is reported.
public final class HandsFreeAudioPreRollBuffer: @unchecked Sendable {
    private let duration: TimeInterval
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var bufferedFrames: AVAudioFramePosition = 0

    public init(duration: TimeInterval = HandsFreeDictationPolicy.preRollSeconds) {
        self.duration = max(0, duration)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer), copy.format.sampleRate > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        buffers.append(copy)
        bufferedFrames += AVAudioFramePosition(copy.frameLength)
        let maximumFrames = AVAudioFramePosition(copy.format.sampleRate * duration)
        while bufferedFrames > maximumFrames, buffers.count > 1 {
            bufferedFrames -= AVAudioFramePosition(buffers.removeFirst().frameLength)
        }
    }

    /// Returns the current immutable snapshot and clears the rolling window.
    public func takeSnapshot() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = buffers
        buffers.removeAll(keepingCapacity: true)
        bufferedFrames = 0
        return snapshot
    }

    public func reset() {
        lock.lock()
        buffers.removeAll(keepingCapacity: true)
        bufferedFrames = 0
        lock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0 ..< min(source.count, destination.count) {
            let sourceBuffer = source[index]
            let destinationBuffer = destination[index]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                continue
            }
            let byteCount = Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
        }
        return copy
    }
}
