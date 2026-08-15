import AVFoundation
import Foundation
import os.log

// swiftlint:disable file_length

// MARK: - Errors

public enum OpenRouterClientError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case httpStatus(Int, String)
    case audioFileTooLarge(fileSize: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "OpenRouter API key is missing."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let code, let body):
            return "OpenRouter responded with status \(code): \(body)"
        case .audioFileTooLarge(let fileSize, let limit):
            let fileSizeDescription = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            let limitDescription = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "Audio file is too large for OpenRouter reprocessing "
                + "(\(fileSizeDescription), limit \(limitDescription))."
        }
    }
}

// MARK: - Branding

/// Attribution headers OpenRouter uses to identify the calling app
/// (`X-Title` / `HTTP-Referer`). Never carries credentials.
public struct OpenRouterBranding: Sendable {
    public let title: String
    public let referer: String

    public init(title: String, referer: String) {
        self.title = title
        self.referer = referer
    }

    public static let platformDefault: OpenRouterBranding = {
        #if os(iOS)
        OpenRouterBranding(
            title: "Just Speak to It (iOS)",
            referer: "https://github.com/crmitchelmore/justspeaktoit"
        )
        #else
        OpenRouterBranding(title: "SpeakApp (macOS)", referer: "https://github.com/speak")
        #endif
    }()
}

// MARK: - Client

/// Shared OpenRouter HTTP client used by both the macOS and iOS apps.
/// Handles chat completions (streaming and non-streaming), inline-audio batch
/// transcription, API-key validation, and connection pre-warming.
///
/// API keys are resolved lazily through `apiKeyProvider` (or the explicit
/// override) and are only ever placed in the `Authorization` header — they are
/// never logged. Validation debug snapshots pass through
/// `APIKeyValidationDebugSnapshot`, which redacts sensitive headers via
/// `SensitiveHeaderRedactor` before storing them.
public actor OpenRouterAPIClient: StreamingChatLLMClient, // swiftlint:disable:this type_body_length
    BatchTranscriptionClient {
    public typealias APIKeyProvider = @Sendable () async -> String?

    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private let session: URLSession
    private let apiKeyProvider: APIKeyProvider
    private let apiKeyOverride: String?
    private let maximumInlineAudioBytes: Int64
    private let branding: OpenRouterBranding
    private let logger = SpeakLogger.logger(category: "OpenRouter")

    private struct ValidationAttemptResult {
        let success: Bool
        let debug: APIKeyValidationDebugSnapshot
        let message: String
    }

    private struct ValidationAttemptError: Error {
        let debug: APIKeyValidationDebugSnapshot
        let message: String
    }

    private enum ValidationAttempt {
        case authEndpoint
        case modelsEndpoint

        var path: String {
            switch self {
            case .authEndpoint: return "auth/validate"
            case .modelsEndpoint: return "models"
            }
        }

        var successMessage: String {
            switch self {
            case .authEndpoint: return "OpenRouter API key validated via auth endpoint"
            case .modelsEndpoint: return "OpenRouter API key validated via models endpoint"
            }
        }

        var unauthorizedMessage: String {
            switch self {
            case .authEndpoint: return "Unauthorized response from auth endpoint"
            case .modelsEndpoint: return "Unauthorized response from models endpoint"
            }
        }

        var logLabel: String {
            switch self {
            case .authEndpoint: return "API key auth validation failed"
            case .modelsEndpoint: return "API key validation via chat failed"
            }
        }
    }

    public init(
        apiKeyProvider: @escaping APIKeyProvider,
        session: URLSession = .shared,
        apiKeyOverride: String? = nil,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.apiKeyOverride = apiKeyOverride
        self.maximumInlineAudioBytes = maximumInlineAudioBytes
        self.branding = branding
    }

    /// Convenience initialiser for call sites that already hold the key.
    public init(
        apiKey: String,
        session: URLSession = .shared,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault
    ) {
        self.init(
            apiKeyProvider: { apiKey },
            session: session,
            maximumInlineAudioBytes: maximumInlineAudioBytes,
            branding: branding
        )
    }

    public func hasStoredAPIKey() async -> Bool {
        await storedAPIKey() != nil
    }

    public func requiresRemoteAccess(for model: String) -> Bool {
        !allowsLocalFallback(for: model)
    }

    // MARK: - Chat

    public func sendChat(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double
    ) async throws -> ChatResponse {
        try await sendChat(
            systemPrompt: systemPrompt,
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: nil
        )
    }

    public func sendChat(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        maxTokens: Int?
    ) async throws -> ChatResponse {
        if let key = await storedAPIKey() {
            let payload = OpenRouterChatRequest(
                model: model,
                temperature: temperature,
                messages: buildMessages(systemPrompt: systemPrompt, messages: messages),
                stream: nil,
                maxTokens: maxTokens
            )
            return try await performRemoteChat(
                apiKey: key,
                payload: payload,
                systemPrompt: systemPrompt,
                messages: messages
            )
        }

        return performLocalChatFallback(systemPrompt: systemPrompt, messages: messages)
    }

    public nonisolated func sendChatStreaming(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = await self.storedAPIKey() else {
                        continuation.finish(throwing: OpenRouterClientError.apiKeyMissing)
                        return
                    }

                    let request = try await self.streamingChatRequest(
                        apiKey: key,
                        systemPrompt: systemPrompt,
                        messages: messages,
                        model: model,
                        temperature: temperature
                    )

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: OpenRouterClientError.invalidResponse)
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                        }
                        continuation.finish(throwing: OpenRouterClientError.httpStatus(http.statusCode, body))
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let content = Self.streamedContent(fromSSELine: line) {
                            continuation.yield(content)
                        } else if Self.isSSETerminator(line) {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Extracts the delta content from a single OpenRouter SSE line, or nil
    /// when the line carries no textual delta (comments, empty lines, `[DONE]`).
    static func streamedContent(fromSSELine line: String) -> String? {
        guard !line.isEmpty, line.hasPrefix("data: ") else { return nil }

        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]", let data = jsonString.data(using: .utf8) else { return nil }

        guard let chunk = try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: data),
              let delta = chunk.choices.first?.delta,
              let content = delta.content, !content.isEmpty else {
            return nil
        }
        return content
    }

    /// True when the line is the `data: [DONE]` terminator.
    static func isSSETerminator(_ line: String) -> Bool {
        line == "data: [DONE]"
    }

    // MARK: - Batch transcription

    public func transcribeFile(at url: URL, model: String, language: String?) async throws
        -> TranscriptionResult {
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = await storedAPIKey() {
            return try await performRemoteTranscription(
                apiKey: key, url: url, model: cleanedModel, language: language)
        }

        if allowsLocalFallback(for: cleanedModel) {
            return await localTranscriptionFallback(url: url, model: cleanedModel)
        }

        throw OpenRouterClientError.apiKeyMissing
    }

    // MARK: - API key resolution

    private func storedAPIKey() async -> String? {
        if let apiKeyOverride {
            let trimmed = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let rawKey = await apiKeyProvider()
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Validation

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(
                message: "API key is empty",
                debug: debugSnapshot(url: "", method: "", errorDescription: "API key is empty")
            )
        }

        var lastFailure: (message: String, debug: APIKeyValidationDebugSnapshot?) =
            ("Validation failed", nil)

        for attempt in [ValidationAttempt.authEndpoint, .modelsEndpoint] {
            do {
                let result = try await runValidation(attempt, apiKey: trimmed)
                if result.success {
                    return .success(message: attempt.successMessage, debug: result.debug)
                }
                lastFailure = (result.message, result.debug)
            } catch let attemptError as ValidationAttemptError {
                logger.error(
                    "\(attempt.logLabel, privacy: .public): \(attemptError.message, privacy: .public)"
                )
                lastFailure = (attemptError.message, attemptError.debug)
            } catch {
                logger.error(
                    "\(attempt.logLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                let debug = debugSnapshot(
                    url: baseURL.appendingPathComponent(attempt.path).absoluteString,
                    method: "GET",
                    errorDescription: error.localizedDescription
                )
                lastFailure = (error.localizedDescription, debug)
            }
        }

        return .failure(message: lastFailure.message, debug: lastFailure.debug)
    }

    private func runValidation(_ attempt: ValidationAttempt, apiKey: String) async throws
        -> ValidationAttemptResult {
        let url = baseURL.appendingPathComponent(attempt.path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyBrandHeaders(&request)

        let headers = request.allHTTPHeaderFields ?? [:]

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                let debug = debugSnapshot(
                    url: url.absoluteString,
                    method: request.httpMethod ?? "GET",
                    requestHeaders: headers,
                    errorDescription: OpenRouterClientError.invalidResponse.localizedDescription
                )
                throw ValidationAttemptError(
                    debug: debug,
                    message: OpenRouterClientError.invalidResponse.localizedDescription
                )
            }
            return try evaluateValidationResponse(
                attempt, url: url, requestHeaders: headers, http: http, data: data
            )
        } catch let attemptError as ValidationAttemptError {
            throw attemptError
        } catch {
            let debug = debugSnapshot(
                url: url.absoluteString,
                method: request.httpMethod ?? "GET",
                requestHeaders: headers,
                errorDescription: error.localizedDescription
            )
            throw ValidationAttemptError(debug: debug, message: error.localizedDescription)
        }
    }

    private func evaluateValidationResponse(
        _ attempt: ValidationAttempt,
        url: URL,
        requestHeaders: [String: String],
        http: HTTPURLResponse,
        data: Data
    ) throws -> ValidationAttemptResult {
        let responseBody = string(from: data)
        let isSuccessStatus: Bool
        switch attempt {
        case .authEndpoint: isSuccessStatus = http.statusCode == 200
        case .modelsEndpoint: isSuccessStatus = (200..<300).contains(http.statusCode)
        }

        let debug = debugSnapshot(
            url: url.absoluteString,
            method: "GET",
            requestHeaders: requestHeaders,
            statusCode: http.statusCode,
            responseHeaders: normalizedHeaders(http.allHeaderFields),
            responseBody: responseBody,
            errorDescription: isSuccessStatus ? nil : responseBody
        )

        if isSuccessStatus {
            if attempt == .authEndpoint,
               let payload = try? JSONDecoder().decode(OpenRouterValidationResponse.self, from: data),
               let valid = payload.valid ?? payload.data?.valid {
                return ValidationAttemptResult(
                    success: valid,
                    debug: debug,
                    message: valid ? "Validated" : "Auth validation returned invalid"
                )
            }
            return ValidationAttemptResult(success: true, debug: debug, message: "Validated")
        }

        if http.statusCode == 401 {
            return ValidationAttemptResult(
                success: false,
                debug: debug,
                message: attempt.unauthorizedMessage
            )
        }

        throw ValidationAttemptError(
            debug: debug,
            message: "Unexpected status \(http.statusCode)"
        )
    }

    private func debugSnapshot(
        url: String,
        method: String,
        requestHeaders: [String: String] = [:],
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        errorDescription: String?
    ) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: url,
            method: method,
            requestHeaders: requestHeaders,
            requestBody: nil,
            statusCode: statusCode,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            errorDescription: errorDescription
        )
    }

    // MARK: - Remote requests

    private func performRemoteChat(
        apiKey: String,
        payload: OpenRouterChatRequest,
        systemPrompt: String?,
        messages: [ChatMessage]
    ) async throws -> ChatResponse {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyBrandHeaders(&request)

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw OpenRouterClientError.httpStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        return chatResponse(
            from: decoded,
            data: data,
            systemPrompt: systemPrompt,
            messages: messages
        )
    }

    private func chatResponse(
        from decoded: OpenRouterChatResponse,
        data: Data,
        systemPrompt: String?,
        messages: [ChatMessage]
    ) -> ChatResponse {
        let assistantMessages = decoded.choices.compactMap { choice in
            choice.message.map { ChatMessage(role: .assistant, content: $0.content) }
        }

        let finishReason = decoded.choices.first?.finishReason ?? "stop"
        let cost = decoded.usage.map { usage in
            ChatCostBreakdown(
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                totalCost: Decimal(usage.promptTokens + usage.completionTokens) / 1_000_000,
                currency: "USD"
            )
        }

        var conversation: [ChatMessage] = []
        if let systemPrompt {
            conversation.append(ChatMessage(role: .system, content: systemPrompt))
        }
        conversation.append(contentsOf: messages)
        conversation.append(contentsOf: assistantMessages)

        return ChatResponse(
            messages: conversation,
            finishReason: finishReason,
            cost: cost,
            rawPayload: String(data: data, encoding: .utf8)
        )
    }

    private func streamingChatRequest(
        apiKey: String,
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyBrandHeaders(&request)

        let payload = OpenRouterChatRequest(
            model: model,
            temperature: temperature,
            messages: buildMessages(systemPrompt: systemPrompt, messages: messages),
            stream: true,
            maxTokens: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func performRemoteTranscription(
        apiKey: String,
        url: URL,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyBrandHeaders(&request)

        try enforceInlineAudioSizeLimit(for: url)
        request.httpBody = try JSONEncoder().encode(
            audioTranscriptionPayload(audioURL: url, model: model, language: language)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw OpenRouterClientError.httpStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        guard
            let text = decoded.choices
                .compactMap({ $0.message?.content.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty })
        else {
            throw OpenRouterClientError.invalidResponse
        }

        return await buildTranscriptionResult(
            text: text,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    private func audioTranscriptionPayload(
        audioURL: URL,
        model: String,
        language: String?
    ) throws -> OpenRouterAudioTranscriptionRequest {
        let audioData = try Data(contentsOf: audioURL)
        let prompt = transcriptionPrompt(language: language)
        return OpenRouterAudioTranscriptionRequest(
            model: model,
            temperature: 0,
            messages: [
                OpenRouterAudioTranscriptionRequest.Message(
                    role: "user",
                    content: [
                        .text(prompt),
                        .inputAudio(
                            data: audioData.base64EncodedString(),
                            format: audioInputFormat(for: audioURL)
                        )
                    ]
                )
            ],
            stream: false
        )
    }

    // MARK: - Local fallbacks

    private func localTranscriptionFallback(url: URL, model: String) async
        -> TranscriptionResult {
        let duration = await bestEffortDuration(of: url)
        let text = "Transcription placeholder for \(url.lastPathComponent)"
        let segment = TranscriptionSegment(startTime: 0, endTime: duration, text: text)
        return TranscriptionResult(
            text: text,
            segments: [segment],
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    private func performLocalChatFallback(systemPrompt: String?, messages: [ChatMessage])
        -> ChatResponse {
        let userText =
            messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""
        let processed = heuristicPostProcess(text: userText)

        var conversation: [ChatMessage] = []
        if let systemPrompt {
            conversation.append(ChatMessage(role: .system, content: systemPrompt))
        }
        conversation.append(contentsOf: messages)
        conversation.append(ChatMessage(role: .assistant, content: processed))

        return ChatResponse(
            messages: conversation, finishReason: "fallback-local", cost: nil, rawPayload: nil)
    }

    private func heuristicPostProcess(text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let collapsed =
            trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return trimmed }

        var result = collapsed
        if let first = result.first {
            let uppercaseFirst = String(first).uppercased()
            result.replaceSubrange(result.startIndex...result.startIndex, with: uppercaseFirst)
        }

        if let last = result.last, !".!?".contains(last) {
            result.append(".")
        }

        return result
    }

    // MARK: - Helpers

    private func buildMessages(systemPrompt: String?, messages: [ChatMessage])
        -> [OpenRouterChatRequest.Message] {
        var payload: [OpenRouterChatRequest.Message] = []
        if let systemPrompt {
            payload.append(.init(role: "system", content: systemPrompt))
        }
        payload += messages.map { message in
            .init(role: message.role.rawValue, content: message.content)
        }
        return payload
    }

    private func string(from data: Data?) -> String? {
        guard let data else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .ascii)
    }

    private func normalizedHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            guard let keyString = key as? String else { continue }
            if let valueString = value as? String {
                normalized[keyString] = valueString
            } else {
                normalized[keyString] = String(describing: value)
            }
        }
        return normalized
    }

    private func transcriptionPrompt(language: String?) -> String {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedLanguage.isEmpty {
            return "Transcribe this audio file. Return only the transcript text, with no commentary."
        }

        return "Transcribe this audio file using locale \(trimmedLanguage). "
            + "Return only the transcript text, with no commentary."
    }

    private func audioInputFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav", "mp3", "aiff", "aac", "ogg", "flac", "m4a", "pcm16", "pcm24":
            return ext
        case "m4b":
            return "m4a"
        case "wave":
            return "wav"
        default:
            return "m4a"
        }
    }

    private func enforceInlineAudioSizeLimit(for url: URL) throws {
        let fileSize = try audioFileSize(for: url)
        guard fileSize <= maximumInlineAudioBytes else {
            throw OpenRouterClientError.audioFileTooLarge(
                fileSize: fileSize,
                limit: maximumInlineAudioBytes
            )
        }
    }

    private func audioFileSize(for url: URL) throws -> Int64 {
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(fileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func buildTranscriptionResult(
        text: String,
        audioURL: URL,
        model: String,
        payload: Data
    ) async -> TranscriptionResult {
        let duration = await bestEffortDuration(of: audioURL)
        let segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

    /// Reads the recorded length of `audioURL`, and reports `0` when the local
    /// file gives no usable value.
    ///
    /// Duration is enrichment that is added after the provider replies. A
    /// container that AVFoundation cannot parse, or that holds no duration
    /// metadata, must not discard a transcript the provider already made — the
    /// audio is frequently a temporary file that is deleted immediately after,
    /// so a thrown error loses the speech and the transcript together.
    ///
    /// `TranscriptionResult.duration` is a non-optional `TimeInterval`, and all
    /// consumers already read `0` as "unknown": speech insights skip sessions
    /// below the minimum length, and the history and recording lists show
    /// `0:00`. Cost is separate metadata and stays `nil` here. The failure is
    /// logged so a run with missing durations stays diagnosable.
    private func bestEffortDuration(of audioURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: audioURL)
        do {
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0 else {
                logger.warning(
                    "Duration metadata for \(audioURL.lastPathComponent, privacy: .public) is not usable; reporting 0"
                )
                return 0
            }
            return seconds
        } catch {
            logger.warning(
                """
                Failed to load duration metadata for \
                \(audioURL.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public). Keeping the transcript with duration 0
                """
            )
            return 0
        }
    }

    private nonisolated func applyBrandHeaders(_ request: inout URLRequest) {
        request.setValue(branding.title, forHTTPHeaderField: "X-Title")
        request.setValue(branding.referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(branding.referer, forHTTPHeaderField: "Referer")
    }

    private func allowsLocalFallback(for model: String) -> Bool {
        if model.lowercased().hasPrefix("apple/") { return true }
        if model.lowercased().hasPrefix("local/") { return true }
        if model.lowercased() == "on-device" { return true }
        return false
    }

    /// Pre-warms the TCP/TLS connection to OpenRouter by making a lightweight HEAD request.
    /// This establishes and caches the connection for subsequent API calls.
    /// Failures are logged but do not throw - warming is best-effort.
    public func warmUp() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        applyBrandHeaders(&request)

        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if let http = response as? HTTPURLResponse {
                logger.info(
                    "Connection warm-up completed in \(elapsed, privacy: .public)ms (status: \(http.statusCode))"
                )
            } else {
                logger.info("Connection warm-up completed in \(elapsed, privacy: .public)ms")
            }
        } catch {
            let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let reason = error.localizedDescription
            logger.warning(
                "Connection warm-up failed after \(elapsed, privacy: .public)ms: \(reason, privacy: .public)"
            )
        }
    }
}

// MARK: - Wire models

private struct OpenRouterChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let messages: [Message]
    let stream: Bool?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case messages
        case stream
        case maxTokens = "max_tokens"
    }
}

private struct OpenRouterChatResponseChoiceMessage: Decodable {
    let role: String?
    let content: String
}

private struct OpenRouterChatResponseChoice: Decodable {
    let index: Int?
    let finishReason: String?
    let message: OpenRouterChatResponseChoiceMessage?

    enum CodingKeys: String, CodingKey {
        case index
        case finishReason = "finish_reason"
        case message
    }
}

private struct OpenRouterChatUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct OpenRouterChatResponse: Decodable {
    let choices: [OpenRouterChatResponseChoice]
    let usage: OpenRouterChatUsage?
}

private struct OpenRouterValidationResponse: Decodable {
    struct ValidationData: Decodable {
        let valid: Bool?
    }

    let valid: Bool?
    let data: ValidationData?
}

private struct OpenRouterAudioTranscriptionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [OpenRouterAudioContentPart]
    }

    let model: String
    let temperature: Double
    let messages: [Message]
    let stream: Bool
}

private enum OpenRouterAudioContentPart: Encodable {
    case text(String)
    case inputAudio(data: String, format: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputAudio(let data, let format):
            try container.encode("input_audio", forKey: .type)
            let inputAudio = OpenRouterInputAudio(data: data, format: format)
            try container.encode(inputAudio, forKey: .inputAudio)
        }
    }
}

private struct OpenRouterInputAudio: Encodable {
    let data: String
    let format: String
}

private struct OpenRouterStreamChunkDelta: Decodable {
    let role: String?
    let content: String?
}

private struct OpenRouterStreamChunkChoice: Decodable {
    let delta: OpenRouterStreamChunkDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct OpenRouterStreamChunk: Decodable {
    let choices: [OpenRouterStreamChunkChoice]
}
