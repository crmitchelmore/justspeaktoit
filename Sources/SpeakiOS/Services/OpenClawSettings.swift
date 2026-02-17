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

    // MARK: - Available Voices & Models

    /// Deepgram Aura-2 voices.
    public static let availableVoices: [(id: String, label: String)] = [
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

    /// Deepgram TTS models — the id is used as a prefix before the voice name.
    public static let availableModels: [(id: String, label: String)] = [
        ("aura-2", "Aura 2 (English)"),
        ("aura", "Aura 1 (English)")
    ]

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
