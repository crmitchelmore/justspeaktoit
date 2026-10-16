import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Velma streaming: WAV-prefixed binary PCM, an empty text end frame, then
/// `done`. Closing without `done` is a failure, even if utterances were received.
/// Contract: https://docs.modulate.ai/get-started/stt (2026-10-13).
public final class ModulateLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let apiKey: String
    private let options: ModulateLiveOptions
    private let lifecycle: StreamingProviderSession
    var preroll: StreamingAudioPreroll { lifecycle.preroll }

    public convenience init(apiKey: String, sampleRate: Int = 16_000, session: URLSession = .shared) {
        self.init(apiKey: apiKey, sampleRate: sampleRate, session: session, options: .none)
    }

    public convenience init(
        apiKey: String, sampleRate: Int = 16_000, session: URLSession = .shared, options: ModulateLiveOptions
    ) {
        self.init(
            apiKey: apiKey, sampleRate: sampleRate, options: options,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String, sampleRate: Int = 16_000, options: ModulateLiveOptions = .none,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = key
        self.options = options
        var configuration = StreamingProviderSession.Configuration(
            provider: "Modulate", sampleRate: sampleRate, shape: .standaloneSegments, finishBudget: 5,
            request: {
                guard !key.isEmpty else { throw StreamingClientError.missingAPIKey(provider: "Modulate") }
                guard sampleRate > 0 else { throw ModulateStreamingError.unsupportedSampleRate(sampleRate) }
                guard let request = Self.request(apiKey: key, options: options) else {
                    throw StreamingClientError.invalidURL
                }
                return request
            },
            setup: nil,
            audio: { audio, first in
                var payload = first ? Self.makeStreamingWAVHeader(sampleRate: sampleRate) : Data()
                payload.append(audio)
                return .binary(payload)
            },
            end: .text(""),
            decode: Self.events
        )
        configuration.cumulativeSegmentUpdates = true
        configuration.unsolicitedCompletionFails = true
        lifecycle = StreamingProviderSession(
            configuration: configuration, makeConnection: makeConnection, schedule: schedule
        )
    }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lifecycle.start(onTranscript: onTranscript, onError: onError)
    }
    public func sendAudio(_ audioData: Data) { lifecycle.sendAudio(audioData) }
    public func stop() { lifecycle.stop() }
    public func finishAndWait() async -> String? { await lifecycle.finishAndWait() }

    func makeRequest() -> URLRequest? { Self.request(apiKey: apiKey, options: options) }

    private static func request(apiKey: String, options: ModulateLiveOptions) -> URLRequest? {
        var components = URLComponents(url: ModulateTranscriptionService.streamingURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "speaker_diarization", value: String(options.speakerDiarization)),
            URLQueryItem(name: "emotion_signal", value: String(options.emotionSignal)),
            URLQueryItem(name: "accent_signal", value: String(options.accentSignal)),
            URLQueryItem(name: "pii_phi_tagging", value: String(options.piiPhiTagging))
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return request
    }

    public enum ModulateStreamingError: LocalizedError {
        case unsupportedSampleRate(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSampleRate(let rate):
                return "Modulate requires a positive PCM sample rate, not \(rate) Hz."
            }
        }
    }

    private static func events(_ text: String) -> [StreamingProviderSession.Event] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "utterance":
            guard let utterance = object["utterance"] as? [String: Any], let text = utterance["text"] as? String else {
                return []
            }
            return [.final(text, id: utterance["utterance_uuid"] as? String)]
        case "done": return [.complete]
        case "error":
            return [.failure(NSError(
                domain: "Modulate", code: 500,
                userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "Modulate error"]
            ))]
        default: return []
        }
    }

    private static func makeStreamingWAVHeader(sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func append(_ value: UInt16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
        }
        func append(_ value: UInt32) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        append("RIFF"); append(UInt32.max); append("WAVE"); append("fmt ")
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16)); append("data"); append(UInt32.max)
        return data
    }
}
