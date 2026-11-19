#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

@MainActor
protocol SonioxPCMAudioPlaying: AnyObject {
    func prepare(streamID: String) throws
    func enqueue(_ data: Data, isFinal: Bool, streamID: String) throws -> Bool
    func waitUntilDrained(streamID: String) async
    func pause(streamID: String)
    func resume(streamID: String)
    func stop(streamID: String?)
}

struct SonioxPCMFrameAccumulator {
    private var pending = Data()

    mutating func append(_ data: Data, isFinal: Bool) throws -> Data {
        pending.append(data)
        let sampleSize = MemoryLayout<Int16>.size
        let completeByteCount = pending.count - pending.count % sampleSize
        let completeSamples = Data(pending.prefix(completeByteCount))
        pending.removeFirst(completeByteCount)
        guard !isFinal || pending.isEmpty else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        return completeSamples
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class SonioxPCMAudioPlayer: SonioxPCMAudioPlaying {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var streamID: String?
    private var scheduledBuffers = 0
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var frameAccumulator = SonioxPCMFrameAccumulator()
    /// The category this stream installed, if any; restored on stop. The
    /// session is never deactivated here, so a recorder that started meanwhile
    /// keeps its audio (the same lease every iOS voice output uses).
    private var sessionLease: VoiceOutputAudioSessionLease?

    func prepare(streamID: String) throws {
        stop(streamID: nil)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            sessionLease = try VoiceOutputAudioSessionLease.acquire()
            try AVAudioSession.sharedInstance().setActive(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
        } catch {
            player.stop()
            engine.stop()
            sessionLease?.restoreIfUnchanged()
            sessionLease = nil
            throw error
        }

        self.engine = engine
        self.player = player
        self.format = format
        self.streamID = streamID
    }

    func enqueue(_ data: Data, isFinal: Bool, streamID: String) throws -> Bool {
        guard self.streamID == streamID,
              let format,
              let player else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        let payload = try frameAccumulator.append(data, isFinal: isFinal)
        guard !payload.isEmpty else { return false }
        let frameCount = AVAudioFrameCount(payload.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0] else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        payload.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(channel, baseAddress, payload.count)
        }
        buffer.frameLength = frameCount
        scheduledBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didFinishBuffer(streamID: streamID) }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    func waitUntilDrained(streamID: String) async {
        guard self.streamID == streamID, scheduledBuffers > 0 else { return }
        await withCheckedContinuation { continuation in
            self.drainContinuation = continuation
        }
    }

    func pause(streamID: String) {
        guard self.streamID == streamID else { return }
        player?.pause()
    }

    func resume(streamID: String) {
        guard self.streamID == streamID else { return }
        // An interruption, for example a telephone call, deactivates the audio
        // session. The engine cannot start again until the session is active.
        try? AVAudioSession.sharedInstance().setActive(true)
        if engine?.isRunning == false { try? engine?.start() }
        if player?.isPlaying == false { player?.play() }
    }

    func stop(streamID: String?) {
        guard streamID == nil || self.streamID == streamID else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        self.streamID = nil
        scheduledBuffers = 0
        frameAccumulator.reset()
        drainContinuation?.resume()
        drainContinuation = nil
        sessionLease?.restoreIfUnchanged()
        sessionLease = nil
    }

    private func didFinishBuffer(streamID: String) {
        guard self.streamID == streamID else { return }
        scheduledBuffers = max(0, scheduledBuffers - 1)
        if scheduledBuffers == 0 {
            drainContinuation?.resume()
            drainContinuation = nil
        }
    }
}
#endif
