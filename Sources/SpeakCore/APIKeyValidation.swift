import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Portable key checks for the API Keys page, dispatched by secure-storage
/// identifier to the same provider validators the Mac uses. Callers must show
/// only the outcome message: debug snapshots describe the probe request.
public enum APIKeyValidation {
    // One provider per case keeps the identifier-to-validator map auditable.
    // swiftlint:disable:next cyclomatic_complexity
    public static func validate(
        identifier: String,
        key: String,
        session: URLSession = .shared,
        staging: SharedMultipartUploadStaging,
        azureEndpoint: String = ""
    ) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(message: "API key is empty") }
        if let provider = FileSpeechProvider.allCases.first(where: { "\($0.rawValue).apiKey" == identifier }) {
            return await FileSpeechBatchClient(provider: provider, session: session).validateAPIKey(trimmed)
        }
        switch identifier {
        case "openai.apiKey", OpenAITTSCatalog.credentialIdentifier:
            return await OpenAIBatchClient(session: session, keywords: []).validateAPIKey(trimmed)
        case "openrouter.apiKey":
            return await openRouter(trimmed, session: session)
        case "assemblyai.apiKey":
            return await AssemblyAIBatchClient(session: session, keywords: []).validateAPIKey(trimmed)
        case "deepgram.apiKey":
            return await DeepgramBatchClient(session: session, keywords: []).validateAPIKey(trimmed)
        case ElevenLabsTTSCatalog.credentialIdentifier:
            return await ElevenLabsSTTAPIKeyValidator(session: session).validate(trimmed)
        case GroqTTSCatalog.credentialIdentifier:
            return await GroqBatchClient(session: session, keywords: []).validateAPIKey(trimmed)
        case MistralTTSCatalog.credentialIdentifier:
            return await MistralBatchClient(session: session, multipartStaging: staging, keywords: [])
                .validateAPIKey(trimmed)
        case "soniox.apiKey":
            return await SonioxBatchClient(session: session, keywords: [], multipartStaging: staging)
                .validateAPIKey(trimmed)
        case "revai.apiKey":
            return await RevAIBatchClient(session: session, multipartStaging: staging).validateAPIKey(trimmed)
        case "modulate.apiKey":
            return await ModulateBatchClient(session: session, multipartStaging: staging).validateAPIKey(trimmed)
        case CartesiaTTSCatalog.credentialIdentifier:
            return await CartesiaTTSAPI(session: session).validateAPIKey(trimmed)
        case GeminiTTSCatalog.credentialIdentifier:
            return await GeminiTTSAPI(session: session).validateAPIKey(trimmed)
        case "xai.apiKey":
            return await XAITTSAPI(session: session).validateAPIKey(trimmed)
        case SpeechmaticsTTSCatalog.credentialIdentifier:
            return await SpeechmaticsTTSAPI(session: session).validateAPIKey(trimmed)
        case "meta.apiKey":
            return await MetaMuseAPIKeyValidator(session: session).validate(trimmed)
        case "gladia.apiKey":
            return await gladia(trimmed, session: session)
        case AzureSpeechConfiguration.credentialIdentifier:
            return await azure(trimmed, endpoint: azureEndpoint, session: session)
        case AlibabaSpeechConfiguration.credentialIdentifier:
            do {
                _ = try AlibabaSpeechConfiguration(credentials: trimmed)
                return .success(
                    message: "Alibaba key, region and workspace saved. Access is checked when transcribing."
                )
            } catch { return .failure(message: error.localizedDescription) }
        default:
            return .failure(message: "Checking this key is not supported.")
        }
    }

    /// `GET /api/v1/key` describes the calling key and needs authentication,
    /// unlike the public model listing.
    static func openRouter(_ key: String, session: URLSession) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: OpenRouterService.baseURL.appendingPathComponent("key"),
            headers: { ["Authorization": "Bearer \($0)"] },
            serviceName: "OpenRouter",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    /// Lists live sessions with `x-gladia-key`, which URLSession would carry
    /// across a cross-origin redirect, so redirects are bound to Gladia.
    static func gladia(_ key: String, session: URLSession) async -> APIKeyValidationResult {
        let origin = GladiaBatchClient.defaultBaseURL
        var request = URLRequest(url: origin.appendingPathComponent("v2/live"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-gladia-key")
        do {
            let (_, response) = try await session.data(
                for: request, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: origin)
            )
            guard let http = response as? HTTPURLResponse else { return .failure(message: "Non-HTTP response") }
            switch http.statusCode {
            case 200..<300: return .success(message: "Gladia API key validated")
            case 401, 403: return .failure(message: "Gladia rejected the key (HTTP \(http.statusCode))")
            default: return .failure(message: "HTTP \(http.statusCode) while validating key")
            }
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }

    /// The Mac's two Azure checks: a configured loopback proxy reports its own
    /// readiness; a real key and region must list the region's voices.
    static func azure(_ credentials: String, endpoint: String, session: URLSession) async -> APIKeyValidationResult {
        do {
            if credentials.hasPrefix(AzureSpeechConfiguration.proxyCredentialPrefix) {
                let connection = try AzureSpeechConfiguration.batchConnection(
                    credentials: credentials, endpoint: endpoint
                )
                var request = URLRequest(url: connection.origin.appendingPathComponent("health"), timeoutInterval: 10)
                request.setValue(connection.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                let (data, response) = try await session.data(
                    for: request, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: connection.origin)
                )
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let status = try JSONSerialization.jsonObject(with: data) as? [String: String],
                      status["status"] == "ready", status["scope"] == "batch-transcription-and-tts" else {
                    return .failure(message: "The local proxy is unavailable or does not support batch transcription.")
                }
                return .success(
                    message: "Local proxy connected for transcription only. "
                        + "Azure sign-in and model access are checked when recording."
                )
            }
            _ = try await AzureSpeechVoiceAPI(session: session).listVoices(credentials: credentials)
            return .success(message: "Azure key and region are valid. Model access depends on your resource.")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }
}
