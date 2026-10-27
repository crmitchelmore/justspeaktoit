import AVFoundation
import Foundation
import SpeakCore

/// Plays linear PCM as it arrives, so speech starts before synthesis finishes.
///
/// The file players the other providers use cannot open a growing file, so a
/// progressive provider schedules its chunks on an `AVAudioPlayerNode` instead.
/// One instance owns one utterance: `prepare` opens the engine, `enqueue`
/// schedules whatever whole samples have arrived, and `stop` tears everything
/// down. A partial sample at the end of a chunk is held until its remaining
/// bytes arrive, because scheduling half a frame would click.
@MainActor
final class TTSProgressivePlayer {
    private let makeEngine: () -> AVAudioEngine

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pending = Data()
    private var state = TTSProgressivePlaybackState()
    private var isPaused = false
    private var drainContinuation: CheckedContinuation<Void, Never>?

    /// Seconds of audio that may sit scheduled ahead of what has been heard.
    ///
    /// A streaming provider can generate far faster than real time, so without a
    /// ceiling a long utterance accumulates the whole document in scheduled
    /// buffers. Ten seconds is more than enough to ride out a network stall.
    static let scheduledAheadLimit = TTSProgressivePlaybackState.scheduledAheadLimit
    /// Longest one chunk waits for that headroom before being scheduled anyway.
    /// Playback that is paused indefinitely must not stall the socket forever.
    static let headroomWaitLimit: TimeInterval = 5
    private static let headroomPollInterval: TimeInterval = 0.05

    /// Whether an utterance is currently scheduled or playing.
    var isActive: Bool { state.isActive }

    func prepare(sampleRate: Int) throws {
        _ = try prepare(sampleRate: sampleRate, mode: .legacy)
    }

    /// Opt-in preparation; no app routing uses this entry until its own gate is enabled.
    func prepareOwned(sampleRate: Int) throws -> TTSProgressivePlaybackState.SessionID {
        try Task.checkCancellation()
        return try prepare(sampleRate: sampleRate, mode: .bounded)
    }

    private func prepare(
        sampleRate: Int, mode: TTSProgressivePlaybackState.Mode
    ) throws -> TTSProgressivePlaybackState.SessionID {
        stop()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate), channels: 1
        ) else {
            throw TTSError.audioPlaybackFailure
        }
        let engine = makeEngine()
        let player = AVAudioPlayerNode()
        let owner: TTSProgressivePlaybackState.SessionID
        do {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            owner = try state.begin(sampleRate: sampleRate, mode: mode)
        } catch {
            state.stop()
            player.stop()
            engine.stop()
            throw TTSError.audioPlaybackFailure
        }
        self.engine = engine
        self.player = player
        self.format = format
        return owner
    }

    /// Schedules every whole sample in `data`, holding a trailing partial sample
    /// for the next chunk. Returns `false` when there was nothing whole to play
    /// yet, which is not a failure.
    @discardableResult
    func enqueue(_ data: Data) throws -> Bool {
        guard isActive, let owner = state.session else { return false }
        guard state.mode == .legacy else { throw TTSError.audioPlaybackFailure }
        pending.append(data)
        let sampleSize = MemoryLayout<Int16>.size
        let wholeByteCount = pending.count - pending.count % sampleSize
        guard wholeByteCount > 0 else { return false }
        let payload = pending.prefix(wholeByteCount)
        pending.removeFirst(wholeByteCount)

        let frameCount = AVAudioFrameCount(wholeByteCount / sampleSize)
        try schedule(Data(payload), frames: frameCount, owner: owner)
        return true
    }

    private func schedule(
        _ payload: Data, frames frameCount: AVAudioFrameCount, owner: TTSProgressivePlaybackState.SessionID
    ) throws {
        try state.requireCurrent(owner)
        guard let format, let player,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0],
            let samples = TTSProgressivePCMConversion.samples(from: payload),
            samples.count == Int(frameCount)
        else {
            throw TTSError.audioPlaybackFailure
        }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        buffer.frameLength = frameCount
        do { try state.reserve(frames: Int(frameCount), owner: owner) } catch {
            if error is CancellationError { throw error }
            throw TTSError.audioPlaybackFailure
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didFinishBuffer(frames: Int(frameCount), owner: owner) }
        }
        if !player.isPlaying, state.mode == .legacy || !isPaused { player.play() }
    }

    /// Waits until every scheduled buffer has been heard, so a caller can report
    /// playback finished rather than guessing from the synthesis time.
    func waitUntilDrained() async {
        guard isActive, state.scheduledBuffers > 0 else { return }
        await withCheckedContinuation { continuation in
            self.drainContinuation = continuation
        }
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        guard isActive else { return }
        isPaused = false
        if engine?.isRunning == false { try? engine?.start() }
        if player?.isPlaying == false { player?.play() }
    }

    func stop() {
        // Invalidate identity before native stop can trigger delayed completions.
        state.stop()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        pending.removeAll(keepingCapacity: false)
        isPaused = false
        drainContinuation?.resume()
        drainContinuation = nil
    }

    private func didFinishBuffer(frames: Int, owner: TTSProgressivePlaybackState.SessionID) {
        guard state.complete(frames: frames, owner: owner) else { return }
        drainContinuation?.resume()
        drainContinuation = nil
    }

    /// Seconds of scheduled audio that have not been heard yet.
    var scheduledAheadSeconds: TimeInterval {
        state.scheduledSeconds
    }

    /// Waits, up to `headroomWaitLimit`, until the scheduled audio falls back
    /// under the ahead-of-playback ceiling.
    ///
    /// Bounded rather than open-ended: a paused or stalled engine would
    /// otherwise hold a provider socket open indefinitely, which is a worse
    /// failure than briefly exceeding the ceiling.
    func waitForHeadroom(now: () -> Date = Date.init) async {
        let deadline = now().addingTimeInterval(Self.headroomWaitLimit)
        while isActive, scheduledAheadSeconds >= Self.scheduledAheadLimit, now() < deadline {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.headroomPollInterval * 1_000_000_000)
            )
        }
    }

    /// Strict entry: reserve room for this aligned <=100 ms chunk before enqueue.
    /// A paused/stalled player fails rather than exceeding the ten-second queue.
    func enqueue(_ data: Data, session owner: TTSProgressivePlaybackState.SessionID) async throws {
        do {
            try Task.checkCancellation()
            try state.requireCurrent(owner)
            guard !data.isEmpty, data.count % 2 == 0,
                  data.count / 2 <= state.maximumChunkFrames else { throw TTSError.audioPlaybackFailure }
            let frames = data.count / 2
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(Self.headroomWaitLimit))
            while try !state.hasHeadroom(for: frames, owner: owner) {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw TTSError.audioPlaybackFailure }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            try state.requireCurrent(owner)
            guard clock.now < deadline else { throw TTSError.audioPlaybackFailure }
            try schedule(data, frames: AVAudioFrameCount(frames), owner: owner)
        } catch {
            stop(session: owner)
            throw error
        }
    }

    /// Only strict sessions use this bounded, cancellation-aware drain. The
    /// existing no-argument continuation entry retains its legacy behavior.
    func waitUntilDrained(session owner: TTSProgressivePlaybackState.SessionID) async throws {
        do {
            try Task.checkCancellation()
            try state.requireCurrent(owner)
            guard state.mode == .bounded else { throw TTSError.audioPlaybackFailure }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(state.scheduledSeconds + Self.headroomWaitLimit))
            while state.scheduledBuffers > 0 {
                try Task.checkCancellation()
                try state.requireCurrent(owner)
                guard clock.now < deadline else { throw TTSError.audioPlaybackFailure }
                try await Task.sleep(for: .milliseconds(50))
            }
            try state.requireCurrent(owner)
            try Task.checkCancellation()
            guard clock.now < deadline else { throw TTSError.audioPlaybackFailure }
        } catch {
            stop(session: owner)
            throw error
        }
    }

    /// Cleanup from a cancelled/replaced request must not stop another engine.
    func stop(session owner: TTSProgressivePlaybackState.SessionID) {
        guard state.session == owner else { return }
        stop()
    }
}

extension TTSProgressivePlayer {
    /// Plays a streaming provider's audio as it arrives and answers the finished
    /// result, which is the same complete `TTSResult` the batch path returns.
    ///
    /// Each chunk is scheduled from inside the provider's own callback, which
    /// the provider awaits. That keeps the speech in order without a second
    /// task, lets a full playback queue hold the provider back, and lets a
    /// scheduling failure end the stream: a thrown error — a barge-in
    /// cancellation or a playback failure — stops the engine, discards the
    /// partial audio and reaches the caller as a failed synthesis.
    func speak(
        text: String,
        voice: String,
        settings: TTSSettings,
        using client: any ProgressiveTextToSpeechClient
    ) async throws -> TTSResult {
        // A cancelled utterance must not open the audio device or provider stream.
        try Task.checkCancellation()
        let owner = try prepare(sampleRate: client.progressiveSampleRate, mode: .legacy)
        do {
            let result = try await client.synthesizeProgressively(
                text: text, voice: voice, settings: settings
            ) { [weak self] chunk in
                guard let self else { throw CancellationError() }
                try await self.schedule(chunk, owner: owner)
            }
            do {
                try Task.checkCancellation()
                try state.requireCurrent(owner)
                await waitUntilDrained()
                try Task.checkCancellation()
                try state.requireCurrent(owner)
                stop(session: owner)
                return result
            } catch {
                // The client has transferred its completed file to this wrapper,
                // but the manager cannot own it until this method returns it.
                try? FileManager.default.removeItem(at: result.audioURL)
                throw error
            }
        } catch {
            stop(session: owner)
            throw error
        }
    }

    /// Schedules one arriving chunk, first waiting for playback headroom.
    private func schedule(_ chunk: Data, owner: TTSProgressivePlaybackState.SessionID) async throws {
        await waitForHeadroom()
        try Task.checkCancellation()
        try state.requireCurrent(owner)
        try enqueue(chunk)
    }
}
