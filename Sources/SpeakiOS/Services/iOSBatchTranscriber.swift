#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Records a complete audio file and uploads it after the user stops recording.
/// Batch mode deliberately has no interim transcript: its result arrives once
/// the selected remote model has processed the saved recording.
@MainActor
public final class IOSBatchTranscriber {
    private let audioSessionManager: AudioSessionManager
    private let audioEngine = AVAudioEngine()
    private let audioRecorder = AudioRecordingPersistence()
    private let client: IOSBatchTranscriptionClient
    private var startTime: Date?

    public let model: String

    public init(
        audioSessionManager: AudioSessionManager,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.audioSessionManager = audioSessionManager
        self.model = model
        self.client = IOSBatchTranscriptionClient(apiKey: apiKey, session: session)
    }

    public func start() async throws {
        guard await ensureMicrophonePermission() else {
            throw iOSTranscriptionError.permissionDenied(.microphone)
        }
        try await audioSessionManager.configureForRecording()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        try audioRecorder.startRecording(format: format)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [audioRecorder] buffer, _ in
            audioRecorder.writeBuffer(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            startTime = Date()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioRecorder.cancelRecording()
            audioSessionManager.deactivate()
            throw error
        }
    }

    public func stop(language: String?) async throws -> TranscriptionResult {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        guard let recording = audioRecorder.stopRecording() else {
            audioSessionManager.deactivate()
            throw IOSBatchTranscriptionError.missingRecording
        }
        audioSessionManager.deactivate()
        startTime = nil
        return try await client.transcribeFile(at: recording.url, model: model, language: language)
    }

    public func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioRecorder.cancelRecording()
        audioSessionManager.deactivate()
        startTime = nil
    }

    private func ensureMicrophonePermission() async -> Bool {
        if audioSessionManager.hasMicrophonePermission() { return true }
        return await audioSessionManager.requestMicrophonePermission()
    }
}

private struct IOSBatchTranscriptionClient {
    let apiKey: String
    let session: URLSession

    func transcribeFile(at url: URL, model: String, language: String?) async throws -> TranscriptionResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw IOSBatchTranscriptionError.apiKeyMissing }

        if AppSettings.openAIBatchModelIDs.contains(model) {
            return try await transcribeWithOpenAI(
                at: url,
                model: model,
                language: language,
                apiKey: trimmedKey
            )
        }
        return try await transcribeWithOpenRouter(
            at: url,
            model: model,
            language: language,
            apiKey: trimmedKey
        )
    }

    private func transcribeWithOpenAI(
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let modelName = model.split(separator: "/").last.map(String.init) ?? model
        var body = Data()
        body.appendFormField(name: "model", value: modelName, boundary: boundary)
        body.appendFormField(
            name: "response_format",
            value: modelName == "gpt-4o-transcribe-diarize" ? "diarized_json" : "json",
            boundary: boundary
        )
        if modelName == "gpt-4o-transcribe-diarize" {
            body.appendFormField(name: "chunking_strategy", value: "auto", boundary: boundary)
        }
        if let languageCode = language?.split(whereSeparator: { $0 == "_" || $0 == "-" }).first {
            body.appendFormField(name: "language", value: String(languageCode), boundary: boundary)
        }
        body.appendFile(
            name: "file",
            filename: url.lastPathComponent,
            mimeType: "audio/m4a",
            data: try Data(contentsOf: url),
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "OpenAI")
        let payload = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let text = payload.transcriptText
        guard !text.isEmpty else { throw IOSBatchTranscriptionError.emptyTranscript }
        return await result(text: text, url: url, model: model, rawPayload: data)
    }

    private func transcribeWithOpenRouter(
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        let audioData = try Data(contentsOf: url)
        guard audioData.count <= 50 * 1024 * 1024 else {
            throw IOSBatchTranscriptionError.audioTooLarge
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Just Speak to It (iOS)", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/crmitchelmore/justspeaktoit", forHTTPHeaderField: "HTTP-Referer")

        let locale = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = locale.isEmpty
            ? "Transcribe this audio file. Return only the transcript text, with no commentary."
            : "Transcribe this audio file using locale \(locale). Return only the transcript text, with no commentary."
        request.httpBody = try JSONEncoder().encode(
            OpenRouterRequest(
                model: model,
                messages: [OpenRouterMessage(role: "user", content: [
                    OpenRouterContent(type: "text", text: prompt, inputAudio: nil),
                    OpenRouterContent(
                        type: "input_audio",
                        text: nil,
                        inputAudio: OpenRouterAudio(
                            data: audioData.base64EncodedString(),
                            format: "m4a"
                        )
                    )
                ])]
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "OpenRouter")
        let payload = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        let text = payload.choices.compactMap(\.message?.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !text.isEmpty else { throw IOSBatchTranscriptionError.emptyTranscript }
        return await result(text: text, url: url, model: model, rawPayload: data)
    }

    private func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw IOSBatchTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw IOSBatchTranscriptionError.httpError(service, http.statusCode, body)
        }
    }

    private func result(text: String, url: URL, model: String, rawPayload: Data) async -> TranscriptionResult {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return TranscriptionResult(
            text: text,
            segments: [.init(startTime: 0, endTime: duration, text: text)],
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: rawPayload, encoding: .utf8),
            debugInfo: nil
        )
    }
}

private struct OpenAIResponse: Decodable {
    let text: String?
    let segments: [OpenAIResponseSegment]?

    var transcriptText: String {
        guard let segments, segments.contains(where: { $0.speaker != nil }) else {
            return text ?? segments?.map(\.text).joined(separator: " ") ?? ""
        }
        return segments.map { segment in
            guard let speaker = segment.speaker else { return segment.text }
            return "\(speaker.replacingOccurrences(of: "_", with: " ").capitalized): \(segment.text)"
        }.joined(separator: "\n")
    }
}

private struct OpenAIResponseSegment: Decodable {
    let text: String
    let speaker: String?
}

private struct OpenRouterRequest: Encodable {
    let model: String
    let temperature = 0
    let stream = false
    let messages: [OpenRouterMessage]
}

private struct OpenRouterMessage: Encodable {
    let role: String
    let content: [OpenRouterContent]
}

private struct OpenRouterContent: Encodable {
    let type: String
    let text: String?
    let inputAudio: OpenRouterAudio?

    enum CodingKeys: String, CodingKey { case type, text; case inputAudio = "input_audio" }
}

private struct OpenRouterAudio: Encodable {
    let data: String
    let format: String
}

private struct OpenRouterResponse: Decodable {
    let choices: [OpenRouterChoice]
}

private struct OpenRouterChoice: Decodable {
    let message: OpenRouterResponseMessage?
}

private struct OpenRouterResponseMessage: Decodable {
    let content: String
}

public enum IOSBatchTranscriptionError: LocalizedError {
    case apiKeyMissing
    case missingRecording
    case audioTooLarge
    case invalidResponse
    case emptyTranscript
    case httpError(String, Int, String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "The selected batch model needs an API key."
        case .missingRecording: return "The audio recording could not be saved."
        case .audioTooLarge: return "This recording is too large for OpenRouter's 50 MB upload limit."
        case .invalidResponse: return "The transcription service returned an invalid response."
        case .emptyTranscript: return "The transcription service returned an empty transcript."
        case .httpError(let service, let status, let body):
            return "\(service) returned HTTP \(status): \(body)"
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        if let data = value.data(using: .utf8) { append(data) }
    }

    mutating func appendFormField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
#endif
