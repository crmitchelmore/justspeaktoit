import Foundation
import os.log

// MARK: - Client

/// Shared OpenRouter HTTP client used by both the macOS and iOS apps.
/// Handles chat completions (streaming and non-streaming), inline-audio batch
/// transcription, API-key validation, and connection pre-warming.
///
/// Inline-audio transcription itself is the portable
/// `OpenRouterInlineAudioTranscriptionClient`; this actor adds the stored-key
/// lookup. Key validation, local fallbacks, file transcription and the
/// streaming request live in `OpenRouterKeyValidation`,
/// `OpenRouterLocalFallback`, `OpenRouterFileTranscription` and
/// `OpenRouterStreamingChat`.
///
/// API keys are resolved lazily through `apiKeyProvider` (or the explicit
/// override) and are only ever placed in the `Authorization` header — they are
/// never logged. Validation debug snapshots pass through
/// `APIKeyValidationDebugSnapshot`, which redacts sensitive headers via
/// `SensitiveHeaderRedactor` before storing them.
public actor OpenRouterAPIClient: StreamingChatLLMClient,
    BatchTranscriptionClient {
    public typealias APIKeyProvider = @Sendable () async -> String?
    /// Resolves a stored key by credential identifier for native text providers.
    public typealias NativeAPIKeyProvider = @Sendable (_ identifier: String) async -> String?

    private let baseURL = OpenRouterService.baseURL
    private let session: URLSession
    private let apiKeyProvider: APIKeyProvider
    private let apiKeyOverride: String?
    private let nativeAPIKeyProvider: NativeAPIKeyProvider?
    private let maximumInlineAudioBytes: Int64
    private let branding: OpenRouterBranding
    private let logger = SpeakLogger.logger(category: "OpenRouter")

    public init(
        apiKeyProvider: @escaping APIKeyProvider,
        session: URLSession = .shared,
        apiKeyOverride: String? = nil,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault,
        nativeAPIKeyProvider: NativeAPIKeyProvider?
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.apiKeyOverride = apiKeyOverride
        self.nativeAPIKeyProvider = nativeAPIKeyProvider
        self.maximumInlineAudioBytes = maximumInlineAudioBytes
        self.branding = branding
    }

    /// OpenRouter only: native selections report a missing provider key.
    public init(
        apiKeyProvider: @escaping APIKeyProvider,
        session: URLSession = .shared,
        apiKeyOverride: String? = nil,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault
    ) {
        self.init(
            apiKeyProvider: apiKeyProvider,
            session: session,
            apiKeyOverride: apiKeyOverride,
            maximumInlineAudioBytes: maximumInlineAudioBytes,
            branding: branding,
            nativeAPIKeyProvider: nil
        )
    }

    /// Convenience initialiser for call sites that already hold the key.
    public init(
        apiKey: String,
        session: URLSession = .shared,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault,
        nativeAPIKeyProvider: NativeAPIKeyProvider?
    ) {
        self.init(
            apiKeyProvider: { apiKey },
            session: session,
            maximumInlineAudioBytes: maximumInlineAudioBytes,
            branding: branding,
            nativeAPIKeyProvider: nativeAPIKeyProvider
        )
    }

    /// Convenience initialiser for OpenRouter-only call sites that already hold the key.
    public init(
        apiKey: String,
        session: URLSession = .shared,
        maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024,
        branding: OpenRouterBranding = .platformDefault
    ) {
        self.init(
            apiKey: apiKey,
            session: session,
            maximumInlineAudioBytes: maximumInlineAudioBytes,
            branding: branding,
            nativeAPIKeyProvider: nil
        )
    }

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await OpenRouterKeyValidation(session: session, branding: branding, baseURL: baseURL).validate(key)
    }

    public func hasStoredAPIKey() async -> Bool {
        await storedAPIKey() != nil
    }

    /// Whether the key the model's route needs is stored: the provider's own key
    /// for a native selection, otherwise the OpenRouter key.
    public func hasStoredAPIKey(forModel model: String) async -> Bool {
        await chatAPIKey(for: model) != nil
    }

    public func requiresRemoteAccess(for model: String) -> Bool {
        !OpenRouterLocalFallback.allows(model: model)
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
        if let key = await chatAPIKey(for: model) {
            return try await OpenRouterChatClient(apiKey: key, session: session, branding: branding).sendChat(
                systemPrompt: systemPrompt,
                messages: messages,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }

        if let native = NativeTextModels.route(for: model) {
            throw NativeTextModelError.apiKeyMissing(providerName: native.provider.displayName)
        }
        return OpenRouterLocalFallback.chatResponse(systemPrompt: systemPrompt, messages: messages)
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
                    guard let key = await self.chatAPIKey(for: model) else {
                        let error: Error = NativeTextModels.route(for: model).map {
                            NativeTextModelError.apiKeyMissing(providerName: $0.provider.displayName)
                        } ?? OpenRouterClientError.apiKeyMissing
                        continuation.finish(throwing: error)
                        return
                    }

                    let request = try OpenRouterStreamingChat.request(
                        apiKey: key,
                        branding: self.branding,
                        messages: OpenRouterChatRequest.messages(systemPrompt: systemPrompt, messages: messages),
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
                        if let content = OpenRouterStreamingChat.content(fromSSELine: line) {
                            continuation.yield(content)
                        } else if OpenRouterStreamingChat.isTerminator(line) {
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

    // MARK: - Batch transcription

    /// One comparison lane owns this session and can abort its requests without
    /// invalidating a recording, chat request or another lane on the original client.
    public func makeIsolatedFileTranscriptionClient() -> (client: OpenRouterAPIClient, session: URLSession) {
        let owned = URLSession(
            configuration: session.configuration, delegate: session.delegate, delegateQueue: session.delegateQueue
        )
        let client = OpenRouterAPIClient(
            apiKeyProvider: apiKeyProvider, session: owned, apiKeyOverride: apiKeyOverride,
            maximumInlineAudioBytes: maximumInlineAudioBytes, branding: branding
        )
        return (client, owned)
    }

    public func transcribeFile(at url: URL, model: String, language: String?) async throws
        -> TranscriptionResult {
        try await OpenRouterFileTranscription(
            session: session, maximumInlineAudioBytes: maximumInlineAudioBytes, branding: branding
        ).transcribe(at: url, model: model, language: language, apiKey: await storedAPIKey())
    }

    // MARK: - API key resolution

    private func chatAPIKey(for model: String) async -> String? {
        guard let native = NativeTextModels.route(for: model) else { return await storedAPIKey() }
        let key = await nativeAPIKeyProvider?(native.provider.credentialIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

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

    // MARK: - Helpers

    private nonisolated func applyBrandHeaders(_ request: inout URLRequest) {
        branding.apply(to: &request)
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
