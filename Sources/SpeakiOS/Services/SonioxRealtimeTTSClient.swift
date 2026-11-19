#if os(iOS)
import AVFoundation
import Combine
import Foundation
import os.log
import SpeakCore
import UIKit

/// Owns one low-latency Soniox stream at a time. Replacement sessions use a new
/// stream ID and ignore all late events from the prior connection.
@MainActor
final class SonioxRealtimeTTSClient: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var firstAudioLatencySeconds: TimeInterval?

    private let webSocketFactory: SonioxTTSWebSocketFactory
    private let audioPlayer: SonioxPCMAudioPlaying
    private let cancelGracePeriod: Duration
    private let receiveTimeout: Duration
    private let keepAliveInterval: Duration
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
            receiveTimeout: .seconds(15),
            observesAudioLifecycle: true
        )
    }

    init(
        webSocketFactory: SonioxTTSWebSocketFactory,
        audioPlayer: SonioxPCMAudioPlaying,
        cancelGracePeriod: Duration = .seconds(1),
        receiveTimeout: Duration = .seconds(15),
        keepAliveInterval: Duration = .seconds(Int(SonioxTTSRealtimeKeepAlive.recommendedInterval)),
        observesAudioLifecycle: Bool = false
    ) {
        self.webSocketFactory = webSocketFactory
        self.audioPlayer = audioPlayer
        self.cancelGracePeriod = cancelGracePeriod
        self.receiveTimeout = receiveTimeout
        self.keepAliveInterval = keepAliveInterval
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
        let chunks = SonioxTTSRealtimeTextChunker.chunks(text)
        guard !chunks.isEmpty else { return }
        let generation = UUID()
        let streamID = "speech-\(generation.uuidString.lowercased())"
        let connection = webSocketFactory.makeConnection(to: region.webSocketEndpoint)
        activeStream = ActiveStream(generation: generation, streamID: streamID, connection: connection)
        firstAudioLatencySeconds = nil
        var lifecycle = SonioxTTSRealtimeLifecycle()
        var providerFailure: SonioxTTSFailure?
        let startedAt = Date()
        let keepAlive = startKeepAlive(generation: generation, connection: connection)
        defer { keepAlive.cancel() }

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
                    from: try await connection.receive(timeout: receiveTimeout)
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
                case .audio(_, let data, let isFinal):
                    if try audioPlayer.enqueue(data, isFinal: isFinal, streamID: streamID),
                       firstAudioLatencySeconds == nil {
                        let latency = Date().timeIntervalSince(startedAt)
                        firstAudioLatencySeconds = latency
                        logger.info("Soniox first-audio latency: \(latency, privacy: .public) seconds")
                        isSpeaking = true
                    }
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
            // Soniox frequently closes the socket after a failure message and
            // sends no terminated message. Report the classified failure, which
            // holds the failure type and the request ID, and not the socket error.
            if let providerFailure { throw SonioxIOSVoiceOutputError.provider(providerFailure) }
            throw error
        }
    }

    /// Sends a keepalive while the stream is open.
    ///
    /// Soniox closes a socket that stays idle for more than 20 to 30 seconds.
    /// The keepalive applies to the connection, not to one stream. Soniox also
    /// closes a connection that generates no audio for more than 3 minutes, so
    /// the keepalive alone cannot hold a silent connection open.
    private func startKeepAlive(
        generation: UUID,
        connection: SonioxTTSWebSocketConnection
    ) -> Task<Void, Never> {
        let interval = keepAliveInterval
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.isCurrent(generation) else { return }
                try? await connection.send(JSONEncoder().encode(SonioxTTSRealtimeKeepAlive()))
            }
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
}

/// Keeps streamed speech audible across interruptions, route changes and
/// application lifecycle changes.
extension SonioxRealtimeTTSClient {
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
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
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
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        handleAudioInterruption(
            type: type,
            options: AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        )
    }

    /// Pauses at the start of an interruption. Continues at the end of an
    /// interruption only when the system permits it with `.shouldResume`.
    func handleAudioInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        if type == .began {
            handleAudioInterruption(began: true)
        } else if options.contains(.shouldResume) {
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

    private func handleRouteChange(_ notification: Notification) {
        let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        handleRouteChange(
            reason: rawValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
        )
    }

    /// Continues playback across route changes, but not when the output device
    /// disappears. Headphones and Bluetooth devices route to the loudspeaker
    /// when they disconnect, so the stream pauses instead.
    func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        guard let streamID = activeStream?.streamID else { return }
        if reason == .oldDeviceUnavailable {
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
