import SpeakCore
import SwiftUI

/// macOS projection of the shared settings search catalogue.
enum MacSettingsSearch {
    /// Prefix for runtime entries that stand for one API-key card.
    static let apiKeyEntryPrefix = "apiKey."

    private struct KeyCard {
        let cardID: String
        let title: String
        let category: String
    }

    /// Catalogue entries this build renders; cards behind an off feature flag are
    /// left out so search never offers a destination that isn't there.
    static let catalogEntries: [SettingsSearchEntry] = {
        let paidAccessIDs: Set<String> = ["apiKeys.subscription", "transcription.modelsChosenForYou"]
        return SendToMacAvailability.filter(SettingsSearchCatalog.entries(for: .macOS)).filter {
            PaidAccessFeature.isEnabled || !paidAccessIDs.contains($0.id)
        }
    }()

    /// One entry per API-key card, generated from the same provider lists the
    /// API Keys page renders, so a new provider is searchable without edits here.
    static func apiKeyEntries(transcriptionProviders: [TranscriptionProviderMetadata]) -> [SettingsSearchEntry] {
        let sharedCredentialIDs = Set(TTSProvider.allCases.filter(\.sharesTranscriptionCredential).map(\.id))
        var cards = [
            KeyCard(
                cardID: "general-openrouter",
                title: "OpenRouter",
                category: "Transcription, Voice Output & Post-processing"
            )
        ]
        cards += transcriptionProviders
            .filter { !sharedCredentialIDs.contains($0.id) }
            .map { KeyCard(cardID: "transcription-\($0.id)", title: $0.displayName, category: "Transcription") }
        cards += TTSProvider.apiKeyCardProviders.map { provider in
            KeyCard(
                cardID: "tts-\(provider.id)",
                title: provider == .elevenlabs ? "ElevenLabs" : provider.displayName,
                category: provider.sharesTranscriptionCredential ? "Transcription & Voice Output" : "Voice Output"
            )
        }
        return cards.map { card in
            SettingsSearchEntry(
                id: apiKeyEntryPrefix + card.cardID,
                title: "\(card.title) API key",
                section: .apiKeys,
                systemImage: "key.fill",
                summary: "Add, validate or remove the \(card.title) key (\(card.category)).",
                keywords: [card.title, "\(card.title) key", "api key", "token", card.category],
                platforms: .macOS
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func sidebarItem(for section: SettingsSearchSection) -> SidebarItem {
        switch section {
        case .general: return .settings(.general)
        case .transcription: return .settings(.transcription)
        case .postProcessing: return .settings(.postProcessing)
        case .profiles: return .settings(.profiles)
        case .voiceOutput: return .settings(.voiceOutput)
        case .pronunciation: return .settings(.pronunciation)
        case .apiKeys: return .settings(.apiKeys)
        case .shortcuts: return .settings(.shortcuts)
        case .permissions: return .settings(.permissions)
        case .compareModels: return .settings(.compareModels)
        case .dataMigration: return .settings(.dataMigration)
        case .about: return .settings(.about)
        case .corrections: return .corrections
        case .troubleshooting: return .troubleshooting
        }
    }
}

extension SettingsTab {
    /// Every settings page must have a search section; adding a tab without one
    /// fails to compile here.
    var searchSection: SettingsSearchSection {
        switch self {
        case .general: return .general
        case .transcription: return .transcription
        case .postProcessing: return .postProcessing
        case .profiles: return .profiles
        case .voiceOutput: return .voiceOutput
        case .pronunciation: return .pronunciation
        case .apiKeys: return .apiKeys
        case .shortcuts: return .shortcuts
        case .permissions: return .permissions
        case .compareModels: return .compareModels
        case .dataMigration: return .dataMigration
        case .about: return .about
        }
    }
}

private struct SettingsSearchHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The settings search entry currently being revealed, if any.
    var settingsSearchHighlightID: String? {
        get { self[SettingsSearchHighlightKey.self] }
        set { self[SettingsSearchHighlightKey.self] = newValue }
    }
}

/// Draws the reveal highlight when settings search navigates to `entryID`.
struct SettingsSearchHighlight: ViewModifier {
    @Environment(\.settingsSearchHighlightID) private var highlightID
    let entryID: String

    func body(content: Content) -> some View {
        let isHighlighted = highlightID == entryID
        content
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(isHighlighted ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(.easeInOut(duration: 0.35), value: isHighlighted)
    }
}

extension View {
    /// Anchors a settings card for search: a scroll target plus the reveal
    /// highlight. `entryID` overrides the title lookup for runtime headings.
    @ViewBuilder
    func settingsSearchAnchor(title: String, entryID: String? = nil) -> some View {
        if let id = entryID ?? SettingsSearchCatalog.entry(title: title, platform: .macOS)?.id {
            modifier(SettingsSearchHighlight(entryID: id)).id(id)
        } else {
            self
        }
    }

    func settingsSearchHighlight(entryID: String) -> some View {
        modifier(SettingsSearchHighlight(entryID: entryID))
    }
}
