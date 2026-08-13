import Foundation

/// Canonical start message for one Soniox real-time TTS stream.
public struct SonioxTTSRealtimeConfiguration: Encodable, Equatable, Sendable {
    private let apiKey: String
    public let streamID: String
    public let model: String
    public let language: String
    public let voice: String
    public let audioFormat: String
    public let sampleRate: Int
    public let speed: Double

    public init(
        apiKey: String,
        streamID: String,
        model: SonioxTTSModel = SonioxTTSCatalog.defaultModel,
        language: String,
        voice: String,
        sampleRate: Int = 24_000,
        speed: Double = 1.0
    ) {
        self.apiKey = apiKey
        self.streamID = streamID
        self.model = model.rawValue
        self.language = SonioxTTSCatalog.requiredLanguageCode(language)
        self.voice = voice
        self.audioFormat = "pcm_s16le"
        self.sampleRate = SonioxTTSAPI.supportedSampleRates.contains(sampleRate) ? sampleRate : 24_000
        self.speed = min(max(speed, SonioxTTSAPI.speedRange.lowerBound), SonioxTTSAPI.speedRange.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case model, language, voice, speed
        case apiKey = "api_key"
        case streamID = "stream_id"
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
    }
}

public struct SonioxTTSRealtimeText: Encodable, Equatable, Sendable {
    public let text: String
    public let textEnd: Bool
    public let streamID: String

    public init(text: String, textEnd: Bool, streamID: String) {
        self.text = text
        self.textEnd = textEnd
        self.streamID = streamID
    }

    enum CodingKeys: String, CodingKey {
        case text
        case textEnd = "text_end"
        case streamID = "stream_id"
    }
}

public struct SonioxTTSRealtimeCancel: Encodable, Equatable, Sendable {
    public let streamID: String
    public let cancel = true

    public init(streamID: String) {
        self.streamID = streamID
    }

    enum CodingKeys: String, CodingKey {
        case cancel
        case streamID = "stream_id"
    }
}

/// Server events are scoped by stream ID so late events cannot affect a replacement stream.
public enum SonioxTTSRealtimeEvent: Equatable, Sendable {
    case audio(streamID: String, data: Data, isFinal: Bool)
    case terminated(streamID: String)
    case failure(streamID: String, failure: SonioxTTSFailure)

    public var streamID: String {
        switch self {
        case .audio(let streamID, _, _), .terminated(let streamID), .failure(let streamID, _): streamID
        }
    }
}

extension SonioxTTSRealtimeEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case audio, terminated
        case streamID = "stream_id"
        case audioEnd = "audio_end"
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let streamID = try values.decode(String.self, forKey: .streamID)
        if try values.decodeIfPresent(Bool.self, forKey: .terminated) == true {
            self = .terminated(streamID: streamID)
            return
        }
        if let encodedAudio = try values.decodeIfPresent(String.self, forKey: .audio),
           let audio = Data(base64Encoded: encodedAudio) {
            self = .audio(
                streamID: streamID,
                data: audio,
                isFinal: try values.decodeIfPresent(Bool.self, forKey: .audioEnd) ?? false
            )
            return
        }
        if let errorType = try values.decodeIfPresent(String.self, forKey: .errorType) {
            self = .failure(
                streamID: streamID,
                failure: SonioxTTSFailure(
                    statusCode: try values.decodeIfPresent(Int.self, forKey: .errorCode) ?? 0,
                    type: SonioxTTSFailureType(rawValue: errorType),
                    message: try values.decodeIfPresent(String.self, forKey: .errorMessage)
                        ?? "Unknown Soniox error",
                    requestID: try values.decodeIfPresent(String.self, forKey: .requestID)
                )
            )
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .streamID,
            in: values,
            debugDescription: "Unknown Soniox TTS event"
        )
    }
}

/// Tracks the required text_end -> audio_end -> terminated normal-completion contract.
public struct SonioxTTSRealtimeLifecycle: Equatable, Sendable {
    public private(set) var sentTextEnd = false
    public private(set) var receivedAudioEnd = false
    public private(set) var receivedFailure = false
    public private(set) var isCancelling = false
    public private(set) var isTerminated = false

    public init() {}

    public mutating func recordTextEnd() { sentTextEnd = true }
    public mutating func recordCancel() { isCancelling = true }

    public mutating func record(_ event: SonioxTTSRealtimeEvent) throws {
        switch event {
        case .audio(_, _, let isFinal):
            guard !isTerminated else { throw SonioxTTSRealtimeProtocolError.eventAfterTermination }
            if isFinal { receivedAudioEnd = true }
        case .failure:
            receivedFailure = true
        case .terminated:
            guard isCancelling || receivedFailure || (sentTextEnd && receivedAudioEnd) else {
                throw SonioxTTSRealtimeProtocolError.incompleteFinalHandshake
            }
            isTerminated = true
        }
    }
}

public enum SonioxTTSRealtimeProtocolError: Error, Equatable, Sendable {
    case incompleteFinalHandshake
    case eventAfterTermination
}

public enum SonioxTTSRealtimeTextChunker {
    public static func chunks(_ text: String, maximumCharacters: Int = 240) -> [String] {
        guard maximumCharacters > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var remaining = trimmed[...]
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: maximumCharacters, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            var split = end
            if end != remaining.endIndex,
               let whitespace = remaining[..<end].lastIndex(where: { $0.isWhitespace }) {
                split = remaining.index(after: whitespace)
            }
            chunks.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        return chunks
    }
}
