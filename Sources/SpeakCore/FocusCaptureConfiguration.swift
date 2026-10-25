import Foundation

/// Local contextual choices, never a transcript, Focus name or credential.
public struct FocusCaptureOverride: Codable, Equatable, Sendable {
    public let destinationID: String?
    public let modelID: String?
    public let languageIdentifier: String?

    public init(destinationID: String? = nil, modelID: String? = nil, languageIdentifier: String? = nil) {
        self.destinationID = destinationID
        self.modelID = modelID
        self.languageIdentifier = languageIdentifier
    }

    public static let none = FocusCaptureOverride()
    public var isEmpty: Bool { self == .none }

    public func affects(_ explicit: CaptureRunParameters) -> Bool {
        (destinationID != nil && explicit.destinationID == nil)
            || (modelID != nil && explicit.modelID == nil)
            || (languageIdentifier != nil && explicit.languageIdentifier == nil)
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
        // Validate only choices actually used. Explicit fields can replace invalid Focus fields.
        let parameters = try CaptureParameterResolution.resolve(
            destinationID: explicit.destinationID ?? focus.destinationID,
            language: explicit.languageIdentifier ?? focus.languageIdentifier,
            model: explicit.modelID ?? focus.modelID,
            source: explicit.sourceTag,
            vocabulary: vocabulary
        )
        return Self(
            parameters: parameters,
            modelID: parameters.modelID ?? globals.modelID,
            usesBatch: parameters.modelID == nil ? globals.usesBatch : parameters.requiresBatchMode,
            languageIdentifier: parameters.languageIdentifier ?? globals.languageIdentifier,
            destinationID: parameters.destinationID ?? globals.destinationID,
            modelOrigin: origin(explicit.modelID, focus.modelID),
            languageOrigin: origin(explicit.languageIdentifier, focus.languageIdentifier),
            destinationOrigin: origin(explicit.destinationID, focus.destinationID)
        )
    }

    private static func origin(_ explicit: String?, _ focus: String?) -> Origin {
        explicit != nil ? .explicit : focus != nil ? .focus : .global
    }
}
