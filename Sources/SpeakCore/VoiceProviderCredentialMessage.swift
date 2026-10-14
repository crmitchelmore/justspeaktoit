import Foundation

public struct VoiceProviderCredentialRequest: Sendable {
    public let context: VoiceAccountCredentialContext
    public let id: UUID
    public let purpose: VoiceCredentialPurpose
    public let identifier: String
    public let operation: VoiceCredentialOperation

    public init(
        context: VoiceAccountCredentialContext, id: UUID, purpose: String,
        identifier: String, operation: VoiceCredentialOperation
    ) throws {
        guard VoiceCredentialPurpose(rawValue: purpose) == .voiceOutput else {
            throw VoiceOutputCredentialError.invalidPurpose
        }
        let slot = try VoiceOutputCredentialSlot(provider: context.provider)
        try slot.validate(purpose: purpose, identifier: identifier)
        self.context = context
        self.id = id
        self.purpose = .voiceOutput
        self.identifier = identifier
        self.operation = operation
    }
}

/// An explicit-provider entry never derives authority from a native-supplied slot.
public enum VoiceProviderCredentialMessage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case open(VoiceAccountCredentialContext, requestID: UUID)
    case cancel(VoiceAccountCredentialContext, requestID: UUID)
    case save(String, VoiceProviderCredentialRequest)

    public init(
        operation: String, purpose: String, providerID: String, identifier: String,
        sessionID: String, epoch: String, requestID: String, key: String
    ) throws {
        guard VoiceCredentialPurpose(rawValue: purpose) == .voiceOutput else {
            throw VoiceOutputCredentialError.invalidPurpose
        }
        guard operation.utf8.count <= 16, providerID.utf8.count <= 32, identifier.utf8.count <= 128,
              key.utf8.count <= 8_192,
              sessionID.utf8.count == 36, let session = UUID(uuidString: sessionID),
              epoch.utf8.count == 36, let epoch = UUID(uuidString: epoch),
              requestID.utf8.count == 36, let id = UUID(uuidString: requestID) else {
            throw VoiceOutputCredentialError.invalidRequest
        }
        let context = try VoiceAccountCredentialContext(
            provider: VoiceAccountProvider(id: providerID), sessionID: session, epoch: epoch)
        if operation == "open" || operation == "cancel" {
            guard identifier.isEmpty, key.isEmpty else { throw VoiceOutputCredentialError.invalidRequest }
            self = operation == "open" ? .open(context, requestID: id) : .cancel(context, requestID: id)
            return
        }
        guard let operation = VoiceCredentialOperation(rawValue: operation),
              operation != .remove || key.isEmpty else { throw VoiceOutputCredentialError.invalidRequest }
        let request = try VoiceProviderCredentialRequest(
            context: context, id: id, purpose: purpose, identifier: identifier, operation: operation)
        self = .save(operation == .remove ? "" : try VoiceOutputCredentialSlot(provider: context.provider)
            .validatedKey(key), request)
    }

    public var description: String {
        switch self {
        case .open(let context, _): "Open \(context.provider.displayName) Voice key entry"
        case .cancel(let context, _): "Cancel \(context.provider.displayName) Voice key entry"
        case .save(_, let request): "\(request.operation.rawValue) \(request.context.provider.displayName) Voice key"
        }
    }

    public var debugDescription: String { description }
}
