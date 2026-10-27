#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// One OpenRouter response's output. Scheduling acknowledgment is not audible-output proof.
@MainActor
final class OpenRouterIOSProgressivePlayback {
    struct SessionID: Equatable, Sendable { private let value = UUID() }
    enum SetupFailure: Error { case unavailable }

    /// Actual native boundaries, replaceable without starting an audio device in ownership tests.
    struct Output {
        let start: () throws -> Void
        let schedule: (Data, @escaping @Sendable () -> Void) throws -> Void
        let stop: () -> Void
    }

    @MainActor
    struct Dependencies {
        var makeOutput: () throws -> Output = { try nativeOutput() }
        var acquireLease: () throws -> OpenRouterIOSAudioSessionLease? = { try .acquire() }
        var activate: () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) }
        var notifications: NotificationCenter = .default
        var now: () -> ContinuousClock.Instant = { ContinuousClock().now }
        var sleep: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
        var inspectedCompletion: () -> Void = {}
    }

    static let maximumFrames = OpenRouterProgressiveSpeechResult.sampleRate * 10
    static let maximumChunkFrames = OpenRouterProgressiveSpeechResult.sampleRate / 10
    static let headroomWait: Duration = .seconds(5)
    private let dependencies: Dependencies
    private var owner: SessionID?
    private var failure: (SessionID, OpenRouterIOSVoiceOutputError)?
    private var scheduledFrames = 0
    private var output: Output?
    private var lease: OpenRouterIOSAudioSessionLease?
    private var observers: [NSObjectProtocol] = []

    convenience init() {
        self.init(dependencies: Dependencies())
    }

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    var onInterruption: (() -> Void)?

    var isActive: Bool { owner != nil }
    var queuedFrames: Int { scheduledFrames }

    func start() throws -> SessionID {
        try Task.checkCancellation()
        stop()
        failure = nil
        let identifier = SessionID()
        owner = identifier
        do {
            lease = try dependencies.acquireLease()
            output = try dependencies.makeOutput()
            observeInterruptions(owner: identifier)
            try dependencies.activate()
            try output?.start()
            try requireCurrent(identifier)
            try Task.checkCancellation()
            return identifier
        } catch {
            stop(session: identifier)
            if error is CancellationError || error is OpenRouterIOSVoiceOutputError { throw error }
            throw SetupFailure.unavailable
        }
    }

    func enqueue(_ pcm: Data, session identifier: SessionID) async throws {
        do {
            try requireCurrent(identifier)
            try Task.checkCancellation()
            let bytes = OpenRouterProgressiveSpeechResult.bytesPerSample
            guard !pcm.isEmpty, pcm.count % bytes == 0 else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
            let frames = pcm.count / bytes
            guard frames <= Self.maximumChunkFrames else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
            let deadline = dependencies.now().advanced(by: Self.headroomWait)
            while scheduledFrames > Self.maximumFrames - frames {
                try requireCurrent(identifier)
                try Task.checkCancellation()
                guard dependencies.now() < deadline else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
                try await dependencies.sleep()
            }
            try requireCurrent(identifier)
            try Task.checkCancellation()
            guard dependencies.now() < deadline, let output else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
            // Reserve before the SDK can invoke its completion callback.
            scheduledFrames += frames
            try output.schedule(pcm) { [weak self] in
                Task { @MainActor in self?.didPlay(frames: frames, owner: identifier) }
            }
        } catch {
            stop(session: identifier)
            throw error
        }
    }

    func finish(session identifier: SessionID) async throws {
        do {
            try requireCurrent(identifier)
            let seconds = Double(scheduledFrames) / Double(OpenRouterProgressiveSpeechResult.sampleRate) + 5
            let deadline = dependencies.now().advanced(by: .seconds(seconds))
            while scheduledFrames > 0 {
                try requireCurrent(identifier)
                try Task.checkCancellation()
                guard dependencies.now() < deadline else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
                try await dependencies.sleep()
            }
            try requireCurrent(identifier)
            try Task.checkCancellation()
            guard dependencies.now() < deadline else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
        } catch {
            stop(session: identifier)
            throw error
        }
    }

    func stop(session identifier: SessionID) {
        guard owner == identifier else { return }
        stop()
    }

    func stop() {
        owner = nil
        onInterruption = nil
        scheduledFrames = 0
        let output = output
        self.output = nil
        observers.forEach { dependencies.notifications.removeObserver($0) }
        observers.removeAll()
        output?.stop()
        lease?.restoreIfUnchanged()
        lease = nil
    }

    func checkInterruption(session identifier: SessionID) throws {
        if let failure, failure.0 == identifier { throw failure.1 }
    }

    private func requireCurrent(_ identifier: SessionID) throws {
        if let failure, failure.0 == identifier { throw failure.1 }
        guard owner == identifier else { throw CancellationError() }
    }

    private func didPlay(frames: Int, owner identifier: SessionID) {
        defer { dependencies.inspectedCompletion() }
        guard owner == identifier else { return }
        scheduledFrames = max(0, scheduledFrames - frames)
    }

    private func observeInterruptions(owner identifier: SessionID) {
        let names = [
            AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification
        ]
        observers = names.map { name in
            dependencies.notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated { self?.receiveSessionEvent(notice, session: identifier) }
            }
        }
    }

    /// The same generation fence serves queued notifications and deterministic ownership tests.
    func receiveSessionEvent(_ notice: Notification, session identifier: SessionID) {
        guard OpenRouterIOSAudioSessionLease.interruptsPlayback(notice), owner == identifier else { return }
        failure = (identifier, .interrupted)
        // A recorder/system owns the replacement session; never restore over it.
        lease = nil
        let interrupted = onInterruption
        stop(session: identifier)
        interrupted?()
    }

    /// The wire remains PCM16LE; the engine receives Apple's standard native Float32 format.
    static func nativeBuffer(for pcm: Data) throws -> AVAudioPCMBuffer {
        let width = OpenRouterProgressiveSpeechResult.bytesPerSample
        guard !pcm.isEmpty, pcm.count % width == 0, pcm.count / width <= maximumChunkFrames,
              let format = nativeFormat(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / width)),
              let channel = buffer.floatChannelData?[0] else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<(pcm.count / width) {
                let bits = UInt16(bytes[index * width]) | (UInt16(bytes[index * width + 1]) << 8)
                channel[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count / width)
        return buffer
    }

    private static func nativeFormat() -> AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: Double(OpenRouterProgressiveSpeechResult.sampleRate),
            channels: AVAudioChannelCount(OpenRouterProgressiveSpeechResult.channelCount)
        )
    }

    private static func nativeOutput() throws -> Output {
        guard let format = nativeFormat() else { throw SetupFailure.unavailable }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        return Output(start: {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
        }, schedule: { pcm, completion in
            let buffer = try nativeBuffer(for: pcm)
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        }, stop: { player.stop(); engine.stop() })
    }
}
#endif
