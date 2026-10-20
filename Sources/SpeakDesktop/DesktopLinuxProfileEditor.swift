import Foundation
import SpeakCore

/// The GTK editor's wire format and mutations, independent of GTK or its thread.
/// IDs, not transient catalogue positions, travel back from native controls.
public enum DesktopLinuxProfileEditor {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static let notice = "Choose a profile manually for this app session, or use automatic matching. "
        + "On X11, automatic matching uses the captured target process's exact /proc/PID/exe path when available. "
        + "Wayland does not expose another app's identity here: choose a profile manually. "
        + "Window titles, WM_CLASS and browser URLs are never treated as executable identities."

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\t", with: "%09")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    public static func fields(_ payload: String) throws -> [String] {
        guard payload.utf8.count <= 1_048_576 else { throw Failure("The profile edit is too large.") }
        return try payload.components(separatedBy: "\t").map {
            guard let value = $0.removingPercentEncoding, !value.utf8.contains(0) else {
                throw Failure("The profile edit is malformed.")
            }
            return value
        }
    }

    public static func presentation(
        profiles: [DictationProfile], catalogue: DesktopProfileEditing.Catalogue,
        token: UUID, active: UUID?, notice: String
    ) -> String {
        var rows = [["H", token.uuidString, active?.uuidString ?? "", notice, Self.notice,
                     DesktopPostProcessing.localRulesNotice]]
        rows += catalogue.batchModels.map { ["T", "batch:" + $0.id, "Batch: " + $0.displayName] }
        rows += catalogue.liveModels.map { ["T", "live:" + $0.id, "Live: " + $0.displayName] }
        rows += catalogue.capabilities.localModels.map { ["T", "local:" + $0.id, "Local: " + $0.displayName] }
        rows += catalogue.polishModels.map { ["P", $0.id, $0.displayName] }
        rows += catalogue.languages.map { ["L", $0.id, $0.displayName] }
        rows += profiles.map { row($0, catalogue: catalogue) }
        return rows.map { $0.map(escape).joined(separator: "\t") }.joined(separator: "\n")
    }

    private static func row(_ profile: DictationProfile, catalogue: DesktopProfileEditing.Catalogue) -> [String] {
        let draft = DesktopProfileEditing.draft(for: profile, catalogue: catalogue)
        var transcription = profile.unsupportedTranscriptionRouting == nil ? "" : "!"
        if let override = profile.resolvedTranscriptionOverride {
            if profile.unsupportedTranscriptionRouting == nil,
               catalogue.capabilities.canRun(transcriptionModel: override.modelID, routing: override.routing) {
                let prefix = override.routing == .remoteBatch ? "batch:"
                    : (override.routing == .remoteStreaming ? "live:" : "local:")
                transcription = prefix + override.modelID
            } else { transcription = "!" }
        }
        let polish = profile.polishModelID.map { id in
            catalogue.polishModels.contains { $0.id == id } ? id : "!"
        } ?? ""
        let language = profile.languageIdentifier.map { id in
            catalogue.languages.contains { $0.id == id } ? id : "!"
        } ?? ""
        var notes = draft.notes
        if !profile.linuxExecutablePaths.allSatisfy(DictationProfileMatcher.isFullLinuxExecutablePath) {
            notes.append("A stored Linux path cannot match an app. It is retained until you explicitly correct it.")
        }
        return [
            "R", profile.id.uuidString, profile.name, profile.linuxExecutablePaths.joined(separator: "\n"),
            transcription, tri(profile.polishEnabled), polish, draft.polishPrompt, draft.polishOutputLanguage,
            language, tri(profile.polishIncludeLexiconDirectives), tri(profile.polishIncludeContextTags),
            notes.joined(separator: "\n")
        ]
    }

    public static func edit(
        _ fields: [String], original: DictationProfile?, catalogue: DesktopProfileEditing.Catalogue
    ) throws -> DictationProfile {
        guard fields.count == 10 else { throw Failure("Reopen Profiles: the form could not be read.") }
        try validatePreservedChoices(fields, original: original)
        var draft = original.map { DesktopProfileEditing.draft(for: $0, catalogue: catalogue) } ?? .init()
        draft.name = fields[0]
        draft.transcription = .preserved
        draft.polishMode = try polishMode(fields[3])
        draft.polishModel = try choice(fields[4], identifiers: catalogue.polishModels.map(\.id))
        draft.polishPrompt = fields[5]
        draft.polishOutputLanguage = fields[6]
        draft.language = try choice(fields[7], identifiers: catalogue.languages.map(\.id))
        var profile = DesktopProfileEditing.profile(from: draft, original: original, catalogue: catalogue)
        let paths = fields[1].components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard paths == original?.linuxExecutablePaths
                || paths.allSatisfy(DictationProfileMatcher.isFullLinuxExecutablePath) else {
            throw Failure("Enter complete Linux executable paths, one per line; not app names or WM_CLASS.")
        }
        if paths != original?.linuxExecutablePaths {
            var seen = Set<String>()
            profile = profile.replacingLinuxExecutablePaths(paths.filter { seen.insert($0).inserted })
        }
        try transcription(fields[2], to: &profile, catalogue: catalogue)
        profile.polishIncludeLexiconDirectives = try boolean(fields[8])
        profile.polishIncludeContextTags = try boolean(fields[9])
        let previous = original.map(DictationProfileValidator.issues(for:)) ?? []
        let issues = DictationProfileValidator.issues(for: profile).filter { !previous.contains($0) }
        guard issues.isEmpty else { throw Failure(issues.map(\.message).joined(separator: " ")) }
        return profile
    }

    private static func validatePreservedChoices(_ fields: [String], original: DictationProfile?) throws {
        if fields[2] == "!", original?.resolvedTranscriptionOverride == nil,
           original?.unsupportedTranscriptionRouting == nil {
            throw Failure("There is no stored transcription override to preserve. Choose Use app setting or a model.")
        }
        if fields[4] == "!", original?.polishModelID == nil {
            throw Failure("There is no stored post-processing model to preserve.")
        }
        if fields[7] == "!", original?.languageIdentifier == nil {
            throw Failure("There is no stored spoken language to preserve.")
        }
    }

    private static func transcription(
        _ value: String, to profile: inout DictationProfile, catalogue: DesktopProfileEditing.Catalogue
    ) throws {
        if value == "!" { return }
        profile.unsupportedTranscriptionRouting = nil
        if value.isEmpty {
            profile.transcriptionModelID = nil
            profile.transcriptionRouting = nil
            return
        }
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { throw Failure("Choose a transcription model again.") }
        let routing: DictationProfileTranscriptionRouting
        switch parts[0] {
        case "batch": routing = .remoteBatch
        case "live": routing = .remoteStreaming
        case "local": routing = .localBatch
        default: throw Failure("Choose a transcription model again.")
        }
        let id = String(parts[1])
        guard catalogue.capabilities.canRun(transcriptionModel: id, routing: routing) else {
            throw Failure("This transcription model is no longer available; no other route was substituted.")
        }
        profile.transcriptionModelID = id
        profile.transcriptionRouting = routing
    }

    private static func choice(
        _ value: String, identifiers: [String]
    ) throws -> DesktopProfileEditing.CatalogueChoice {
        if value.isEmpty { return .appSetting }
        if value == "!" { return .preserved }
        guard let index = identifiers.firstIndex(of: value) else {
            throw Failure("Choose the model or language again.")
        }
        return .index(index)
    }

    private static func polishMode(_ value: String) throws -> DesktopProfileEditing.PolishMode {
        // Explicit .none/.some(_) patterns (rather than implicit nil/true/false literals)
        // so every Swift compiler recognizes this switch over Bool? as exhaustive; no
        // behavioral change versus the prior equivalent pattern matching.
        switch try boolean(value) {
        case .none: return .appSetting
        case .some(true): return .enabled
        case .some(false): return .disabled
        }
    }

    private static func boolean(_ value: String) throws -> Bool? {
        switch value {
        case "": return nil
        case "1": return true
        case "0": return false
        default: throw Failure("Choose Use app setting, On or Off again.")
        }
    }

    private static func tri(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "" }
}
