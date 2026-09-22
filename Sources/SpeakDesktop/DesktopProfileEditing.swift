import Foundation
import SpeakCore

/// The projection a native desktop profile editor edits and the rules that
/// turn it back into a canonical `DictationProfile`.
///
/// The editor only ever chooses from the host's executable catalogues, so a
/// saved profile runs exactly as displayed. A stored value the host cannot show
/// or run — a macOS local model, an Apple-only polish engine, a language not in
/// the catalogue — is carried as `preserved`: the editor names it in its notes,
/// keeps it byte-for-byte on save, and replaces it only when the user picks
/// something else. Matchers of other platforms are never touched.
public enum DesktopProfileEditing {
    public struct Catalogue: Sendable {
        public var capabilities: DesktopProfileCapabilities
        public var languages: [TranscriptionLanguageOption]

        public init(
            capabilities: DesktopProfileCapabilities,
            languages: [TranscriptionLanguageOption] = TranscriptionLanguageCatalog.options
        ) {
            self.capabilities = capabilities
            self.languages = languages
        }

        public var batchModels: [ModelCatalog.Option] { capabilities.batchModels }
        public var liveModels: [ModelCatalog.Option] { capabilities.liveModels }
        public var polishModels: [ModelCatalog.Option] { capabilities.polishModels }
    }

    public enum TranscriptionChoice: Equatable, Sendable {
        case appSetting
        case batch(index: Int)
        case live(index: Int)
        /// Keep the stored override, which this host cannot display or run.
        case preserved
    }

    public enum PolishMode: Equatable, Sendable {
        case appSetting
        case disabled
        case enabled
    }

    public enum CatalogueChoice: Equatable, Sendable {
        case appSetting
        case index(Int)
        /// Keep the stored value, which is not in this host's catalogue.
        case preserved
    }

    public struct Draft: Equatable, Sendable {
        /// The stored profile's identifier; `nil` for a profile the editor created.
        public var id: UUID?
        public var name: String
        /// One full Windows executable path per entry; blank entries are ignored.
        public var executablePaths: [String]
        public var transcription: TranscriptionChoice
        public var polishMode: PolishMode
        public var polishModel: CatalogueChoice
        public var polishPrompt: String
        public var polishOutputLanguage: String
        public var language: CatalogueChoice
        /// Read-only notes about preserved values and platform limitations.
        public var notes: [String]

        public init(
            id: UUID? = nil,
            name: String = "",
            executablePaths: [String] = [],
            transcription: TranscriptionChoice = .appSetting,
            polishMode: PolishMode = .appSetting,
            polishModel: CatalogueChoice = .appSetting,
            polishPrompt: String = "",
            polishOutputLanguage: String = "",
            language: CatalogueChoice = .appSetting,
            notes: [String] = []
        ) {
            self.id = id
            self.name = name
            self.executablePaths = executablePaths
            self.transcription = transcription
            self.polishMode = polishMode
            self.polishModel = polishModel
            self.polishPrompt = polishPrompt
            self.polishOutputLanguage = polishOutputLanguage
            self.language = language
            self.notes = notes
        }
    }

    /// Why a list of drafts could not be stored. Nothing is persisted when
    /// any draft fails, so a cancelled or invalid edit leaves the prior values.
    public struct Rejection: Equatable, Sendable {
        public let name: String
        public let issues: [DictationProfileIssue]
    }

    public struct MergeFailure: Error, Equatable, Sendable {
        public let rejections: [Rejection]

        public var message: String {
            rejections.map { rejection in
                let name = rejection.name.isEmpty ? "Unnamed profile" : "Profile “\(rejection.name)”"
                return "\(name): " + rejection.issues.map(\.message).joined(separator: " ")
            }.joined(separator: " ")
        }
    }

    // MARK: - Profile to draft

    public static func draft(for profile: DictationProfile, catalogue: Catalogue) -> Draft {
        var draft = Draft(id: profile.id, name: profile.name, executablePaths: profile.windowsExecutablePaths)
        draft.transcription = transcriptionChoice(for: profile, catalogue: catalogue)
        switch profile.polishEnabled {
        case .some(true): draft.polishMode = .enabled
        case .some(false): draft.polishMode = .disabled
        case .none: draft.polishMode = .appSetting
        }
        if let model = trimmedNonEmpty(profile.polishModelID) {
            if let index = catalogue.polishModels.firstIndex(where: { $0.id == model }) {
                draft.polishModel = .index(index)
            } else {
                draft.polishModel = .preserved
            }
        }
        draft.polishPrompt = profile.polishPrompt ?? ""
        draft.polishOutputLanguage = profile.polishOutputLanguage ?? ""
        if let language = trimmedNonEmpty(profile.languageIdentifier) {
            if let index = catalogue.languages.firstIndex(where: { $0.id == language }) {
                draft.language = .index(index)
            } else {
                draft.language = .preserved
            }
        }
        draft.notes = notes(for: profile, catalogue: catalogue)
        return draft
    }

    private static func transcriptionChoice(
        for profile: DictationProfile, catalogue: Catalogue
    ) -> TranscriptionChoice {
        guard let override = profile.resolvedTranscriptionOverride else { return .appSetting }
        switch override.routing {
        case .remoteBatch:
            return catalogue.batchModels.firstIndex(where: { $0.id == override.modelID }).map {
                .batch(index: $0)
            } ?? .preserved
        case .remoteStreaming:
            return catalogue.liveModels.firstIndex(where: { $0.id == override.modelID }).map {
                .live(index: $0)
            } ?? .preserved
        case .localBatch: return .preserved
        }
    }

    /// Everything the editor keeps but cannot change, in the words the user
    /// sees. Limitations come from the same policy the recording applies.
    public static func notes(for profile: DictationProfile, catalogue: Catalogue) -> [String] {
        var notes = DesktopProfileSessionResolver.limitations(of: profile, capabilities: catalogue.capabilities)
            .map(\.message)
        if let language = trimmedNonEmpty(profile.languageIdentifier),
           !catalogue.languages.contains(where: { $0.id == language }) {
            notes.append("Spoken language “\(language)” is not in this build's language list and is kept as stored.")
        }
        let bundleIDs = profile.matchers.filter { $0.kind == .bundleID }.map(\.value)
        if !bundleIDs.isEmpty {
            notes.append("Also matches these macOS apps, which only the Mac editor changes: "
                + bundleIDs.joined(separator: ", ") + ".")
        }
        if profile.matchers.contains(where: { $0.kind == .urlPattern }) {
            notes.append("Has a browser URL matcher, which no platform evaluates yet; it is kept as stored.")
        }
        return notes
    }

    // MARK: - Draft to profile

    /// The profile exactly as the editor displayed it, merged over `original`
    /// so the identifier, macOS matchers and preserved values survive. Polish
    /// options remain stored when disabled or inherited; the session resolver
    /// alone decides whether they run.
    public static func profile(
        from draft: Draft, original: DictationProfile?, catalogue: Catalogue
    ) -> DictationProfile {
        var profile = original ?? DictationProfile(id: draft.id ?? UUID(), name: "")
        profile.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile = profile.replacingWindowsExecutablePaths(cleanedPaths(draft.executablePaths))

        applyTranscription(draft, to: &profile, original: original, catalogue: catalogue)

        let polishEnabled: Bool?
        switch draft.polishMode {
        case .appSetting: polishEnabled = nil
        case .disabled: polishEnabled = false
        case .enabled: polishEnabled = true
        }
        profile.polishEnabled = polishEnabled
        switch draft.polishModel {
        case .appSetting: profile.polishModelID = nil
        case .index(let index):
            profile.polishModelID = catalogue.polishModels.indices.contains(index)
                ? catalogue.polishModels[index].id : nil
        case .preserved: profile.polishModelID = original?.polishModelID
        }
        profile.polishPrompt = trimmedNonEmpty(draft.polishPrompt)
        profile.polishOutputLanguage = trimmedNonEmpty(draft.polishOutputLanguage)
        profile.polishIncludeLexiconDirectives = original?.polishIncludeLexiconDirectives
        profile.polishIncludeContextTags = original?.polishIncludeContextTags

        switch draft.language {
        case .appSetting: profile.languageIdentifier = nil
        case .index(let index):
            profile.languageIdentifier = catalogue.languages.indices.contains(index)
                ? catalogue.languages[index].id : nil
        case .preserved: profile.languageIdentifier = original?.languageIdentifier
        }
        return profile
    }

    private static func applyTranscription(
        _ draft: Draft, to profile: inout DictationProfile, original: DictationProfile?, catalogue: Catalogue
    ) {
        switch draft.transcription {
        case .appSetting:
            profile.transcriptionModelID = nil
            profile.transcriptionRouting = nil
        case .batch(let index):
            profile.transcriptionModelID = catalogue.batchModels.indices.contains(index)
                ? catalogue.batchModels[index].id : nil
            profile.transcriptionRouting = profile.transcriptionModelID == nil ? nil : .remoteBatch
        case .live(let index):
            profile.transcriptionModelID = catalogue.liveModels.indices.contains(index)
                ? catalogue.liveModels[index].id : nil
            profile.transcriptionRouting = profile.transcriptionModelID == nil ? nil : .remoteStreaming
        case .preserved:
            profile.transcriptionModelID = original?.transcriptionModelID
            profile.transcriptionRouting = original?.transcriptionRouting
        }

    }

    /// Save-time validation of what the editor controls. Preserved values are
    /// excluded: they were stored before this edit and are kept unchanged.
    public static func issues(for draft: Draft, catalogue: Catalogue) -> [DictationProfileIssue] {
        var editable = draft
        if editable.transcription == .preserved { editable.transcription = .appSetting }
        if editable.polishModel == .preserved { editable.polishModel = .appSetting }
        if editable.language == .preserved { editable.language = .appSetting }
        return selectionIssues(for: draft, catalogue: catalogue)
            + DictationProfileValidator.issues(for: profile(from: editable, original: nil, catalogue: catalogue))
    }

    private static func selectionIssues(for draft: Draft, catalogue: Catalogue) -> [DictationProfileIssue] {
        var issues: [DictationProfileIssue] = []
        switch draft.transcription {
        case .batch(let index) where !catalogue.batchModels.indices.contains(index),
             .live(let index) where !catalogue.liveModels.indices.contains(index):
            issues.append(.invalidSelection(field: "a transcription model"))
        default: break
        }
        if case .index(let index) = draft.polishModel, !catalogue.polishModels.indices.contains(index) {
            issues.append(.invalidSelection(field: "a polish model"))
        }
        if case .index(let index) = draft.language, !catalogue.languages.indices.contains(index) {
            issues.append(.invalidSelection(field: "a spoken language"))
        }
        return issues
    }

    /// The complete stored list after an editing session: drafts in their new
    /// order, each merged over the stored profile with its identifier, and
    /// profiles absent from `drafts` removed. Fails, storing nothing, when a
    /// draft introduces an issue the stored profile did not already have.
    public static func merge(
        _ drafts: [Draft], into stored: [DictationProfile], catalogue: Catalogue
    ) -> Result<[DictationProfile], MergeFailure> {
        var merged: [DictationProfile] = []
        var rejections: [Rejection] = []
        var seen = Set<UUID>()
        for draft in drafts {
            let original = draft.id.flatMap { id in stored.first { $0.id == id } }
            let profile = profile(from: draft, original: original, catalogue: catalogue)
            guard seen.insert(profile.id).inserted else {
                rejections.append(Rejection(name: profile.name, issues: [.duplicateProfile]))
                continue
            }
            let existing = original.map(DictationProfileValidator.issues(for:)) ?? []
            let introduced = selectionIssues(for: draft, catalogue: catalogue)
                + DictationProfileValidator.issues(for: profile).filter { !existing.contains($0) }
            if introduced.isEmpty {
                merged.append(profile)
            } else {
                rejections.append(Rejection(name: profile.name, issues: introduced))
            }
        }
        guard rejections.isEmpty else { return .failure(MergeFailure(rejections: rejections)) }
        return .success(merged)
    }

}

extension DesktopProfileEditing {
    /// Trimmed, non-blank paths with duplicates (by normalised form) removed.
    public static func cleanedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = DictationProfileMatcher.normalizedWindowsExecutablePath(path),
                  seen.insert(key).inserted else { continue }
            cleaned.append(path)
        }
        return cleaned
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        DesktopProfileSessionResolver.trimmedNonEmpty(value)
    }
}
