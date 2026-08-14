#if os(iOS)
// swiftlint:disable file_length
import AVFoundation
import Combine
import Foundation
import os.log
import SpeakCore
import UIKit

@MainActor
protocol SonioxTTSWebSocketConnection: AnyObject {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor
protocol SonioxTTSWebSocketFactory {
    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection
}

@MainActor
private final class URLSessionSonioxTTSWebSocketConnection: SonioxTTSWebSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): data
        case .string(let string): Data(string.utf8)
        @unknown default: throw SonioxIOSVoiceOutputError.invalidWebSocketMessage
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

@MainActor
private struct URLSessionSonioxTTSWebSocketFactory: SonioxTTSWebSocketFactory {
    let session: URLSession

    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection {
        URLSessionSonioxTTSWebSocketConnection(task: session.webSocketTask(with: endpoint))
    }
}

@MainActor
protocol SonioxPCMAudioPlaying: AnyObject {
    func prepare(streamID: String) throws
    func enqueue(_ data: Data, streamID: String) throws
    func waitUntilDrained(streamID: String) async
    func pause(streamID: String)
    func resume(streamID: String)
    func stop(streamID: String?)
}

@MainActor
private final class SonioxPCMAudioPlayer: SonioxPCMAudioPlaying {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var streamID: String?
    private var scheduledBuffers = 0
    private var drainContinuation: CheckedContinuation<Void, Never>?

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
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
        } catch {
            player.stop()
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        self.engine = engine
        self.player = player
        self.format = format
        self.streamID = streamID
    }

    func enqueue(_ data: Data, streamID: String) throws {
        guard self.streamID == streamID,
              data.count >= MemoryLayout<Int16>.size,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              let format,
              let player else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0] else {
            throw SonioxIOSVoiceOutputError.invalidPCMData
        }
        data.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(channel, baseAddress, data.count)
        }
        buffer.frameLength = frameCount
        scheduledBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.didFinishBuffer(streamID: streamID) }
        }
        if !player.isPlaying { player.play() }
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
        drainContinuation?.resume()
        drainContinuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

/// Owns one low-latency Soniox stream at a time. Replacement sessions use a new
/// stream ID and ignore all late events from the prior connection.
@MainActor
final class SonioxRealtimeTTSClient: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var firstAudioLatencySeconds: TimeInterval?

    private let webSocketFactory: SonioxTTSWebSocketFactory
    private let audioPlayer: SonioxPCMAudioPlaying
    private let cancelGracePeriod: Duration
    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "SonioxTTS")
    private var activeStream: ActiveStream?
    private var notificationObservers: [NSObjectProtocol] = []

    private struct ActiveStream {
        let generation: UUID
        let streamID: String
        let connection: SonioxTTSWebSocketConnection
    }

    convenience init(session: URLSession) {
        self.init(
            webSocketFactory: URLSessionSonioxTTSWebSocketFactory(session: session),
            audioPlayer: SonioxPCMAudioPlayer(),
            cancelGracePeriod: .seconds(1),
            observesAudioLifecycle: true
        )
    }

    init(
        webSocketFactory: SonioxTTSWebSocketFactory,
        audioPlayer: SonioxPCMAudioPlaying,
        cancelGracePeriod: Duration = .seconds(1),
        observesAudioLifecycle: Bool = false
    ) {
        self.webSocketFactory = webSocketFactory
        self.audioPlayer = audioPlayer
        self.cancelGracePeriod = cancelGracePeriod
        if observesAudioLifecycle { observeAudioLifecycle() }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
    func speak(
        text: String,
        apiKey: String,
        voice: String,
        language: String,
        region: SonioxTTSRegion,
        speed: Double
    ) async throws {
        stop()
        let generation = UUID()
        let streamID = "openclaw-\(generation.uuidString.lowercased())"
        let connection = webSocketFactory.makeConnection(to: region.webSocketEndpoint)
        activeStream = ActiveStream(generation: generation, streamID: streamID, connection: connection)
        firstAudioLatencySeconds = nil
        var lifecycle = SonioxTTSRealtimeLifecycle()
        var providerFailure: SonioxTTSFailure?
        let startedAt = Date()

        do {
            try audioPlayer.prepare(streamID: streamID)
            connection.resume()
            try await connection.send(JSONEncoder().encode(SonioxTTSRealtimeConfiguration(
                apiKey: apiKey,
                streamID: streamID,
                language: language,
                voice: voice,
                speed: speed
            )))
            let chunks = SonioxTTSRealtimeTextChunker.chunks(text)
            for (index, chunk) in chunks.enumerated() {
                try ensureCurrent(generation)
                let isFinal = index == chunks.index(before: chunks.endIndex)
                try await connection.send(JSONEncoder().encode(SonioxTTSRealtimeText(
                    text: chunk,
                    textEnd: isFinal,
                    streamID: streamID
                )))
                if isFinal { lifecycle.recordTextEnd() }
            }

            while true {
                let event = try JSONDecoder().decode(
                    SonioxTTSRealtimeEvent.self,
                    from: try await connection.receive()
                )
                guard event.streamID == streamID else { continue }
                guard isCurrent(generation) else {
                    if case .terminated = event {
                        connection.close()
                        throw CancellationError()
                    }
                    continue
                }
                try lifecycle.record(event)

                switch event {
                case .audio(_, let data, _):
                    if firstAudioLatencySeconds == nil {
                        let latency = Date().timeIntervalSince(startedAt)
                        firstAudioLatencySeconds = latency
                        logger.info("Soniox first-audio latency: \(latency, privacy: .public) seconds")
                    }
                    try audioPlayer.enqueue(data, streamID: streamID)
                    isSpeaking = true
                case .failure(_, let failure):
                    providerFailure = failure
                    if let requestID = failure.requestID {
                        logger.error("Soniox TTS failed; request_id=\(requestID, privacy: .public)")
                    }
                case .terminated:
                    if let providerFailure { throw SonioxIOSVoiceOutputError.provider(providerFailure) }
                    await audioPlayer.waitUntilDrained(streamID: streamID)
                    finish(generation: generation, streamID: streamID, connection: connection)
                    return
                }
            }
        } catch {
            if !isCurrent(generation) {
                connection.close()
                throw CancellationError()
            }
            finish(generation: generation, streamID: streamID, connection: connection)
            throw error
        }
    }

    func stop() {
        guard let stream = activeStream else {
            audioPlayer.stop(streamID: nil)
            isSpeaking = false
            return
        }
        activeStream = nil
        audioPlayer.stop(streamID: stream.streamID)
        isSpeaking = false
        Task {
            try? await stream.connection.send(JSONEncoder().encode(
                SonioxTTSRealtimeCancel(streamID: stream.streamID)
            ))
        }
        let cancelGracePeriod = self.cancelGracePeriod
        Task {
            try? await Task.sleep(for: cancelGracePeriod)
            stream.connection.close()
        }
    }

    private func ensureCurrent(_ generation: UUID) throws {
        guard isCurrent(generation) else { throw CancellationError() }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        activeStream?.generation == generation
    }

    private func finish(
        generation: UUID,
        streamID: String,
        connection: SonioxTTSWebSocketConnection
    ) {
        guard isCurrent(generation) else { return }
        activeStream = nil
        audioPlayer.stop(streamID: streamID)
        connection.close()
        isSpeaking = false
    }

    private func observeAudioLifecycle() {
        let centre = NotificationCenter.default
        notificationObservers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })
        notificationObservers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioLifecycleResume() }
        })
        notificationObservers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioLifecycleResume() }
        })
        notificationObservers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioLifecycleResume() }
        })
        // The play-and-record session remains active across both callbacks so
        // streamed speech and the configured Bluetooth route can continue.
    }

    private func handleInterruption(_ notification: Notification) {
        guard activeStream != nil,
              let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
        if type == .began {
            handleAudioInterruption(began: true)
        } else {
            handleAudioInterruption(began: false)
        }
    }

    func handleAudioInterruption(began: Bool) {
        guard let streamID = activeStream?.streamID else { return }
        if began {
            audioPlayer.pause(streamID: streamID)
        } else {
            audioPlayer.resume(streamID: streamID)
        }
    }

    func handleAudioLifecycleResume() {
        guard let streamID = activeStream?.streamID else { return }
        audioPlayer.resume(streamID: streamID)
    }
}
#endif
