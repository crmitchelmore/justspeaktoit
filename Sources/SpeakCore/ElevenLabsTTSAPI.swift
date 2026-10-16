import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ElevenLabsTTSOutputFormat: Sendable {
    case providerDefault, wav24k
}

/// Request contracts shared with the Mac adapter. Provider-default output is
/// retained there; desktop explicitly requests and validates genuine 24k WAV.
public enum ElevenLabsTTSAPI {
    public static let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    public static let sampleRate = 24_000
    public static let maximumRequestBytes = 65_536
    /// Preserved Mac standard-plan approximation, not current plan/account billing.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.30")!
    public static let pricingEstimateBasis =
        "Preserved Mac approximation: USD0.30 per thousand submitted graphemes. Actual model, plan, discounts "
        + "and provider billing counts vary. This is not a quote, invoice or measured charge."

    public static func speechRequest(
        text: String, voiceID: String, modelID: String, apiKey: String,
        format: ElevenLabsTTSOutputFormat = .providerDefault
    ) throws -> URLRequest {
        guard !ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(modelID) else {
            throw ElevenLabsTTSAPIError.unsupportedRequest
        }
        return try request(path: "text-to-speech/" + validatedIdentifier(voiceID), body: [
            "text": text, "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75,
                               "style": 0.0, "use_speaker_boost": true]
        ], apiKey: apiKey, format: format)
    }

    public static func dialogueRequest(
        text: String, voiceID: String, modelID: String, apiKey: String,
        format: ElevenLabsTTSOutputFormat = .providerDefault
    ) throws -> URLRequest {
        try request(path: "text-to-dialogue", body: [
            "inputs": [["text": text, "voice_id": validatedIdentifier(voiceID)]], "model_id": modelID
        ], apiKey: apiKey, format: format)
    }

    public static func permitsDialogueFallback(status: Int) -> Bool { [400, 403, 404, 422].contains(status) }

    private static func validatedIdentifier(_ value: String) throws -> String {
        let raw = value.hasPrefix(ElevenLabsTTSCatalog.voiceIDPrefix)
            ? String(value.dropFirst(ElevenLabsTTSCatalog.voiceIDPrefix.count)) : value
        guard !raw.isEmpty, raw.utf8.count <= 128,
              raw.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ElevenLabsTTSAPIError.unsupportedRequest
        }
        return raw
    }

    private static func request(
        path: String, body: [String: Any], apiKey: String, format: ElevenLabsTTSOutputFormat
    ) throws -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if case .wav24k = format {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "output_format", value: "wav_24000")]
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public enum ElevenLabsTTSAPIError: LocalizedError, Equatable, Sendable {
    case unsupportedRequest, emptyText, inputTooLarge, missingCredential, invalidCredential, service(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedRequest: "The ElevenLabs model or voice is unsupported for this request."
        case .emptyText: "Enter nonempty text for ElevenLabs speech."
        case .inputTooLarge: "The ElevenLabs request exceeds the supported text or local request-size limit."
        case .missingCredential: "Enter the canonical ElevenLabs provider key in Voice Output."
        case .invalidCredential: "The ElevenLabs key contains control characters or exceeds 8,192 UTF-8 bytes."
        case .service(let status): "ElevenLabs speech returned HTTP \(status)."
        }
    }
}
