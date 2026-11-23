import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VoiceStudioAPI {
    // MARK: - Probes & Discovery

    static func testVoiceboxConnection(
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioConnectionResult {
        let version = try await probeVersionIfAvailable(paths: ["health"], context: context)
        let voices = try await fetchVoiceboxProfiles(context: context)
        let versionText = version.map { " (\($0))" } ?? ""
        let plural = voices.count == 1 ? "" : "s"
        return VoiceStudioConnectionResult(
            kind: .voicebox,
            baseURL: context.endpoint.sanitizedURLString,
            studioVersion: version,
            voiceCount: voices.count,
            gptSoVITSConfigured: false,
            detailMessage: "Connected to Voicebox\(versionText) — \(voices.count) profile\(plural) found."
        )
    }

    static func testVoiceStudioConnection(
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioConnectionResult {
        let version = try await probeVersionIfAvailable(paths: ["health"], context: context)
        let voices = try await fetchVoiceStudioVoices(context: context)
        let versionText = version.map { " (\($0))" } ?? ""
        let plural = voices.count == 1 ? "" : "s"
        return VoiceStudioConnectionResult(
            kind: .voiceStudio,
            baseURL: context.endpoint.sanitizedURLString,
            studioVersion: version,
            voiceCount: voices.count,
            gptSoVITSConfigured: false,
            detailMessage: "Connected to VoiceStudio\(versionText) — \(voices.count) voice\(plural) found."
        )
    }

    static func testGPTSoVITSConnection(
        configuration: VoiceStudioConfiguration,
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioConnectionResult {
        let version = try await probeGPTSoVITSHealth(context: context)
        let configError = configuration.gptSoVITSValidationError()
        let versionText = version.map { " (\($0))" } ?? ""
        let detail = if let configError {
            "GPT-SoVITS is reachable\(versionText), but setup is incomplete: \(configError.localizedDescription)"
        } else {
            "Connected to GPT-SoVITS\(versionText) — reference clip and prompt are ready."
        }
        return VoiceStudioConnectionResult(
            kind: .gptSoVITS,
            baseURL: context.endpoint.sanitizedURLString,
            studioVersion: version,
            voiceCount: nil,
            gptSoVITSConfigured: configError == nil,
            detailMessage: detail
        )
    }

    static func probeVersionIfAvailable(
        paths: [String],
        context: VoiceStudioRequestContext
    ) async throws -> String? {
        for path in paths {
            let request = makeRequest(
                url: context.endpoint.endpointURL(path: path),
                method: "GET",
                apiKey: context.apiKey,
                timeout: 15
            )
            let response = try await performTransport(request, context: context, budget: metadataBudget)
            let status = response.http.statusCode
            if (200..<300).contains(status) {
                return extractVersionString(from: response.body)
            }
            if status == 401 || status == 403 {
                throw VoiceStudioError.unauthorized(kind: context.kind, statusCode: status)
            }
            if status != 404 && status != 405 {
                let detail = sanitizedErrorDetail(response.body, statusCode: status, apiKey: context.apiKey)
                throw VoiceStudioError.httpError(kind: context.kind, statusCode: status, detail: detail)
            }
        }
        return nil
    }

    static func probeGPTSoVITSHealth(context: VoiceStudioRequestContext) async throws -> String? {
        var lastError: VoiceStudioError?
        for path in ["health", "openapi.json", ""] {
            let request = makeRequest(
                url: context.endpoint.endpointURL(path: path),
                method: "GET",
                apiKey: context.apiKey,
                timeout: 15
            )
            let response = try await performTransport(request, context: context, budget: metadataBudget)
            let status = response.http.statusCode
            if (200..<300).contains(status) {
                return extractVersionString(from: response.body)
            }
            if status == 401 || status == 403 {
                throw VoiceStudioError.unauthorized(kind: .gptSoVITS, statusCode: status)
            }
            let detail = sanitizedErrorDetail(response.body, statusCode: status, apiKey: context.apiKey)
            let error = VoiceStudioError.httpError(kind: .gptSoVITS, statusCode: status, detail: detail)
            if status == 404 || status == 405 {
                lastError = error
                continue
            }
            throw error
        }
        if let lastError { throw lastError }
        throw VoiceStudioError.studioNotRunning(kind: .gptSoVITS, baseURL: context.endpoint.sanitizedURLString)
    }

    static func fetchVoiceboxProfiles(context: VoiceStudioRequestContext) async throws -> [VoiceStudioVoice] {
        let request = makeRequest(
            url: context.endpoint.endpointURL(path: "profiles"),
            method: "GET",
            apiKey: context.apiKey,
            timeout: 15
        )
        let response = try await performValidated(request, context: context, budget: metadataBudget)
        return try decodeVoiceList(response.body, kind: .voicebox, wrapperKeys: ["profiles", "items", "data"])
    }

    static func fetchVoiceStudioVoices(context: VoiceStudioRequestContext) async throws -> [VoiceStudioVoice] {
        let primary = makeRequest(
            url: context.endpoint.endpointURL(path: "v1/voices"),
            method: "GET",
            apiKey: context.apiKey,
            timeout: 15
        )
        let response = try await performTransport(primary, context: context, budget: metadataBudget)
        let status = response.http.statusCode
        if (200..<300).contains(status) {
            return try decodeVoiceList(response.body, kind: .voiceStudio, wrapperKeys: ["voices", "data", "items"])
        }
        if status == 404 {
            let legacy = makeRequest(
                url: context.endpoint.endpointURL(path: "voices"),
                method: "GET",
                apiKey: context.apiKey,
                timeout: 15
            )
            let legacyResponse = try await performValidated(legacy, context: context, budget: metadataBudget)
            return try decodeVoiceList(
                legacyResponse.body,
                kind: .voiceStudio,
                wrapperKeys: ["voices", "data", "items"]
            )
        }
        throw statusError(kind: .voiceStudio, statusCode: status, body: response.body, apiKey: context.apiKey)
    }

    // MARK: - Synthesis

    static func synthesizeVoicebox(
        text: String,
        voice: VoiceStudioVoice,
        language: String?,
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        var payload: [String: String] = [
            "profile_id": voice.remoteVoiceID,
            "text": text
        ]
        if let resolvedLanguage = normalizedLanguage(language ?? voice.language) {
            payload["language"] = resolvedLanguage
        }
        var request = makeRequest(
            url: context.endpoint.endpointURL(path: "generate"),
            method: "POST",
            apiKey: context.apiKey,
            timeout: 180
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let response = try await performValidated(request, context: context, budget: audioBudget)
        return try await decodeOrFetchAudioResponse(response: response, context: context)
    }

    static func synthesizeVoiceStudio(
        text: String,
        voice: VoiceStudioVoice,
        language: String?,
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        var payload: [String: String] = [
            "model": "voicestudio",
            "input": text,
            "voice": voice.remoteVoiceID,
            "response_format": "wav"
        ]
        if let resolvedLanguage = normalizedLanguage(language ?? voice.language) {
            payload["language"] = resolvedLanguage
        }
        var request = makeRequest(
            url: context.endpoint.endpointURL(path: "v1/audio/speech"),
            method: "POST",
            apiKey: context.apiKey,
            timeout: 180
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let response = try await performValidated(request, context: context, budget: audioBudget)
        return try await decodeOrFetchAudioResponse(response: response, context: context)
    }

    static func synthesizeGPTSoVITS(
        text: String,
        configuration: VoiceStudioConfiguration,
        language: String?,
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        if let configError = configuration.gptSoVITSValidationError() {
            throw configError
        }
        let refPath = configuration.gptSoVITSReferenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = configuration.gptSoVITSReferencePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptLang = normalizedLanguage(configuration.gptSoVITSReferencePromptLanguage)
            ?? VoiceStudioPreference.defaultGPTSoVITSLanguage
        let textLang = normalizedLanguage(language ?? configuration.gptSoVITSTextLanguage)
            ?? VoiceStudioPreference.defaultGPTSoVITSLanguage

        let bodyObject = GPTSoVITSSynthesisPayload(
            text: text,
            textLang: textLang,
            refAudioPath: refPath,
            promptLang: promptLang,
            promptText: promptText,
            mediaType: "wav",
            streamingMode: false
        )
        var request = makeRequest(
            url: context.endpoint.endpointURL(path: "tts"),
            method: "POST",
            apiKey: context.apiKey,
            timeout: 180
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(bodyObject)

        let response = try await performValidated(request, context: context, budget: audioBudget)
        return try normalizeAudioBytes(response.body, kind: .gptSoVITS)
    }

    static func decodeOrFetchAudioResponse(
        response: OpenRouterBoundedResponseTransport.Response,
        context: VoiceStudioRequestContext
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        if startsWithRIFF(response.body) {
            return try normalizeAudioBytes(response.body, kind: context.kind)
        }

        let contentType = response.http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("json") || startsWithJSONBrace(response.body) {
            guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw VoiceStudioError.invalidResponse(kind: context.kind, detail: "Malformed JSON audio payload.")
            }
            if let audioURLString = stringValue(json["audio_url"]) ?? stringValue(json["url"]) {
                let resolvedURL = try context.endpoint.resolveSameOriginAudioURL(audioURLString, kind: context.kind)
                let audioRequest = makeRequest(url: resolvedURL, method: "GET", apiKey: context.apiKey, timeout: 60)
                let fetched = try await performValidated(audioRequest, context: context, budget: audioBudget)
                return try normalizeAudioBytes(fetched.body, kind: context.kind)
            }
            if let base64 = stringValue(json["audio_base64"]) ?? stringValue(json["audio"]),
               let decoded = Data(base64Encoded: base64) {
                return try normalizeAudioBytes(decoded, kind: context.kind)
            }
            if context.kind == .voicebox, let generationID = idStringValue(json["id"]) {
                let audioURL = context.endpoint.endpointURL(path: "audio/\(generationID)")
                let audioRequest = makeRequest(url: audioURL, method: "GET", apiKey: context.apiKey, timeout: 60)
                let fetched = try await performValidated(audioRequest, context: context, budget: audioBudget)
                return try normalizeAudioBytes(fetched.body, kind: context.kind)
            }
            throw VoiceStudioError.invalidResponse(
                kind: context.kind,
                detail: "Studio JSON response contained no audio."
            )
        }

        return try normalizeAudioBytes(response.body, kind: context.kind)
    }

    static func normalizeAudioBytes(
        _ data: Data,
        kind: VoiceStudioKind
    ) throws -> VoiceStudioWAV.NormalizedAudio {
        do {
            return try VoiceStudioWAV.normalizeToMono24kPCM16(data)
        } catch let error as VoiceStudioWAVError {
            throw VoiceStudioError.invalidResponse(
                kind: kind,
                detail: error.localizedDescription
            )
        }
    }
}

private struct GPTSoVITSSynthesisPayload: Encodable {
    let text: String
    let textLang: String
    let refAudioPath: String
    let promptLang: String
    let promptText: String
    let mediaType: String
    let streamingMode: Bool

    enum CodingKeys: String, CodingKey {
        case text
        case textLang = "text_lang"
        case refAudioPath = "ref_audio_path"
        case promptLang = "prompt_lang"
        case promptText = "prompt_text"
        case mediaType = "media_type"
        case streamingMode = "streaming_mode"
    }
}
