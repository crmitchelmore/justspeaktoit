import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopHostConfigurationEditorEvent: Sendable {
    case rendered(String)
    case action(Int32, [String], String?)

    package init(action: Int32, values: [String]) throws {
        if action == 6 {
            guard values.count == 1, UUID(uuidString: values[0]) != nil else {
                throw DesktopConfigurationError.invalidField("Preferences render acknowledgement")
            }
            self = .rendered(values[0])
            return
        }
        let isEdit = action == 0 || action == 3 || action == 4 || action == 5
        let id = isEdit ? values.last : nil
        if isEdit, id.flatMap(UUID.init(uuidString:)) == nil {
            throw DesktopConfigurationError.invalidField("Preferences view identity")
        }
        let entries = isEdit ? Array(values.dropLast()) : values
        if action == 0 || action == 4 || action == 5 {
            try DesktopConfiguration.validateEntries(entries)
        } else if action == 3 {
            guard entries.count == DesktopConfiguration.fields.count + 1 else {
                throw DesktopConfigurationError.invalidField("Recovered keyword selection")
            }
            try DesktopConfiguration.validateEntries(Array(entries.dropLast()))
        } else if !(action == 1 || action == 2) || entries.count != 1 {
            throw DesktopConfigurationError.invalidField("Configuration action")
        }
        self = .action(action, entries, id)
    }
}

package struct DesktopHostConfigurationEditorSnapshot: Sendable {
    package let preferences: DesktopConfiguration
    package let entries: [String]
    package let languageTitle: String
    package let qualityTitle: String
    package let qualityEnabled: Bool
    let basis: DesktopHostConfigurationEditorBasis
    package var id: String { basis.id.uuidString }
    var notice: String? { basis.notice }
}

struct DesktopHostConfigurationEditorBasis: Sendable {
    let id: UUID
    let model: String
    let preferences: DesktopConfiguration
    let pronunciationWords: [String]?
    let projectedKeyterms: String
    let notice: String?
}

enum DesktopHostConfigurationEditorState {
    case loading(UUID)
    case awaitingRender(DesktopHostConfigurationEditorBasis)
    case ready(DesktopHostConfigurationEditorBasis)
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func nativeConfigurationEditorSnapshot() async throws -> DesktopHostConfigurationEditorSnapshot {
        guard !closed else { throw CancellationError() }
        let id = UUID()
        configurationEditor = .loading(id)
        let model = settings.model
        let snapshot = try voiceConfigurationEditorSnapshot()
        let words: [String]?
        if DesktopHostModels.provider(for: model)?.id == "assemblyai" {
            words = try await recognitionVocabulary().pronunciationWords
        } else {
            words = nil
        }
        guard let state = configurationEditor, case .loading(let currentID) = state, currentID == id,
              !closed, settings.model == model, try configurationForNativeEditor() == snapshot.preferences else {
            throw DesktopHostError(message: "Preferences changed while opening the editor. Reopen preferences.")
        }
        var entries = snapshot.preferences.entries
        let index = try Self.assemblyAIEditorIndex()
        var notice: String?
        if let words {
            let projected = snapshot.preferences.liveOptions.includingPronunciationWords(words)
                .assemblyAIKeyterms.joined(separator: ", ")
            if projected.utf8.count <= 65_535, !projected.contains("\0") {
                entries[index] = projected
            } else {
                notice = "Effective pronunciation hints cannot fit safely in this editor."
                    + " Showing saved keywords only; automatic hints are retained."
            }
        }
        let basis = DesktopHostConfigurationEditorBasis(
            id: id, model: model, preferences: snapshot.preferences,
            pronunciationWords: words, projectedKeyterms: entries[index], notice: notice
        )
        configurationEditor = .awaitingRender(basis)
        return DesktopHostConfigurationEditorSnapshot(
            preferences: snapshot.preferences, entries: entries,
            languageTitle: snapshot.languageTitle, qualityTitle: snapshot.qualityTitle,
            qualityEnabled: snapshot.qualityEnabled, basis: basis
        )
    }
}

extension DesktopHostController {
    /// Activate only after the native field replacement succeeds, not merely after loading its data.
    package func activateConfigurationEditorSnapshot(_ snapshot: DesktopHostConfigurationEditorSnapshot) throws {
        try activateConfigurationEditorSnapshot(snapshot.id)
    }

    package func activateConfigurationEditorSnapshot(_ id: String) throws {
        guard let state = configurationEditor, case .awaitingRender(let basis) = state, basis.id.uuidString == id,
              !closed, settings.model == basis.model,
              try configurationForNativeEditor() == basis.preferences else {
            throw DesktopHostError(message: "Preferences changed before the editor was displayed. Reopen preferences.")
        }
        configurationEditor = .ready(basis)
        if let notice = basis.notice { update(notice) }
    }

    func activeConfigurationEditor() throws -> DesktopHostConfigurationEditorBasis? {
        guard let configurationEditor else { return nil }
        switch configurationEditor {
        case .loading, .awaitingRender:
            throw DesktopHostError(message: "The preferences editor is not ready. Reopen preferences before applying.")
        case .ready(let basis): return basis
        }
    }

    func requireConfigurationEditorID(_ id: String?, editor: DesktopHostConfigurationEditorBasis?) throws {
        guard let id else { return }
        guard editor?.id.uuidString == id else {
            throw DesktopHostError(message: "This preferences view was superseded. Reopen preferences before applying.")
        }
    }

    func canonicalConfigurationEntries(
        _ entries: [String], from previous: DesktopConfiguration, editor: DesktopHostConfigurationEditorBasis?
    ) throws -> [String] {
        guard let editor else { return entries }
        guard settings.model == editor.model, previous == editor.preferences else {
            throw DesktopHostError(message: "Preferences changed since this editor opened. Reopen preferences.")
        }
        guard entries.count == DesktopConfiguration.fields.count else {
            throw DesktopConfigurationError.invalidField("Native preferences")
        }
        let index = try Self.assemblyAIEditorIndex()
        guard editor.pronunciationWords != nil, entries[index] == editor.projectedKeyterms else { return entries }
        var canonical = entries
        canonical[index] = previous.entries[index]
        return canonical
    }

    private static func assemblyAIEditorIndex() throws -> Int {
        guard let index = DesktopConfiguration.fields.firstIndex(where: {
            $0.key == ApplicationPreferenceKey.assemblyAIKeyterms.rawValue
        }) else {
            throw DesktopConfigurationError.invalidField("AssemblyAI keyterms")
        }
        return index
    }
}
