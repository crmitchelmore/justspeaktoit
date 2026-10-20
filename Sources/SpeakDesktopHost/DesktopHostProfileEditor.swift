import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopHostProfileEditorState: Sendable {
    var token = UUID()
    var profiles: [DictationProfile]
    let catalogue: DesktopProfileEditing.Catalogue
    var document: Data
}

extension DesktopHostController {
    /// The native event captures this value in settings order. Later editor
    /// actions cannot change the profile carried by an admitted recording.
    package func captureProfile(modelIndex: Int?, executablePath: String?) -> DesktopProfileSession {
        let models = DesktopHostModels.all
        let model = modelIndex.flatMap { models.indices.contains($0) ? models[$0].id : nil }
            ?? settings.model
        return resolveSelectedProfile(defaultModel: model, executablePath: executablePath)
    }

    func resolveSelectedProfile(defaultModel: String, executablePath: String?) -> DesktopProfileSession {
        let profile: DictationProfile?
        if let manualProfileID { profile = profiles.first { $0.id == manualProfileID } } else {
            profile = Platform.matchProfile(profiles, executablePath: executablePath)
        }
        return DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: defaultModel, defaultPostProcessing: settings.postProcessing ?? .init(),
            capabilities: profileCapabilities, defaultLanguage: settings.configuration?.language
        ).capturingTranscriptionOptions(settings.configuration?.liveOptions ?? .desktopDefaults)
            .capturingModulateFeatures(settings.configuration?.modulateBatchFeatures ?? .init())
            .capturingLivePolish(livePolishSelection())
    }

    package func profileEditorEvent(_ payload: String) async throws -> String {
        let fields = try DesktopLinuxProfileEditor.fields(payload)
        if fields == ["refresh"] {
            guard !handsFreeMachine.isArmed else {
                throw DesktopHostError(message: "Disarm sound activation before editing profiles.")
            }
            let snapshot = try profileSnapshot()
            let loaded = try profileStore.loadForEditing()
            profiles = loaded.profiles
            profileEditorState = DesktopHostProfileEditorState(
                profiles: profiles, catalogue: snapshot.catalogue, document: loaded.document
            )
            return try profileEditorPresentation(snapshot.notice)
        }
        guard !closed, !busy, recording == nil, !handsFreeMachine.isArmed,
              var editor = profileEditorState, fields.count >= 3,
              fields[0] == editor.token.uuidString, editor.profiles == profiles else {
            throw DesktopHostError(message: "Profiles changed or dictation started. Reopen Profiles before editing.")
        }
        let action = fields[1]
        let identifier = UUID(uuidString: fields[2])
        if action == "activate" {
            guard fields.count == 3 else { throw DesktopHostError(message: "The profile selection is malformed.") }
            guard fields[2].isEmpty || profiles.contains(where: { $0.id == identifier }) else {
                throw DesktopHostError(message: "Choose an existing profile before activating it.")
            }
            manualProfileID = identifier
            editor.token = UUID()
            profileEditorState = editor
            return try profileEditorPresentation("Profile selection applies to the next recording in this app session.")
        }
        let mutation = try profileEditorMutation(fields, editor: editor)
        return try await persistProfileEditorMutation(mutation, editor: editor)
    }

    private func persistProfileEditorMutation(
        _ mutation: (profiles: [DictationProfile], copies: [UUID: UUID]),
        editor original: DesktopHostProfileEditorState
    ) async throws -> String {
        var editor = original
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        let store = profileStore
        let document = editor.document
        try await Task.detached {
            try store.savePreservingUnknownFields(
                mutation.profiles, copiedFrom: mutation.copies, expectedDocument: document
            )
        }.value
        guard !closed else { throw DesktopHostError(message: "Profiles saved; the application is closing.") }
        profiles = mutation.profiles
        profileWarning = nil
        editor.profiles = profiles
        editor.document = try profileStore.rawDocument()
        editor.token = UUID()
        profileEditorState = editor
        return try profileEditorPresentation("Profiles saved. Changes apply to the next recording.")
    }

    private func profileEditorPresentation(_ notice: String) throws -> String {
        guard let editor = profileEditorState else { throw DesktopHostError(message: "Reopen Profiles.") }
        return DesktopLinuxProfileEditor.presentation(
            profiles: editor.profiles, catalogue: editor.catalogue, token: editor.token,
            active: manualProfileID, notice: notice
        )
    }

    private func profileEditorMutation(
        _ fields: [String], editor: DesktopHostProfileEditorState
    ) throws -> (profiles: [DictationProfile], copies: [UUID: UUID]) {
        var changed = editor.profiles
        let index = UUID(uuidString: fields[2]).flatMap { id in changed.firstIndex { $0.id == id } }
        guard fields[1] == "save" || fields.count == 3 else {
            throw DesktopHostError(message: "The profile action is malformed.")
        }
        if fields[1] == "save" {
            guard fields[2].isEmpty || index != nil, changed.count < 1000 || index != nil else {
                throw DesktopHostError(message: "Choose a stored profile or remove a profile before adding one.")
            }
            let profile = try DesktopLinuxProfileEditor.edit(
                Array(fields.dropFirst(3)), original: index.map { changed[$0] }, catalogue: editor.catalogue
            )
            if let index { changed[index] = profile } else { changed.append(profile) }
            return (changed, [:])
        }
        guard let index else { throw DesktopHostError(message: "Choose a saved profile before changing the list.") }
        return try changeStoredProfile(fields[1], at: index, profiles: changed)
    }

    private func changeStoredProfile(
        _ action: String, at index: Int, profiles: [DictationProfile]
    ) throws -> (profiles: [DictationProfile], copies: [UUID: UUID]) {
        var changed = profiles
        var copies: [UUID: UUID] = [:]
        switch action {
        case "duplicate":
            guard changed.count < 1000 else { throw DesktopHostError(message: "Remove a profile before duplicating.") }
            var copy = changed[index]
            copy.id = UUID()
            copy.name += " Copy"
            copies[copy.id] = changed[index].id
            changed.insert(copy, at: index + 1)
        case "delete":
            changed.remove(at: index)
        case "up", "down":
            let destination = index + (action == "up" ? -1 : 1)
            guard changed.indices.contains(destination) else {
                throw DesktopHostError(message: "Already at this end of the list.")
            }
            changed.swapAt(index, destination)
        default: throw DesktopHostError(message: "The profile action is not supported.")
        }
        return (changed, copies)
    }
}
