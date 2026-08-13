import Foundation

/// Where a keyboard profile executes. The extension never resolves credentials:
/// app-owned models and post-processing always run through the containing app.
public enum KeyboardDictationProfileRoute: String, Codable, Equatable, Sendable {
    case directAppleSpeech
    case appHandoff

    public var displayName: String {
        switch self {
        case .directAppleSpeech: return "On-device"
        case .appHandoff: return "Via app"
        }
    }
}

/// Transcription mode snapshotted from the containing app without importing an
/// iOS-only settings type into SpeakCore.
public enum KeyboardDictationTranscriptionMode: String, Codable, Equatable, Sendable {
    case streaming
    case batch
}

/// One extension-safe profile projection. It deliberately contains identifiers
/// and display metadata only: credentials remain in the containing app's
/// Keychain and prompts remain in their owning process.
public struct KeyboardDictationProfileOption: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let chipLabel: String
    public let route: KeyboardDictationProfileRoute
    public let transcriptionMode: KeyboardDictationTranscriptionMode
    public let transcriptionModelIdentifier: String
    public let languageIdentifier: String
    public let postProcessingEnabled: Bool
    public let postProcessingModelIdentifier: String?

    public init(
        id: String,
        displayName: String,
        chipLabel: String,
        route: KeyboardDictationProfileRoute,
        transcriptionMode: KeyboardDictationTranscriptionMode,
        transcriptionModelIdentifier: String,
        languageIdentifier: String,
        postProcessingEnabled: Bool,
        postProcessingModelIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.chipLabel = chipLabel
        self.route = route
        self.transcriptionMode = transcriptionMode
        self.transcriptionModelIdentifier = transcriptionModelIdentifier
        self.languageIdentifier = TranscriptionLanguageCatalog.normalizedIdentifier(languageIdentifier)
        self.postProcessingEnabled = postProcessingEnabled
        self.postProcessingModelIdentifier = postProcessingEnabled
            ? postProcessingModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    public var polishes: Bool {
        postProcessingEnabled && postProcessingModelIdentifier?.isEmpty == false
    }
}

/// Non-secret app settings used to publish the app-owned keyboard projection.
public struct KeyboardAppProfileConfiguration: Equatable, Sendable {
    public let transcriptionMode: KeyboardDictationTranscriptionMode
    public let transcriptionModelIdentifier: String
    public let languageIdentifier: String
    public let postProcessingEnabled: Bool
    public let postProcessingModelIdentifier: String?

    public init(
        transcriptionMode: KeyboardDictationTranscriptionMode,
        transcriptionModelIdentifier: String,
        languageIdentifier: String,
        postProcessingEnabled: Bool,
        postProcessingModelIdentifier: String?
    ) {
        self.transcriptionMode = transcriptionMode
        self.transcriptionModelIdentifier = transcriptionModelIdentifier
        self.languageIdentifier = languageIdentifier
        self.postProcessingEnabled = postProcessingEnabled
        self.postProcessingModelIdentifier = postProcessingModelIdentifier
    }
}

/// Canonical keyboard-mode catalogue shared by the app and extension.
///
/// `Local` always runs inside the extension with Apple Speech. `App` snapshots
/// the app's exact active model, mode, language, and post-processing choice and
/// routes the whole session through the app. Consequently cloud configuration
/// is never silently downgraded and profile switching remains available on
/// devices without Apple Foundation Models.
public enum KeyboardDictationProfileCatalog {
    public static let maxChipLabelLength = 5
    public static let maxCycleTaps = 2

    public static let directIdentifier = "direct-apple-speech"
    public static let appIdentifier = "app-current-mode"

    public static func selection(
        for configuration: KeyboardAppProfileConfiguration,
        selectedIdentifier: String? = nil,
        revision: UInt64 = 0,
        modifiedAt: Date = Date()
    ) -> KeyboardProfileSelection {
        let language = TranscriptionLanguageCatalog.normalizedIdentifier(configuration.languageIdentifier)
        let direct = KeyboardDictationProfileOption(
            id: directIdentifier,
            displayName: "Local Apple Speech",
            chipLabel: "Local",
            route: .directAppleSpeech,
            transcriptionMode: .streaming,
            transcriptionModelIdentifier: AppleLocalModels.legacySpeechModelID,
            languageIdentifier: language,
            postProcessingEnabled: false
        )
        let isBatch = configuration.transcriptionMode == .batch
        let appModelName = ModelCatalog.transcriptionDisplayName(
            for: configuration.transcriptionModelIdentifier,
            isBatch: isBatch
        )
        let app = KeyboardDictationProfileOption(
            id: appIdentifier,
            displayName: "App: \(appModelName)",
            chipLabel: "App",
            route: .appHandoff,
            transcriptionMode: configuration.transcriptionMode,
            transcriptionModelIdentifier: configuration.transcriptionModelIdentifier,
            languageIdentifier: language,
            postProcessingEnabled: configuration.postProcessingEnabled,
            postProcessingModelIdentifier: configuration.postProcessingModelIdentifier
        )
        return KeyboardProfileSelection(
            selectedIdentifier: selectedIdentifier ?? appIdentifier,
            availableProfiles: [direct, app],
            defaultIdentifier: appIdentifier,
            catalogueRevision: revision,
            catalogueModifiedAt: modifiedAt
        )
    }
}

/// App-owned catalogue plus a selected stable identifier. The store persists
/// the catalogue and keyboard selection under separate keys, so concurrent app
/// refreshes cannot overwrite a keyboard-side choice and readers never mix
/// model, language, route, or post-processing fields from different revisions.
public struct KeyboardProfileSelection: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let selectedIdentifier: String
    public let availableProfiles: [KeyboardDictationProfileOption]
    public let defaultIdentifier: String
    public let catalogueRevision: UInt64
    public let catalogueModifiedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedIdentifier
        case availableProfiles
        case defaultIdentifier
        case catalogueRevision
        case catalogueModifiedAt
    }

    public init(
        schemaVersion: Int = Self.schemaVersion,
        selectedIdentifier: String?,
        availableProfiles: [KeyboardDictationProfileOption],
        defaultIdentifier: String,
        catalogueRevision: UInt64,
        catalogueModifiedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        var seen = Set<String>()
        let normalizedProfiles = availableProfiles.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert($0.id).inserted
        }
        self.availableProfiles = normalizedProfiles
        let fallback = normalizedProfiles.contains { $0.id == defaultIdentifier }
            ? defaultIdentifier
            : normalizedProfiles.first?.id ?? KeyboardDictationProfileCatalog.directIdentifier
        self.defaultIdentifier = fallback
        let requested = selectedIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedIdentifier = normalizedProfiles.contains { $0.id == requested } ? requested ?? fallback : fallback
        self.catalogueRevision = catalogueRevision
        self.catalogueModifiedAt = catalogueModifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            selectedIdentifier: try container.decodeIfPresent(String.self, forKey: .selectedIdentifier),
            availableProfiles: try container.decode([KeyboardDictationProfileOption].self, forKey: .availableProfiles),
            defaultIdentifier: try container.decode(String.self, forKey: .defaultIdentifier),
            catalogueRevision: try container.decode(UInt64.self, forKey: .catalogueRevision),
            catalogueModifiedAt: try container.decode(Date.self, forKey: .catalogueModifiedAt)
        )
    }

    public static let directOnly: KeyboardProfileSelection = {
        let configuration = KeyboardAppProfileConfiguration(
            transcriptionMode: .streaming,
            transcriptionModelIdentifier: AppleLocalModels.legacySpeechModelID,
            languageIdentifier: TranscriptionLanguageCatalog.automaticIdentifier,
            postProcessingEnabled: false,
            postProcessingModelIdentifier: nil
        )
        let projected = KeyboardDictationProfileCatalog.selection(for: configuration)
        return KeyboardProfileSelection(
            selectedIdentifier: KeyboardDictationProfileCatalog.directIdentifier,
            availableProfiles: [projected.availableProfiles[0]],
            defaultIdentifier: KeyboardDictationProfileCatalog.directIdentifier,
            catalogueRevision: 0,
            catalogueModifiedAt: .distantPast
        )
    }()

    public var selectedProfile: KeyboardDictationProfileOption {
        availableProfiles.first { $0.id == selectedIdentifier }
            ?? availableProfiles.first
            ?? Self.directOnly.availableProfiles[0]
    }

    public var nextQuickIdentifier: String? {
        guard availableProfiles.count > 1,
              let index = availableProfiles.firstIndex(where: { $0.id == selectedIdentifier }) else {
            return nil
        }
        return availableProfiles[(index + 1) % availableProfiles.count].id
    }

    public func selecting(_ identifier: String?) -> KeyboardProfileSelection {
        KeyboardProfileSelection(
            schemaVersion: schemaVersion,
            selectedIdentifier: identifier,
            availableProfiles: availableProfiles,
            defaultIdentifier: defaultIdentifier,
            catalogueRevision: catalogueRevision,
            catalogueModifiedAt: catalogueModifiedAt
        )
    }

    public var chipLabel: String { selectedProfile.chipLabel }
    public var displayName: String { selectedProfile.displayName }
    public var route: KeyboardDictationProfileRoute { selectedProfile.route }
}

/// Requires exact, full ownership evidence before a post-processing rewrite can
/// delete text. If the proxy truncates the dictated region, or any host/user edit
/// changes the observed context while processing runs, the raw text is retained.
enum KeyboardDocumentRewriteGuard {
    static func canReplace(
        dictatedText: String,
        contextAtPolishStart: String?,
        currentContext: String?
    ) -> Bool {
        guard !dictatedText.isEmpty,
              let contextAtPolishStart,
              let currentContext,
              contextAtPolishStart == currentContext else {
            return false
        }
        return contextAtPolishStart.hasSuffix(dictatedText)
    }
}
