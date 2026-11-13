import Foundation

/// Whether a selected model can run on this device right now.
///
/// Product rule: an unavailable model is reported, never silently replaced by
/// another one (`Docs/ios-keyboard-v2-design.md`, `Docs/desktop-porting-playbook.md`
/// §6). Pickers, the keyboard profile menu and recording start all evaluate
/// availability here so they agree on what "unavailable" means and say it the
/// same way.
public struct TranscriptionModelAvailability: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case available
        /// The platform has no execution path for this model in this mode.
        case unsupportedOnPlatform
        /// Secure storage could not be read (for example before first unlock),
        /// so a stored key cannot be told apart from a missing one.
        case credentialsUnavailable
        /// The model needs an API key that is not stored on this device.
        case missingCredential
    }

    public let status: Status
    /// The provider whose credential is needed, when one is.
    public let providerName: String?

    public init(status: Status, providerName: String? = nil) {
        self.status = status
        self.providerName = providerName
    }

    public static let available = TranscriptionModelAvailability(status: .available)

    public var isAvailable: Bool { status == .available }

    /// Short, user-facing reason for menus and accessibility; `nil` when available.
    public var note: String? {
        switch status {
        case .available:
            return nil
        case .unsupportedOnPlatform:
            return "Unavailable: not supported on this device"
        case .credentialsUnavailable:
            return "Unavailable: API keys are locked until you unlock this device"
        case .missingCredential:
            return "Unavailable: \(providerName ?? "provider") API key not set"
        }
    }

    /// Applies the rule: an unsupported route is unavailable, a model with no
    /// credential requirement is available, and otherwise the credential must
    /// have been readable and non-blank.
    public static func evaluate(
        requirement: ModelCredentialRequirement,
        isExecutableHere: Bool,
        credentialsLoaded: Bool,
        credential: String?
    ) -> TranscriptionModelAvailability {
        guard isExecutableHere else { return TranscriptionModelAvailability(status: .unsupportedOnPlatform) }
        guard case .apiKey(_, let providerName) = requirement else { return .available }
        guard credentialsLoaded else {
            return TranscriptionModelAvailability(status: .credentialsUnavailable, providerName: providerName)
        }
        let trimmed = (credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? TranscriptionModelAvailability(status: .missingCredential, providerName: providerName)
            : .available
    }

    /// The first unavailable part, so a profile reports its transcription
    /// model before its post-processing model.
    public static func first(of parts: [TranscriptionModelAvailability]) -> TranscriptionModelAvailability {
        parts.first { !$0.isAvailable } ?? .available
    }
}

/// Thrown when recording would start with a selected model that cannot run.
/// The recording is not started and no other model is substituted.
public struct TranscriptionModelUnavailableError: LocalizedError, Equatable, Sendable {
    public let modelIdentifier: String
    public let modelName: String
    public let availability: TranscriptionModelAvailability

    public init(modelIdentifier: String, modelName: String, availability: TranscriptionModelAvailability) {
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.availability = availability
    }

    public var errorDescription: String? {
        let reason: String
        switch availability.status {
        case .available, .unsupportedOnPlatform:
            reason = "it isn't supported on this device. Choose another model in Settings."
        case .credentialsUnavailable:
            reason = "API keys can't be read until this device is unlocked. Unlock it and try again."
        case .missingCredential:
            reason = "the \(availability.providerName ?? "provider") API key isn't set. "
                + "Add it in Settings, or choose another model."
        }
        return "\(modelName) is unavailable: \(reason) The recording was not started."
    }
}
