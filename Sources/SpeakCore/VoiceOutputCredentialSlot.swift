import Foundation

public enum VoiceCredentialPurpose: String, Sendable {
    case voiceOutput = "voice-output"
}

public enum VoiceCredentialOperation: String, Sendable {
    case replace, remove
}

public struct VoiceOutputCredentialRequest: Sendable {
    public let id: UUID
    public let selectionEpoch: UUID
    public let purpose: VoiceCredentialPurpose
    public let identifier: String
    public let operation: VoiceCredentialOperation

    public init(
        id: UUID, selectionEpoch: UUID, purpose: String, identifier: String,
        operation: VoiceCredentialOperation
    ) throws {
        guard let purpose = VoiceCredentialPurpose(rawValue: purpose) else {
            throw VoiceOutputCredentialError.invalidPurpose
        }
        self.id = id
        self.selectionEpoch = selectionEpoch
        self.purpose = purpose
        self.identifier = identifier
        self.operation = operation
    }
}

public enum VoiceOutputCredentialMessage: Sendable {
    case open(UUID)
    case cancel(UUID)
    case save(String, VoiceOutputCredentialRequest)

    public init(
        operation: String, purpose: String, identifier: String, requestID: String,
        selectionEpoch: String, key: String
    ) throws {
        guard VoiceCredentialPurpose(rawValue: purpose) == .voiceOutput else {
            throw VoiceOutputCredentialError.invalidPurpose
        }
        guard requestID.count == 36, let id = UUID(uuidString: requestID) else {
            throw VoiceOutputCredentialError.invalidRequest
        }
        if operation == "open" || operation == "cancel" {
            guard identifier.isEmpty, selectionEpoch.isEmpty, key.isEmpty else {
                throw VoiceOutputCredentialError.invalidRequest
            }
            self = operation == "open" ? .open(id) : .cancel(id)
            return
        }
        guard let operation = VoiceCredentialOperation(rawValue: operation),
              selectionEpoch.count == 36, let epoch = UUID(uuidString: selectionEpoch),
              !identifier.isEmpty, identifier.utf8.count <= 128,
              operation != .remove || key.isEmpty else {
            throw VoiceOutputCredentialError.invalidRequest
        }
        self = .save(key, try .init(
            id: id, selectionEpoch: epoch, purpose: purpose, identifier: identifier, operation: operation))
    }
}

/// A credential destination, never a secret or a transcription model index.
public struct VoiceOutputCredentialSlot: Equatable, Sendable {
    public let purpose: VoiceCredentialPurpose
    public let identifier: String
    public let providerName: String

    public init(provider: VoiceAccountProvider) throws {
        guard case .apiKey(let identifier, let name) = ModelCredentialResolver.requirement(
            for: provider.id, purpose: .voiceOutput) else { throw VoiceOutputCredentialError.unavailable }
        self.purpose = .voiceOutput
        self.identifier = identifier
        self.providerName = name
    }

    public init(voice: DesktopSpeechVoice, inventory: XAIAccountVoiceInventory? = nil) throws {
        try self.init(voice: voice, accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    public init(voice: DesktopSpeechVoice, accountInventory: VoiceAccountInventory?) throws {
        let resolverID: String
        if case .deepgram = voice {
            resolverID = VoiceOutputProvider.deepgram.rawValue
        } else {
            resolverID = voice.id
        }
        guard DesktopSpeechVoice.voices.contains(voice) || accountInventory?.contains(voice) == true,
              case .apiKey(let identifier, let providerName) = ModelCredentialResolver.requirement(
                for: resolverID, purpose: .voiceOutput),
              identifier == voice.apiKeyIdentifier else {
            throw VoiceOutputCredentialError.unavailable
        }
        self.purpose = .voiceOutput
        self.identifier = identifier
        self.providerName = providerName
    }

    public func validate(purpose: String, identifier: String) throws {
        guard VoiceCredentialPurpose(rawValue: purpose) == self.purpose else {
            throw VoiceOutputCredentialError.invalidPurpose
        }
        guard identifier == self.identifier else { throw VoiceOutputCredentialError.destinationChanged }
    }

    public func validatedKey(_ key: String) throws -> String {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoiceOutputCredentialError.emptyKey }
        guard cleaned.utf8.count <= 8_192,
              cleaned.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceOutputCredentialError.invalidKey
        }
        if identifier == AzureSpeechConfiguration.credentialIdentifier {
            do { _ = try AzureSpeechConfiguration(credentials: cleaned) } catch {
                throw VoiceOutputCredentialError.invalidAzureKey
            }
        }
        return cleaned
    }

    public var entryLabel: String {
        identifier == OpenAITTSCatalog.credentialIdentifier
            ? "OpenAI Voice Output key (separate from transcription)"
            : "\(providerName) Voice Output key"
    }

    public var privacyDescription: String {
        "Voice text is sent to \(providerName) using this key. The key is stored securely, not in Voice text, "
            + "settings or audio exports. Existing key-sync preferences still apply."
            + (identifier == OpenAITTSCatalog.credentialIdentifier
                ? " This is separate from the OpenAI transcription key."
                : " Other features using this same provider key also see replacements or removal.")
    }
}

public enum VoiceOutputCredentialError: LocalizedError, Equatable, Sendable {
    case invalidPurpose, invalidRequest, destinationChanged, unavailable, emptyKey, invalidKey, invalidAzureKey
    case busy, closed, cancelled, readFailed, saveFailed
    case completedForPreviousSelection, completedWhileClosing

    public var errorDescription: String? {
        switch self {
        case .invalidPurpose: "This credential request is not for Voice Output."
        case .invalidRequest: "The Voice key request is invalid. Reopen key entry and retry."
        case .destinationChanged: "The Voice provider changed. Reopen its key entry before saving."
        case .unavailable: "Choose an available Voice Output voice before entering its provider key."
        case .emptyKey: "Enter a new key to save it. Cancel keeps the existing key."
        case .invalidKey: "The key contains control characters or exceeds 8,192 UTF-8 bytes."
        case .invalidAzureKey: "Enter the Azure Speech key and region as key:region."
        case .busy: "Wait for recording and Voice Output work to finish before saving a provider key."
        case .closed: "The app is closing. The Voice provider key was not admitted."
        case .cancelled: "Saving the Voice provider key was cancelled. Check the credential store before retrying."
        case .readFailed:
            "The saved Voice provider key could not be checked. Retry when the credential store is available."
        case .saveFailed:
            "The Voice provider key save could not be confirmed. Check the credential store before retrying."
        case .completedForPreviousSelection:
            "The key operation completed for the previous Voice selection. Reopen key entry for the current voice."
        case .completedWhileClosing:
            "The key operation completed while closing or cancelling. Check the credential store before retrying."
        }
    }
}
