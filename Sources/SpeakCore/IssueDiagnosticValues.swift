import Foundation

public extension RequestDiagnosticContext {
    enum ModelClassification: String, Codable, Sendable {
        case builtIn, customOrUnknown, unavailable
    }

    /// Exact catalogue membership, never a friendly-name or custom-ID fallback.
    struct ModelSelection: Codable, Equatable, Sendable {
        public let classification: ModelClassification
        public let identifier: String?

        public static func project(_ identifier: String?) -> Self {
            guard let identifier else { return Self(classification: .unavailable, identifier: nil) }
            guard let option = ModelCatalog.allOptions.first(where: { $0.id.utf8.elementsEqual(identifier.utf8) }),
                  option.id != ModelCatalog.customOptionID, option.id.utf8.count <= 160 else {
                return Self(classification: .customOrUnknown, identifier: nil)
            }
            return Self(classification: .builtIn, identifier: option.id)
        }
        private init(classification: ModelClassification, identifier: String?) {
            self.classification = classification
            self.identifier = identifier
        }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: IssueDiagnosticIdentifierKeys.self)
            let identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            let classification = try container.decodeIfPresent(ModelClassification.self, forKey: .classification)
            self = identifier == nil && classification == .customOrUnknown
                ? Self(classification: .customOrUnknown, identifier: nil) : Self.project(identifier)
        }
        var sanitized: Self { identifier == nil ? self : Self.project(identifier) }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: IssueDiagnosticIdentifierKeys.self)
            try container.encode(classification, forKey: .classification)
            try container.encodeIfPresent(identifier, forKey: .identifier)
        }

    }

    /// Membership only. A caller must have an actual handoff receipt before
    /// labelling this as observed; it is never inferred from a model prefix.
    struct ProviderSelection: Codable, Equatable, Sendable {
        public let identifier: String?

        public static func project(_ identifier: String?) -> Self {
            let providers = Set(LiveTranscriptionProviderID.allCases.map(\.rawValue))
                .union(ModelCatalog.batchTranscription.compactMap {
                    BatchTranscriptionRouting.route(for: $0.id, platform: .macOS)?.providerID
                })
            return Self(identifier: providers.first { $0.utf8.elementsEqual((identifier ?? "").utf8) })
        }

        private init(identifier: String?) { self.identifier = identifier }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: IssueDiagnosticIdentifierKeys.self)
            self = Self.project(try container.decodeIfPresent(String.self, forKey: .identifier))
        }

    }

    struct LanguageSelection: Codable, Equatable, Sendable {
        public let identifier: String?

        public static func project(_ identifier: String?) -> Self {
            Self(identifier: TranscriptionLanguageCatalog.options.first {
                $0.id.utf8.elementsEqual((identifier ?? "").utf8)
            }?.id)
        }

        private init(identifier: String?) { self.identifier = identifier }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: IssueDiagnosticIdentifierKeys.self)
            self = Self.project(try container.decodeIfPresent(String.self, forKey: .identifier))
        }

    }

    /// Numeric release versions only; no arbitrary build labels or OS strings.
    struct Version: Codable, Equatable, Sendable {
        public let value: String

        public static func project(_ value: String?) -> Self? {
            guard let value, !value.isEmpty, value.utf8.count <= 32,
                  value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(components.count),
                  components.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 }) else { return nil }
            return Self(value: value)
        }

        private init(value: String) { self.value = value }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            guard let version = Self.project(try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid numeric version")
            }
            self = version
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    enum Platform: String, Codable, Sendable { case macOS, iOS, windows, linux, unknown }
    enum Architecture: String, Codable, Sendable {
        case arm64, unknown
        case x64 = "x86_64"
    }
    enum Channel: String, Codable, Sendable { case alpha, stable, development, unknown }
    enum Availability: String, Codable, Sendable { case available, unavailable, denied, unknown }

    struct Environment: Codable, Equatable, Sendable {
        public let platform: Platform
        public let architecture: Architecture
        public let channel: Channel
        public let appVersion: Version?
        public let appBuild: Version?
        public let osVersion: Version?
        public let microphonePermission: Availability
        public static let unavailable = Self()

        public init(
            platform: Platform = .unknown, architecture: Architecture = .unknown, channel: Channel = .unknown,
            appVersion: Version? = nil, appBuild: Version? = nil, osVersion: Version? = nil,
            microphonePermission: Availability = .unknown
        ) {
            self.platform = platform
            self.architecture = architecture
            self.channel = channel
            self.appVersion = Version.project(appVersion?.value)
            self.appBuild = Version.project(appBuild?.value)
            self.osVersion = Version.project(osVersion?.value)
            self.microphonePermission = microphonePermission
        }
    }
}

private enum IssueDiagnosticIdentifierKeys: String, CodingKey { case classification, identifier }
