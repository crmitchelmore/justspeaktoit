#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

// MARK: - OpenClaw Settings Manager

/// Manages OpenClaw gateway connection settings separately from main AppSettings
/// to avoid access control issues with the private keychain methods.
@MainActor
public final class OpenClawSettings: ObservableObject {
    public static let shared = OpenClawSettings()

    @Published public var gatewayURL: String {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: "openclaw.gatewayURL") }
    }

    @Published public var token: String {
        didSet { saveToKeychain(key: token, for: "openclaw.token") }
    }

    @Published public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "openclaw.enabled") }
    }

    @Published public var ttsEnabled: Bool {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: "openclaw.ttsEnabled") }
    }

    @Published public var summariseResponses: Bool {
        didSet { UserDefaults.standard.set(summariseResponses, forKey: "openclaw.summarise") }
    }

    @Published public var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "openclaw.ttsVoice") }
    }

    @Published public var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: "openclaw.ttsModel") }
    }

    @Published public var ttsSpeed: Double {
        didSet { UserDefaults.standard.set(ttsSpeed, forKey: "openclaw.ttsSpeed") }
    }

    @Published public var conversationModeEnabled: Bool {
        didSet { UserDefaults.standard.set(conversationModeEnabled, forKey: "openclaw.conversationModeEnabled") }
    }

    @Published public var autoResumeListening: Bool {
        didSet { UserDefaults.standard.set(autoResumeListening, forKey: "openclaw.autoResumeListening") }
    }

    @Published public var headsetSingleTapAcknowledge: Bool {
        didSet {
            UserDefaults.standard.set(
                headsetSingleTapAcknowledge,
                forKey: "openclaw.headsetSingleTapAcknowledge"
            )
        }
    }

    @Published public var keywordAcknowledgeEnabled: Bool {
        didSet { UserDefaults.standard.set(keywordAcknowledgeEnabled, forKey: "openclaw.keywordAcknowledgeEnabled") }
    }

    @Published public var keywordAcknowledgePhrase: String {
        didSet { UserDefaults.standard.set(keywordAcknowledgePhrase, forKey: "openclaw.keywordAcknowledgePhrase") }
    }

    @Published public var lowLatencySpeech: Bool {
        didSet { UserDefaults.standard.set(lowLatencySpeech, forKey: "openclaw.lowLatencySpeech") }
    }

    // MARK: - Available Voices & Models

    /// Deepgram Aura-2 voices (from official docs).
    public static let aura2Voices: [(id: String, label: String)] = [
        ("andromeda", "Andromeda (American, Female)"),
        ("apollo", "Apollo (American, Male)"),
        ("arcas", "Arcas (American, Male)"),
        ("aries", "Aries (American, Male)"),
        ("asteria", "Asteria (American, Female)"),
        ("athena", "Athena (American, Female)"),
        ("aurora", "Aurora (American, Female)"),
        ("callista", "Callista (American, Female)"),
        ("cora", "Cora (American, Female)"),
        ("draco", "Draco (British, Male)"),
        ("electra", "Electra (American, Female)"),
        ("helena", "Helena (American, Female)"),
        ("hera", "Hera (American, Female)"),
        ("hermes", "Hermes (American, Male)"),
        ("luna", "Luna (American, Female)"),
        ("orion", "Orion (American, Male)"),
        ("orpheus", "Orpheus (American, Male)"),
        ("pandora", "Pandora (British, Female)"),
        ("thalia", "Thalia (American, Female)")
    ]

    /// Deepgram Aura-1 voices.
    public static let aura1Voices: [(id: String, label: String)] = [
        ("asteria", "Asteria (American, Female)"),
        ("luna", "Luna (American, Female)"),
        ("stella", "Stella (American, Female)"),
        ("athena", "Athena (British, Female)"),
        ("hera", "Hera (American, Female)"),
        ("orion", "Orion (American, Male)"),
        ("arcas", "Arcas (American, Male)"),
        ("perseus", "Perseus (American, Male)"),
        ("angus", "Angus (Irish, Male)"),
        ("orpheus", "Orpheus (American, Male)"),
        ("helios", "Helios (British, Male)"),
        ("zeus", "Zeus (American, Male)")
    ]

    /// Returns voices available for the given model.
    public static func voices(for model: String) -> [(id: String, label: String)] {
        model.hasPrefix("aura-2") ? aura2Voices : aura1Voices
    }

    /// Deepgram TTS models — the id is used as a prefix before the voice name.
    public static let availableModels: [(id: String, label: String)] = [
        ("aura-2", "Aura 2 (English)"),
        ("aura", "Aura 1 (English)")
    ]

    /// Validate that the current voice is compatible with the current model,
    /// falling back to the first available voice if not.
    public func validateVoiceModelCombination() {
        let validVoices = Self.voices(for: ttsModel)
        if !validVoices.contains(where: { $0.id == ttsVoice }) {
            ttsVoice = validVoices.first?.id ?? "asteria"
        }
    }

    public var isConfigured: Bool {
        !gatewayURL.isEmpty && !token.isEmpty && enabled
    }

    private init() {
        self.gatewayURL = UserDefaults.standard.string(forKey: "openclaw.gatewayURL") ?? ""
        self.token = Self.loadFromKeychain(for: "openclaw.token") ?? ""
        self.enabled = UserDefaults.standard.bool(forKey: "openclaw.enabled")
        self.ttsEnabled = UserDefaults.standard.object(forKey: "openclaw.ttsEnabled") as? Bool ?? true
        self.summariseResponses = UserDefaults.standard.object(forKey: "openclaw.summarise") as? Bool ?? true
        self.ttsVoice = UserDefaults.standard.string(forKey: "openclaw.ttsVoice") ?? "asteria"
        self.ttsModel = UserDefaults.standard.string(forKey: "openclaw.ttsModel") ?? "aura-2"
        self.ttsSpeed = UserDefaults.standard.object(forKey: "openclaw.ttsSpeed") as? Double ?? 1.0
        self.conversationModeEnabled =
            UserDefaults.standard.object(forKey: "openclaw.conversationModeEnabled") as? Bool ?? false
        self.autoResumeListening = UserDefaults.standard.object(forKey: "openclaw.autoResumeListening") as? Bool ?? true
        self.headsetSingleTapAcknowledge =
            UserDefaults.standard.object(forKey: "openclaw.headsetSingleTapAcknowledge") as? Bool ?? false
        self.keywordAcknowledgeEnabled =
            UserDefaults.standard.object(forKey: "openclaw.keywordAcknowledgeEnabled") as? Bool ?? false
        self.keywordAcknowledgePhrase =
            UserDefaults.standard.string(forKey: "openclaw.keywordAcknowledgePhrase") ?? "over"
        self.lowLatencySpeech = UserDefaults.standard.object(forKey: "openclaw.lowLatencySpeech") as? Bool ?? false

        // Validate saved voice is compatible with saved model
        validateVoiceModelCombination()
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, for account: String) {
        let service = "com.speak.ios.credentials"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !key.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadFromKeychain(for account: String) -> String? {
        let service = "com.speak.ios.credentials"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }
}
#endif
