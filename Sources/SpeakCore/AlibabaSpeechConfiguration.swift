import Foundation

/// Region and workspace travel with the key, never as independent preferences.
/// Only workspace-specific Model Studio origins are supported; no region retry.
public struct AlibabaSpeechConfiguration: Codable, Sendable, Equatable {
    public static let credentialIdentifier = "alibaba.apiKey"
    public let region: Region
    public let workspace: String
    public let apiKey: String

    public enum Region: String, Codable, CaseIterable, Sendable {
        case beijing = "cn-beijing"
        case singapore = "ap-southeast-1"
        case frankfurt = "eu-central-1"
        case tokyo = "ap-northeast-1"
        case hongKong = "cn-hongkong"
        case virginia = "us-east-1"

        public var displayName: String {
            switch self {
            case .beijing: return "China (Beijing)"
            case .singapore: return "Singapore"
            case .frankfurt: return "Germany (Frankfurt)"
            case .tokyo: return "Japan (Tokyo)"
            case .hongKong: return "China (Hong Kong)"
            case .virginia: return "US (Virginia)"
            }
        }
    }

    public init(region: Region, workspace: String, apiKey: String) throws {
        self.region = region
        self.workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate()
    }

    public init(credentials: String) throws {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(credentials.utf8)) else {
            throw AlibabaSpeechError.configuration
        }
        self = try Self(region: decoded.region, workspace: decoded.workspace, apiKey: decoded.apiKey)
    }

    public func encodedCredentials() throws -> String {
        try validate()
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
            throw AlibabaSpeechError.configuration
        }
        return value
    }

    public var origin: URL {
        // validate() permits a single DNS label, not a caller-supplied endpoint.
        URL(string: "https://\(workspace).\(region.rawValue).maas.aliyuncs.com")!
    }

    public var liveURL: URL {
        URL(string: "wss://\(workspace).\(region.rawValue).maas.aliyuncs.com/api-ws/v1/inference")!
    }

    public func validateModel(_ identifier: String) throws {
        guard AlibabaSpeechModels.allIDs.contains(identifier) else { throw AlibabaSpeechError.unsupportedModel }
        guard identifier == AlibabaSpeechModels.qwen38
                || region == .beijing || region == .singapore else {
            throw AlibabaSpeechError.unsupportedRegion
        }
    }

    private func validate() throws {
        guard !apiKey.isEmpty, !apiKey.contains(where: \.isNewline),
              !workspace.isEmpty, workspace.count <= 63,
              workspace.first != "-", workspace.last != "-",
              workspace != "trial",
              workspace.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
              }) else { throw AlibabaSpeechError.configuration }
    }
}

public enum AlibabaSpeechError: LocalizedError, Equatable {
    case configuration
    case unsupportedModel
    case unsupportedRegion
    case unsupportedFormat
    case audioTooLarge
    case invalidDuration
    case durationExceeded
    case invalidResponse
    case providerFailure(String)
    case missingCompletion
    case sessionNotReady

    public var errorDescription: String? {
        switch self {
        case .configuration:
            return "Set the Alibaba region and workspace ID, then save the API key from that same region. "
                + "Use a workspace ID, not an endpoint URL."
        case .unsupportedModel:
            return "This is not a supported Alibaba transcription model."
        case .unsupportedRegion:
            return "Fun-ASR and Qwen3.5-Omni-Plus require a Beijing or Singapore workspace and regional key."
        case .unsupportedFormat:
            return "Alibaba recorded transcription needs WAV, MP3, M4A, AAC, AMR, Ogg, Opus, or FLAC audio."
        case .audioTooLarge:
            return "This recording exceeds Alibaba's local inline-audio limit (Base64 must be smaller than 10 MB)."
        case .invalidDuration:
            return "The recording duration could not be read. Convert the recording to WAV and try again."
        case .durationExceeded:
            return "Fun-ASR-Flash accepts up to 5 minutes; Qwen Omni accepts up to 3 hours. "
                + "Split the recording or choose another model."
        case .invalidResponse:
            return "Alibaba returned an invalid transcription response."
        case .providerFailure(let code):
            return "Alibaba transcription failed (\(code)). Check the regional key, workspace, model access and quota."
        case .missingCompletion:
            return "Alibaba did not confirm completion. Text received so far is recovery material, "
                + "not a complete transcript."
        case .sessionNotReady:
            return "Alibaba did not start the transcription task in time."
        }
    }
}
