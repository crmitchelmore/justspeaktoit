#if os(iOS)
import Combine
import Foundation
import SpeakCore

/// iOS Soniox voice-output client backed by the low-latency WebSocket transport.
@MainActor
public final class SonioxIOSVoiceOutputClient: ObservableObject {
    @Published private(set) public var isSpeaking = false
    @Published private(set) public var firstAudioLatencySeconds: TimeInterval?

    private let session: URLSession
    private let realtime: SonioxRealtimeTTSClient
    private var activeOperationID: UUID?

    public init(session: URLSession = .shared) {
        self.session = session
        self.realtime = SonioxRealtimeTTSClient(session: session)
        realtime.$isSpeaking.assign(to: &$isSpeaking)
        realtime.$firstAudioLatencySeconds.assign(to: &$firstAudioLatencySeconds)
    }

    // swiftlint:disable:next function_body_length
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
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
            }
        }

        let api = SonioxTTSAPI(session: session, region: region)
        let accountVoices: [SonioxTTSAccountVoice]
        if SonioxTTSCatalog.voice(forID: voiceID) == nil {
            accountVoices = try await api.listAccountVoices(apiKey: apiKey)
        } else {
            accountVoices = []
        }
        try Task.checkCancellation()
        guard activeOperationID == operationID else { throw CancellationError() }
        let resolution = SonioxTTSCatalog.resolvedVoice(
            voiceID: voiceID,
            accountVoices: accountVoices,
            lastKnownName: lastKnownVoiceName
        )
        let language = SonioxTTSCatalog.languageCode(
            forVoiceOutputIdentifier: languageIdentifier,
            content: trimmed
        )
        try await withTaskCancellationHandler {
            try await realtime.speak(
                text: trimmed,
                apiKey: apiKey,
                voice: resolution.apiVoiceID,
                language: language,
                region: region,
                speed: speed
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeOperationID == operationID else { return }
                self?.stop()
            }
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
        realtime.stop()
    }
}

public enum SonioxIOSVoiceOutputError: LocalizedError {
    case missingAPIKey
    case invalidWebSocketMessage
    case invalidPCMData
    case provider(SonioxTTSFailure)
    case api(SonioxTTSAPIError)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Soniox API key is required for voice output"
        case .invalidWebSocketMessage:
            "Soniox returned an invalid streaming response"
        case .invalidPCMData:
            "Soniox returned invalid PCM audio"
        case .provider(let failure):
            failure.requestID.map { "\(failure.message) (request \($0))" } ?? failure.message
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
