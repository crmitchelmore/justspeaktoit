import Foundation

extension CartesiaLiveClient {
    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    final class Run: @unchecked Sendable {
        let id = UUID()
        let onTranscript: (String, Bool) -> Void
        let onError: (Error) -> Void
        var socket: LiveWebSocketTransport?
        var socketID = UUID()
        var transportReady = false
        var finishing = false
        var completed = false
        var sending = false
        var closeAdmitted = false
        var closeSent = false
        var outbound: [Outbound] = []
        var outboundAudioBytes = 0
        var startupFrames: [Data] = []
        var startupBytes = 0
        var framer: CartesiaPCMFramer
        var assembler = CartesiaTranscriptAssembler()
        var finishWaiters: [CheckedContinuation<String?, Never>] = []

        init(
            sampleRate: Int,
            onTranscript: @escaping (String, Bool) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            framer = CartesiaPCMFramer(sampleRate: sampleRate)
            self.onTranscript = onTranscript
            self.onError = onError
        }
    }

    enum Outbound {
        case audio(Data)
        case close

        var message: URLSessionWebSocketTask.Message {
            switch self {
            case .audio(let data): return .data(data)
            case .close: return .string(#"{"type":"close"}"#)
            }
        }
    }

    static func transcriptEvent(from json: String) -> (text: String, isFinal: Bool)? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(CartesiaTurnResponse.self, from: data),
              ["turn.update", "turn.eager_end", "turn.end", "transcript"].contains(response.type),
              let transcript = response.transcriptText, !transcript.isEmpty else { return nil }
        return (transcript, response.type == "turn.end")
    }

    static func providerError(from json: String) -> Error? {
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(CartesiaErrorEvent.self, from: data),
              event.type == "error" else { return nil }
        return NSError(
            domain: "Cartesia", code: event.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: event.message ?? event.title ?? "Cartesia streaming error"]
        )
    }

    func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Cartesia")
        }
        return error
    }
}

struct CartesiaPCMFramer {
    private let preferredBytes: Int
    private let minimumBytes: Int
    private var buffered = Data()
    var bufferedByteCount: Int { buffered.count }

    init(sampleRate: Int) {
        preferredBytes = max(2, sampleRate * 2 / 10)
        minimumBytes = max(2, sampleRate * 2 / 20)
    }

    mutating func append(_ data: Data) -> [Data] {
        buffered.append(data)
        var frames: [Data] = []
        while buffered.count >= preferredBytes {
            frames.append(Data(buffered.prefix(preferredBytes)))
            buffered.removeFirst(preferredBytes)
        }
        return frames
    }

    mutating func finish() -> Data? {
        guard !buffered.isEmpty else { return nil }
        if buffered.count < minimumBytes {
            buffered.append(Data(repeating: 0, count: minimumBytes - buffered.count))
        }
        if !buffered.count.isMultiple(of: 2) { buffered.append(0) }
        defer { buffered.removeAll(keepingCapacity: false) }
        return buffered
    }
}

struct CartesiaTranscriptAssembler {
    private var finalTexts: [String] = []
    private var interim = ""

    var confirmedText: String { finalTexts.joined(separator: " ") }
    var completeText: String {
        [confirmedText, interim].filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func consume(_ event: (text: String, isFinal: Bool)) -> String? {
        guard !event.text.isEmpty else { return nil }
        if event.isFinal {
            finalTexts.append(event.text)
            interim = ""
        } else {
            interim = event.text
        }
        return completeText
    }

    func snapshot(terminal: Bool) -> StreamingTranscriptSnapshot {
        StreamingTranscriptSnapshot(
            confirmedText: confirmedText,
            pendingInterim: interim,
            displayText: completeText,
            segments: finalTexts.map {
                TranscriptionSegment(startTime: 0, endTime: 0, text: $0)
            },
            isTerminal: terminal
        )
    }
}

private struct CartesiaTurnResponse: Decodable {
    struct TurnResult: Decodable { let transcript: String? }
    let type: String
    let transcript: String?
    let results: [TurnResult]?

    var transcriptText: String? {
        if let transcript { return transcript }
        return results?.compactMap(\.transcript).first { !$0.isEmpty }
    }
}

private struct CartesiaErrorEvent: Decodable {
    let type: String
    let statusCode: Int?
    let title: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case statusCode = "status_code"
        case title
        case message
    }
}
