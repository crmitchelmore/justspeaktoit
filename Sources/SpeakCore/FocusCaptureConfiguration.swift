import Foundation

/// Local contextual choices, never a transcript, Focus name or credential.
public struct FocusCaptureOverride: Codable, Equatable, Sendable {
    public let destinationID: String?
    public let modelID: String?
    public let languageIdentifier: String?

    public init(destinationID: String? = nil, modelID: String? = nil, languageIdentifier: String? = nil) {
        self.destinationID = captureNonblank(destinationID)
        self.modelID = captureNonblank(modelID)
        self.languageIdentifier = captureNonblank(languageIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case destinationID, modelID, languageIdentifier
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            destinationID: try values.decodeIfPresent(String.self, forKey: .destinationID),
            modelID: try values.decodeIfPresent(String.self, forKey: .modelID),
            languageIdentifier: try values.decodeIfPresent(String.self, forKey: .languageIdentifier)
        )
    }

    public static let none = FocusCaptureOverride()
    public var isEmpty: Bool { self == .none }

    public func affects(_ explicit: CaptureRunParameters) -> Bool {
        (destinationID != nil && captureNonblank(explicit.destinationID) == nil)
            || (modelID != nil && captureNonblank(explicit.modelID) == nil)
            || (languageIdentifier != nil && captureNonblank(explicit.languageIdentifier) == nil)
    }
}

/// Frozen at admission; global settings are not read again to choose this run's fields.
public struct EffectiveCaptureConfiguration: Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case explicit
        case focus
        case global
    }

    public let parameters: CaptureRunParameters
    public let modelID: String
    public let usesBatch: Bool
    public let languageIdentifier: String
    public let destinationID: String
    public let modelOrigin: Origin
    public let languageOrigin: Origin
    public let destinationOrigin: Origin

    public struct Globals: Equatable, Sendable {
        public let modelID: String
        public let usesBatch: Bool
        public let languageIdentifier: String
        public let destinationID: String

        public init(modelID: String, usesBatch: Bool, languageIdentifier: String, destinationID: String) {
            self.modelID = modelID
            self.usesBatch = usesBatch
            self.languageIdentifier = languageIdentifier
            self.destinationID = destinationID
        }
    }

    public static func resolve(
        explicit: CaptureRunParameters,
        focus: FocusCaptureOverride,
        globals: Globals,
        vocabulary: CaptureParameterVocabulary
    ) throws -> Self {
        // Empty parameters do not erase higher-level choices. Nonempty invalid values still refuse.
        let explicitDestination = captureNonblank(explicit.destinationID)
        let explicitLanguage = captureNonblank(explicit.languageIdentifier)
        let explicitModel = captureNonblank(explicit.modelID)
        // Validate only choices actually used. Explicit fields can replace invalid Focus fields.
        let parameters = try CaptureParameterResolution.resolve(
            destinationID: explicitDestination ?? focus.destinationID,
            language: explicitLanguage ?? focus.languageIdentifier,
            model: explicitModel ?? focus.modelID,
            source: explicit.sourceTag,
            vocabulary: vocabulary
        )
        return Self(
            parameters: parameters,
            modelID: parameters.modelID ?? globals.modelID,
            usesBatch: parameters.modelID == nil ? globals.usesBatch : parameters.requiresBatchMode,
            languageIdentifier: parameters.languageIdentifier ?? globals.languageIdentifier,
            destinationID: parameters.destinationID ?? globals.destinationID,
            modelOrigin: origin(explicitModel, focus.modelID),
            languageOrigin: origin(explicitLanguage, focus.languageIdentifier),
            destinationOrigin: origin(explicitDestination, focus.destinationID)
        )
    }

    private static func origin(_ explicit: String?, _ focus: String?) -> Origin {
        explicit != nil ? .explicit : focus != nil ? .focus : .global
    }
}

private func captureNonblank(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}
