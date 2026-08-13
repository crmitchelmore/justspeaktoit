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
    public static let sonioxBuiltInVoices = SonioxTTSCatalog.voices

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

    @Published public var ttsProvider: VoiceOutputProvider {
        didSet { UserDefaults.standard.set(ttsProvider.rawValue, forKey: "openclaw.ttsProvider") }
    }

    @Published public var summariseResponses: Bool {
        didSet { UserDefaults.standard.set(summariseResponses, forKey: "openclaw.summarise") }
    }

    @Published public var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "openclaw.ttsVoice") }
    }

    @Published public var ttsVoiceName: String {
        didSet { UserDefaults.standard.set(ttsVoiceName, forKey: "openclaw.ttsVoiceName") }
    }

    @Published public var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: "openclaw.ttsModel") }
    }

    @Published public var ttsSpeed: Double {
        didSet { UserDefaults.standard.set(ttsSpeed, forKey: "openclaw.ttsSpeed") }
    }

    @Published public var ttsLanguageIdentifier: String {
        didSet { UserDefaults.standard.set(ttsLanguageIdentifier, forKey: "openclaw.ttsLanguage") }
    }

    @Published public var sonioxRegion: SonioxTTSRegion {
        didSet { UserDefaults.standard.set(sonioxRegion.rawValue, forKey: "openclaw.sonioxRegion") }
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

    /// Migrates legacy selections and keeps the selected voice compatible with its model.
    public func validateVoiceModelCombination() {
        switch ttsProvider {
        case .deepgram:
            let incompatibleVoice = ttsVoice.hasPrefix("soniox/") ? nil : ttsVoice
            let selection = DeepgramTTSCatalog.resolvedSelection(modelID: ttsModel, voiceID: incompatibleVoice)
            if ttsModel != selection.model.id { ttsModel = selection.model.id }
            if ttsVoice != selection.voice.id { ttsVoice = selection.voice.id }
            ttsVoiceName = selection.voice.displayName
        case .soniox:
            ttsModel = SonioxTTSCatalog.defaultModel.rawValue
            if let voice = SonioxTTSCatalog.voice(forID: ttsVoice) {
                ttsVoice = voice.providerVoiceID
                ttsVoiceName = voice.displayName
            } else if !ttsVoice.hasPrefix("soniox/") {
                let voice = SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
                ttsVoice = voice.providerVoiceID
                ttsVoiceName = voice.displayName
            }
        }
        ttsSpeed = min(max(ttsSpeed, ttsProvider.speedRange.lowerBound), ttsProvider.speedRange.upperBound)
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
        let storedModel = UserDefaults.standard.string(forKey: "openclaw.ttsModel")
        let storedVoice = UserDefaults.standard.string(forKey: "openclaw.ttsVoice")
        self.ttsProvider = VoiceOutputProvider(
            rawValue: UserDefaults.standard.string(forKey: "openclaw.ttsProvider") ?? ""
        ) ?? VoiceOutputProvider.inferred(modelID: storedModel, voiceID: storedVoice)
        if ttsProvider == .soniox {
            self.ttsModel = SonioxTTSCatalog.defaultModel.rawValue
            if let storedVoice, storedVoice.hasPrefix("soniox/") {
                self.ttsVoice = storedVoice
            } else {
                self.ttsVoice = SonioxTTSCatalog.defaultVoice(
                    for: SonioxTTSCatalog.defaultModel
                ).providerVoiceID
            }
        } else {
            let selection = DeepgramTTSCatalog.resolvedSelection(modelID: storedModel, voiceID: storedVoice)
            self.ttsVoice = selection.voice.id
            self.ttsModel = selection.model.id
        }
        self.ttsVoiceName = UserDefaults.standard.string(forKey: "openclaw.ttsVoiceName") ?? ttsVoice
        self.ttsSpeed = UserDefaults.standard.object(forKey: "openclaw.ttsSpeed") as? Double ?? 1.0
        self.ttsLanguageIdentifier = VoiceOutputLanguageCatalog.normalizedIdentifier(
            UserDefaults.standard.string(forKey: "openclaw.ttsLanguage")
        )
        self.sonioxRegion = SonioxTTSRegion.migrated(
            from: UserDefaults.standard.string(forKey: "openclaw.sonioxRegion")
        )
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

        UserDefaults.standard.set(ttsVoice, forKey: "openclaw.ttsVoice")
        UserDefaults.standard.set(ttsModel, forKey: "openclaw.ttsModel")
        UserDefaults.standard.set(ttsProvider.rawValue, forKey: "openclaw.ttsProvider")
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
