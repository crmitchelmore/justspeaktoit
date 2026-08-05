#if os(iOS)
import AVFoundation
import Foundation
import os.log

/// Reusable pool of `AVAudioPCMBuffer`s so audio tap callbacks can copy the
/// engine's buffer and hop off the real-time audio thread without allocating
/// on every callback. Mirrors the macOS `OpenAIRealtimePCMBufferPool`.
final class PCMBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBuffers: Int
    private var buffers: [AVAudioPCMBuffer] = []
    /// Buffers handed out plus buffers sitting idle. `maximumBuffers` caps this,
    /// not just the idle list, so a consumer backlog can't make the audio thread
    /// allocate without bound.
    private var allocatedBuffers = 0
    /// Number of checkouts refused because the pool was exhausted. Bounded frame
    /// loss under a pathological backlog beats unbounded memory growth on a live
    /// capture path; the counter makes that loss visible instead of silent.
    private var exhaustedCheckouts = 0

    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "PCMBufferPool")

    init(maximumBuffers: Int) {
        self.maximumBuffers = maximumBuffers
    }

    /// Checkouts refused so far because every allocated buffer was in flight.
    var exhaustedCheckoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exhaustedCheckouts
    }

    func buffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if let index = buffers.firstIndex(where: { $0.format == format && $0.frameCapacity >= frameCapacity }) {
            let buffer = buffers.remove(at: index)
            buffer.frameLength = 0
            return buffer
        }

        if allocatedBuffers >= maximumBuffers {
            // At the cap. An idle buffer of the wrong format/capacity is worth
            // less than the one we need, so retire it and allocate in its place.
            guard !buffers.isEmpty else {
                exhaustedCheckouts += 1
                logger.debug(
                    "PCM buffer pool exhausted (\(self.maximumBuffers) in flight); dropping frame"
                )
                return nil
            }
            buffers.removeFirst()
            allocatedBuffers -= 1
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        allocatedBuffers += 1
        return buffer
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

        guard buffers.count < maximumBuffers else {
            // Foreign buffer (or a duplicate return): dropping it keeps the idle
            // list bounded. Don't touch `allocatedBuffers` — it only tracks the
            // buffers this pool created.
            return
        }
        buffer.frameLength = 0
        buffers.append(buffer)
    }
}
#endif
