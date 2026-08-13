#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// iOS REST playback client for Soniox. Real-time WebSocket playback is tracked separately.
@MainActor
public final class SonioxIOSVoiceOutputClient: ObservableObject {
    @Published private(set) public var isSpeaking = false

    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var synthesisTask: Task<Data, Error>?
    private var activeOperationID: UUID?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func speak( // swiftlint:disable:this function_parameter_count
        text: String,
        apiKey: String,
        voiceID: String,
        lastKnownVoiceName: String?,
        languageIdentifier: String,
        region: SonioxTTSRegion,
        speed: Double
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SonioxIOSVoiceOutputError.missingAPIKey
        }

        stop()
        let operationID = UUID()
        activeOperationID = operationID

        let api = SonioxTTSAPI(session: session, region: region)
        let accountVoices: [SonioxTTSAccountVoice]
        if SonioxTTSCatalog.voice(forID: voiceID) == nil {
            accountVoices = try await api.listAccountVoices(apiKey: apiKey)
        } else {
            accountVoices = []
        }
        let resolution = SonioxTTSCatalog.resolvedVoice(
            voiceID: voiceID,
            accountVoices: accountVoices,
            lastKnownName: lastKnownVoiceName
        )
        let language = SonioxTTSCatalog.languageCode(
            forVoiceOutputIdentifier: languageIdentifier,
            content: trimmed
        )
        let request: SonioxTTSRequest
        if let accountVoice = resolution.accountVoice {
            request = SonioxTTSRequest(
                language: language,
                accountVoice: accountVoice,
                audioFormat: .mp3,
                speed: speed
            )
        } else {
            let voice = SonioxTTSCatalog.voice(forID: resolution.providerVoiceID)
                ?? SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
            request = SonioxTTSRequest(
                language: language,
                voice: voice,
                audioFormat: .mp3,
                speed: speed
            )
        }

        let task = Task { try await api.synthesize(text: trimmed, apiKey: apiKey, request: request) }
        synthesisTask = task
        defer {
            if activeOperationID == operationID {
                synthesisTask = nil
                activeOperationID = nil
            }
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard activeOperationID == operationID else { throw CancellationError() }
            try await playAudio(data, operationID: operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SonioxTTSAPIError {
            throw SonioxIOSVoiceOutputError.api(error)
        }
    }

    public func listAccountVoices(
        apiKey: String,
        region: SonioxTTSRegion
    ) async throws -> [SonioxTTSAccountVoice] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try await SonioxTTSAPI(session: session, region: region).listAccountVoices(apiKey: apiKey)
    }

    public func stop() {
        activeOperationID = nil
        synthesisTask?.cancel()
        synthesisTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playAudio(_ data: Data, operationID: UUID) async throws {
        guard activeOperationID == operationID else { throw CancellationError() }
        let audioSession = AVAudioSession.sharedInstance()
        var player: AVAudioPlayer?
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
            guard activeOperationID == operationID else { throw CancellationError() }
            let preparedPlayer = try AVAudioPlayer(data: data)
            player = preparedPlayer
            audioPlayer = preparedPlayer
            preparedPlayer.prepareToPlay()
            isSpeaking = preparedPlayer.play()
            while preparedPlayer.isPlaying {
                try Task.checkCancellation()
                guard activeOperationID == operationID, audioPlayer === preparedPlayer else {
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            finishPlayback(operationID: operationID, player: preparedPlayer)
        } catch {
            finishPlayback(operationID: operationID, player: player)
            throw error
        }
    }

    private func finishPlayback(operationID: UUID, player: AVAudioPlayer?) {
        guard activeOperationID == operationID else { return }
        player?.stop()
        if let player, audioPlayer === player {
            audioPlayer = nil
        }
        synthesisTask = nil
        activeOperationID = nil
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

public enum SonioxIOSVoiceOutputError: LocalizedError {
    case missingAPIKey
    case api(SonioxTTSAPIError)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Soniox API key is required for voice output"
        case .api(let error):
            switch error {
            case .apiFailure(let failure):
                failure.requestID.map { "\(failure.message) (request \($0))" } ?? failure.message
            case .textTooLong(let limit, _):
                "Soniox accepts up to \(limit) characters per request"
            case .invalidResponse:
                "Invalid response from Soniox"
            case .unauthorized:
                "Soniox rejected the API key"
            case .httpError(let statusCode, _):
                "Soniox request failed (HTTP \(statusCode))"
            }
        }
    }
}
#endif
