import Foundation

/// One playable Read Aloud entry projected from a `VoiceProfile` and one bound engine.
public struct MyVoicePickerEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let profileID: UUID
    public let profileName: String
    public let engineID: String
    public let engineDisplayName: String
    public let language: String
    public let binding: VoiceProfileEngineBinding

    public init(
        profile: VoiceProfile,
        binding: VoiceProfileEngineBinding
    ) {
        self.id = binding.playableVoiceID(for: profile.id)
        self.profileID = profile.id
        self.profileName = profile.name
        self.engineID = binding.engineID
        self.engineDisplayName = binding.engineDisplayName
        self.language = profile.language
        self.binding = binding
    }

    public var displayName: String {
        "\(profileName) (\(engineDisplayName))"
    }

    public var desktopPickerLabel: String {
        "\(VoiceProfilePickerCatalog.groupTitle) · \(profileName) — \(engineDisplayName)"
    }

    public var desktopPickerIdentifier: String {
        let raw = "\(VoiceProfilePickerCatalog.desktopPickerIdentifierPrefix)"
            + "\(profileID.uuidString.lowercased())|\(engineID)|\(id)"
        return raw.count <= 260 ? raw : String(raw.prefix(260))
    }
}

/// Projects `VoiceProfile` bindings into the Read Aloud `My voices` picker group across desktop platforms.
public enum VoiceProfilePickerCatalog {
    public static let groupTitle = "My voices"
    public static let desktopPickerIdentifierPrefix = "voice-profile|"

    /// Profiles with no bound engine yet yield zero entries (never fabricated fallback voices).
    public static func entries(from profiles: [VoiceProfile]) -> [MyVoicePickerEntry] {
        profiles
            .flatMap { profile in
                profile.engineBindings.values.map { binding in
                    MyVoicePickerEntry(profile: profile, binding: binding)
                }
            }
            .sorted { lhs, rhs in
                let nameOrder = lhs.profileName.localizedStandardCompare(rhs.profileName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.profileID != rhs.profileID {
                    return lhs.profileID.uuidString < rhs.profileID.uuidString
                }
                let engineOrder = lhs.engineDisplayName.localizedStandardCompare(rhs.engineDisplayName)
                if engineOrder != .orderedSame { return engineOrder == .orderedAscending }
                return lhs.engineID < rhs.engineID
            }
    }

    public static func resolve(voiceID: String, in profiles: [VoiceProfile]) -> MyVoicePickerEntry? {
        entries(from: profiles).first { $0.id == voiceID || $0.desktopPickerIdentifier == voiceID }
    }

    public static func resolve(desktopPickerIdentifier: String, in profiles: [VoiceProfile]) -> MyVoicePickerEntry? {
        guard desktopPickerIdentifier.hasPrefix(desktopPickerIdentifierPrefix) else { return nil }
        return entries(from: profiles).first { $0.desktopPickerIdentifier == desktopPickerIdentifier }
    }

    public static func isProfileVoiceIdentifier(_ voiceID: String) -> Bool {
        voiceID.hasPrefix("local/tts/")
            || voiceID.hasPrefix("studio/")
            || voiceID.hasPrefix(desktopPickerIdentifierPrefix)
    }

    public static func unavailableMessage(for profileName: String? = nil, engineName: String? = nil) -> String {
        if let profileName, let engineName {
            return "\"\(profileName)\" cannot speak with \(engineName) on this build yet. "
                + "Choose another voice or install that voice engine."
        }
        return "This My voices profile has no available speech engine on this build yet. Choose another voice."
    }
}
