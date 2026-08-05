import SpeakCore
import AVFoundation
import Foundation

// MARK: - Deepgram Transcription Provider

struct DeepgramTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "deepgram",
        displayName: "Deepgram",
        systemImage: "waveform.circle",
        tintColor: "indigo",
        website: "https://deepgram.com"
    )

    private let baseURL = URL(string: "https://api.deepgram.com/v1")!
    private let session: URLSession
    private let bufferPool: AudioBufferPool

    init(session: URLSession = .shared, bufferPool: AudioBufferPool? = nil) {
        self.session = session
        self.bufferPool = bufferPool ?? AudioBufferPool(poolSize: 10, bufferSize: 8192)
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("listen")

        guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TranscriptionProviderError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "model", value: extractModelName(from: model)),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "numerals", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        if let language {
            let languageCode = language.localeLanguageCode
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        urlComponents.queryItems = queryItems

        guard let requestURL = urlComponents.url else {
            throw TranscriptionProviderError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: url)
        request.httpBody = audioData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramBatchResponse.self, from: data)
        return try await buildTranscriptionResult(
            response: decoded,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: baseURL.appendingPathComponent("projects"),
            headers: { ["Authorization": "Token \($0)"] },
            serviceName: "Deepgram",
            session: session
        ).validate(key)
    }

    func requiresAPIKey(for model: String) -> Bool {
        true
    }

    func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
    }

    /// Creates a live transcriber for streaming audio.
    ///
    /// The transport is the shared `SpeakCore.DeepgramLiveClient` — the same
    /// client iOS streams through — so nova and Flux sessions behave
    /// identically on both platforms and the socket-state synchronisation
    /// lives in one place.
    func createLiveTranscriber(
        apiKey: String,
        model: String = "nova-3",
        language: String? = nil,
        sampleRate: Int = 16000
    ) -> DeepgramLiveClient {
        DeepgramLiveClient(
            apiKey: apiKey,
            model: extractModelName(from: model),
            language: language,
            sampleRate: sampleRate,
            session: session,
            bufferPool: bufferPool
        )
    }

    // MARK: - Private Methods

    private func extractModelName(from model: String) -> String {
        // Extract the model name after the "/" and remove any "-streaming" suffix
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

    private func buildTranscriptionResult(
        response: DeepgramBatchResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let asset = AVURLAsset(url: audioURL)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds

        guard let channel = response.results?.channels.first,
              let alternative = channel.alternatives.first else {
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: duration,
                modelIdentifier: model,
                cost: nil,
                rawPayload: String(data: payload, encoding: .utf8),
                debugInfo: nil
            )
        }

        let text = alternative.transcript
        let segments: [TranscriptionSegment]

        if let words = alternative.words, !words.isEmpty {
            segments = words.map { word in
                TranscriptionSegment(
                    startTime: word.start,
                    endTime: word.end,
                    text: word.word
                )
            }
        } else {
            segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]
        }

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: alternative.confidence,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

}

// MARK: - Response Models

private struct DeepgramBatchResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable {
                    let word: String
                    let start: TimeInterval
                    let end: TimeInterval
                    let confidence: Double?
                }

                let transcript: String
                let confidence: Double?
                let words: [Word]?
            }

            let alternatives: [Alternative]
        }

        let channels: [Channel]
    }

    let results: Results?
}

// MARK: - Error Types

enum DeepgramError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct Deepgram WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to Deepgram"
        case .sendFailed:
            return "Failed to send audio data to Deepgram"
        case .missingAPIKey:
            return "Deepgram API key is missing. Please configure it in Settings."
        }
    }
}
