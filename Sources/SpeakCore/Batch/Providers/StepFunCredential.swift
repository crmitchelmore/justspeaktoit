import Foundation

/// StepFun keys are bound to the platform that issued them: platform.stepfun.ai
/// keys work only on api.stepfun.ai, platform.stepfun.com keys only on
/// api.stepfun.com. The region travels with the key, like Alibaba's, and a
/// rejected key is never retried against the other region.
public struct StepFunCredential: Codable, Sendable, Equatable {
    public static let credentialIdentifier = "stepfun.apiKey"
    /// Device-local draft for the next key saved; never changes a saved key.
    public static let newKeyRegionDefaultsKey = "stepfun.newKey.region"

    public enum Region: String, Codable, CaseIterable, Sendable {
        case international
        case china

        public static let defaultForNewKeys: Region = .international

        public var displayName: String {
            switch self {
            case .international: return "International (platform.stepfun.ai)"
            case .china: return "China (platform.stepfun.com)"
            }
        }

        public var asrURL: URL {
            switch self {
            case .international: return URL(string: "https://api.stepfun.ai/v1/audio/asr/sse")!
            case .china: return URL(string: "https://api.stepfun.com/v1/audio/asr/sse")!
            }
        }

        public var keyCreationURL: URL {
            switch self {
            case .international: return URL(string: "https://platform.stepfun.ai/interface-key")!
            case .china: return URL(string: "https://platform.stepfun.com/interface-key")!
            }
        }
    }

    public let region: Region
    public let apiKey: String

    public init(region: Region, apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isNewline), !key.hasPrefix("{") else {
            throw StepFunCredentialError.invalid
        }
        self.region = region
        self.apiKey = key
    }

    /// A plain key was saved before region support, when only the China
    /// endpoint was called, so it keeps that region.
    public init(credentials: String) throws {
        let value = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("{") else {
            self = try Self(region: .china, apiKey: value)
            return
        }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else {
            throw StepFunCredentialError.invalid
        }
        self = try Self(region: decoded.region, apiKey: decoded.apiKey)
    }

    public func encodedCredentials() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let value = String(data: try encoder.encode(self), encoding: .utf8) else {
            throw StepFunCredentialError.invalid
        }
        return value
    }

    /// Tags a newly entered key with `region`. A value that already carries a
    /// region (for example, pasted from a transfer) keeps its own region.
    public static func credentialsForSaving(_ entered: String, region: Region) throws -> String {
        let value = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{") { return try Self(credentials: value).encodedCredentials() }
        return try Self(region: region, apiKey: value).encodedCredentials()
    }

    public static func newKeyRegion(defaults: UserDefaults = .standard) -> Region {
        defaults.string(forKey: newKeyRegionDefaultsKey).flatMap(Region.init(rawValue:)) ?? .defaultForNewKeys
    }

    public static func credentialsForSaving(_ entered: String, defaults: UserDefaults = .standard) throws -> String {
        try credentialsForSaving(entered, region: newKeyRegion(defaults: defaults))
    }
}

public enum StepFunCredentialError: LocalizedError, Equatable {
    case invalid
    case rejected(StepFunCredential.Region, Int)

    public var errorDescription: String? {
        switch self {
        case .invalid:
            return "Enter a StepFun API key. Choose its region in Settings \u{203A} API Keys before saving."
        case .rejected(let region, let status):
            return "StepFun rejected this key for the \(region.displayName) region (HTTP \(status)). "
                + "Keys only work in the region that issued them. Choose that region under "
                + "StepFun region for new keys, then save the key again."
        }
    }
}
