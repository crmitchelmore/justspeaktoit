import Foundation

/// The existing Keychain value remains `key:region`. Resource endpoints are
/// non-secret configuration, shared by the Mac and iOS settings surfaces.
public struct AzureSpeechConfiguration: Sendable {
    public static let credentialIdentifier = "azure.speech.apiKey"
    public static let endpointDefaultsKey = "azureSpeechResourceEndpoint"
    public static let proxyCredentialPrefix = "local-proxy/"
    public let apiKey: String
    public let region: String

    public init(credentials: String) throws {
        try self.init(credentials: credentials, allowProxyCredential: false)
    }

    private init(credentials: String, allowProxyCredential: Bool) throws {
        let parts = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let region = parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "eastus"
        // `AzureSpeechEndpoint` is the hardened region check (#1091): lowercase
        // ASCII letters and digits, at most 63 bytes, never URL syntax.
        guard !key.isEmpty, let ttsOrigin = AzureSpeechEndpoint.baseURL(region: region) else {
            throw AzureSpeechError.configuration("Enter your Azure key and region as key:region.")
        }
        guard allowProxyCredential || !key.hasPrefix(Self.proxyCredentialPrefix) else {
            throw AzureSpeechError.configuration(
                "Use local proxy credentials through a configured transcription proxy."
            )
        }
        self.apiKey = key
        self.region = region
        self.ttsOrigin = ttsOrigin
    }

    /// `https://<region>.tts.speech.microsoft.com`, built from components.
    private let ttsOrigin: URL

    public var voicesURL: URL {
        ttsOrigin.appendingPathComponent("cognitiveservices/voices/list")
    }

    /// The regional Speech origin for recorded audio when no resource endpoint
    /// is configured. The region has already passed `AzureSpeechEndpoint`.
    public var transcriptionURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = region + ".api.cognitive.microsoft.com"
        return components.url!
    }

    public var synthesisURL: URL {
        ttsOrigin.appendingPathComponent("cognitiveservices/v1")
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

    /// Transcription may use an explicitly configured IPv4 loopback proxy.
    /// Literal loopback avoids resolving a hostname to an unexpected address.
    public static func batchResourceURL(_ endpoint: String) throws -> URL {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value),
           components.scheme == "http", components.host == "127.0.0.1",
           let port = components.port, (1...65535).contains(port),
           components.user == nil, components.password == nil,
           components.query == nil, components.fragment == nil,
           components.path.isEmpty || components.path == "/",
           let url = components.url {
            return url
        }
        return try resourceURL(value)
    }

    public static func batchConnection(
        credentials: String, endpoint: String
    ) throws -> (origin: URL, apiKey: String) {
        let config = try AzureSpeechConfiguration(credentials: credentials, allowProxyCredential: true)
        let origin = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.transcriptionURL : try batchResourceURL(endpoint)
        let proxyCredential = config.apiKey.hasPrefix(proxyCredentialPrefix)
        if origin.scheme == "http" {
            guard proxyCredential else {
                throw AzureSpeechError.configuration(
                    "For the local proxy, save local-proxy/ followed by its local token, not your Azure key."
                )
            }
            let token = String(config.apiKey.dropFirst(proxyCredentialPrefix.count))
            guard token.count >= 43, token.count <= 128,
                  token.utf8.allSatisfy({
                      (65...90).contains($0) || (97...122).contains($0)
                          || (48...57).contains($0) || $0 == 45 || $0 == 95
                  }) else {
                throw AzureSpeechError.configuration("The local proxy token is invalid.")
            }
            return (origin, token)
        }
        guard !proxyCredential else {
            throw AzureSpeechError.configuration(
                "A local proxy token requires an endpoint such as http://127.0.0.1:8765."
            )
        }
        return (origin, config.apiKey)
    }

    public static func liveConnection(
        credentials: String, endpoint: String
    ) throws -> (origin: URL, apiKey: String) {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AzureSpeechError.configuration("Add the HTTPS resource endpoint from Azure in API Keys settings.")
        }
        return try batchConnection(credentials: credentials, endpoint: endpoint)
    }
}

public enum AzureSpeechError: LocalizedError, Sendable {
    case configuration(String)
    case service(Int)
    case invalidResponse
    case emptyInput
    case unsupportedModel
    case timedOut
    /// Every Voice Live turn came back as `input_audio_transcription.failed`,
    /// so there is no transcript to return. Reported once, at finish.
    case transcriptionFailed

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
        case .transcriptionFailed:
            return "Azure could not transcribe this recording. Check the model's access on your resource."
        }
    }
}
