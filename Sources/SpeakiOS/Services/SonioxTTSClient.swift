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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func speak(
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
        defer { synthesisTask = nil }
        do {
            try await playAudio(try await task.value)
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
        synthesisTask?.cancel()
        synthesisTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    private func playAudio(_ data: Data) async throws {
        stop()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            isSpeaking = true
            audioPlayer?.play()
            while audioPlayer?.isPlaying == true {
                try await Task.sleep(for: .milliseconds(30))
            }
            isSpeaking = false
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            isSpeaking = false
            throw error
        }
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
