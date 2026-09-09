import Foundation

/// The existing Keychain value remains `key:region`. Resource endpoints are
/// non-secret configuration, shared by the Mac and iOS settings surfaces.
public struct AzureSpeechConfiguration: Sendable {
    public static let credentialIdentifier = "azure.speech.apiKey"
    public static let endpointDefaultsKey = "azureSpeechResourceEndpoint"
    public let apiKey: String
    public let region: String

    public init(credentials: String) throws {
        let parts = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let region = parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "eastus"
        guard !key.isEmpty, !region.isEmpty,
              region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw AzureSpeechError.configuration("Enter your Azure key and region as key:region.")
        }
        self.apiKey = key
        self.region = region
    }

    public var voicesURL: URL {
        URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list")!
    }

    public var transcriptionURL: URL {
        URL(string: "https://\(region).api.cognitive.microsoft.com")!
    }

    public var synthesisURL: URL {
        URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")!
    }

    /// Only a resource origin is accepted: credentials must never follow a
    /// user-entered path, redirect or an unrelated host.
    public static func resourceURL(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              [".cognitiveservices.azure.com", ".services.ai.azure.com"].contains(where: host.hasSuffix),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw AzureSpeechError
                .configuration("Add the HTTPS resource endpoint from Azure in API Keys settings.")
        }
        return url
    }
}

public enum AzureSpeechError: LocalizedError, Sendable {
    case configuration(String)
    case service(Int)
    case invalidResponse
    case emptyInput
    case unsupportedModel
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .service(let status):
            switch status {
            case 401: return "Azure rejected the key or region. Check your Azure credentials."
            case 403: return "This Azure resource cannot access the selected model. Check its region and tier."
            case 402: return "Azure credit is exhausted."
            case 429: return "Azure quota or rate limit reached."
            default: return "Azure Speech returned HTTP \(status)."
            }
        case .invalidResponse: return "Azure Speech returned an invalid response."
        case .emptyInput: return "There is no audio or text to process."
        case .unsupportedModel: return "This Azure model is not supported by the selected API."
        case .timedOut: return "Azure Speech did not finish the transcription in time."
        }
    }
}
