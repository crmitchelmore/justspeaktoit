#if os(iOS)
import AVFoundation
import Foundation

/// Reusable pool of `AVAudioPCMBuffer`s so audio tap callbacks can copy the
/// engine's buffer and hop off the real-time audio thread without allocating
/// on every callback. Mirrors the macOS `OpenAIRealtimePCMBufferPool`.
final class PCMBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBuffers: Int
    private var buffers: [AVAudioPCMBuffer] = []

    init(maximumBuffers: Int) {
        self.maximumBuffers = maximumBuffers
    }

    func buffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if let index = buffers.firstIndex(where: { $0.format == format && $0.frameCapacity >= frameCapacity }) {
            let buffer = buffers.remove(at: index)
            buffer.frameLength = 0
            return buffer
        }

        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
    }

    /// Copies `buffer` into a pooled buffer. Cheap enough for the real-time
    /// audio thread: a pool checkout plus one memcpy per channel.
    func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = buffer.frameLength
        guard let copy = self.buffer(format: buffer.format, frameCapacity: max(frameLength, 1)) else {
            return nil
        }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
        for idx in 0..<min(src.count, dst.count) {
            let srcBuffer = src[idx]
            guard let srcData = srcBuffer.mData, let dstData = dst[idx].mData else { continue }
            dstData.copyMemory(from: srcData, byteCount: Int(srcBuffer.mDataByteSize))
            dst[idx].mDataByteSize = srcBuffer.mDataByteSize
        }
        return copy
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard buffers.count < maximumBuffers else { return }
        buffer.frameLength = 0
        buffers.append(buffer)
    }
}
#endif
