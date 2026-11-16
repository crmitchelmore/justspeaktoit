#if os(iOS)
import Foundation
import SpeakCore

/// Remembers the Local sub-mode and the batch model on each side of Local › Downloaded model and
/// Remote › Batch, which share `batchTranscriptionModel`, so switching back
/// restores the user's choice. Derived navigation state, not a setting: the
/// active choice is always `batchTranscriptionModel`.
enum IOSLocalModelSelectionMemory {
    static let localModelKey = "iosRememberedDownloadedTranscriptionModel"
    static let remoteModelKey = "iosRememberedRemoteBatchTranscriptionModel"
    static let localModeKey = "iosRememberedLocalTranscriptionMode"

    /// Apple Speech (streaming) or a downloaded model (batch).
    static func localMode(defaults: UserDefaults) -> IOSTranscriptionMode? {
        defaults.string(forKey: localModeKey).flatMap(IOSTranscriptionMode.init(rawValue:))
    }

    static func rememberLocalMode(_ mode: IOSTranscriptionMode, defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: localModeKey)
    }

    static func localModel(defaults: UserDefaults) -> String? {
        nonEmpty(defaults.string(forKey: localModelKey))
    }

    static func remoteModel(defaults: UserDefaults) -> String? {
        nonEmpty(defaults.string(forKey: remoteModelKey))
    }

    static func rememberLocalModel(_ identifier: String, defaults: UserDefaults) {
        defaults.set(identifier, forKey: localModelKey)
    }

    static func rememberRemoteModel(_ identifier: String, defaults: UserDefaults) {
        defaults.set(identifier, forKey: remoteModelKey)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
#endif
