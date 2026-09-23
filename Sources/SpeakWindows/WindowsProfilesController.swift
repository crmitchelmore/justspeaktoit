import Foundation
import SpeakCore
import SpeakDesktop

extension WindowsAppController {
    func profileRecord(id: UUID, filename: String, profile: DesktopProfileSession) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: filename, modelIdentifier: profile.modelIdentifier
        )
        record.profileName = profile.profileName
        record.languageIdentifier = profile.language
        record.profileNotes = profile.limitations.map(\.message)
        return record
    }

    func resolvedProfile(executablePath: String?) -> DesktopProfileSession {
        DesktopProfileSessionResolver.resolve(
            profile: ProfileResolver(profiles: profiles).profile(forWindowsExecutablePath: executablePath),
            defaultModel: settings.model, defaultPostProcessing: settings.postProcessing ?? .init(),
            capabilities: profileCapabilities
        )
    }

    func profileRecordingStatus(_ profile: DesktopProfileSession, trigger: HotKeySessionTrigger) -> String {
        var status = "Recording… " + hotKeySettings().finishHint(for: trigger)
        if let name = profile.profileName { status += " App profile: \(name)." }
        for limitation in profile.limitations { status += " " + limitation.message }
        return status
    }

    func profileContext(_ record: DesktopRecordingStore.Record) -> String {
        var details = record.profileName.map { " App profile: \($0)." } ?? ""
        for note in record.profileNotes ?? [] { details += " " + note }
        return details
    }

    static func loadProfiles(
        from store: DesktopDictationProfileStore
    ) throws -> (profiles: [DictationProfile], warning: String?) {
        do { return (try store.load(), nil) } catch {
            let backup = try store.preserveUnreadableFile()
            return ([], "Previous app profiles could not be read. "
                + "A backup is kept at \(backup?.path ?? store.fileURL.path); "
                + "app settings apply until new profiles are saved.")
        }
    }

    func profileSnapshot() throws -> WindowsProfilesCoordinator.Snapshot {
        guard !closed, !busy, recording == nil else {
            throw WindowsNativeError(message: "Finish dictation before editing app profiles.")
        }
        return WindowsProfilesCoordinator.Snapshot(
            profiles: profiles,
            catalogue: DesktopProfileEditing.Catalogue(capabilities: profileCapabilities),
            notice: profileWarning ?? "Overrides apply to one recording; your normal app settings stay unchanged."
        )
    }

    var profileCapabilities: DesktopProfileCapabilities {
        DesktopProfileCapabilities(
            batchModels: WindowsModels.visible.filter { !WindowsModels.isLive($0.id) && !WindowsModels.isLocal($0.id) },
            liveModels: WindowsModels.live, polishModels: DesktopPostProcessing.remoteModels,
            localModels: WindowsModels.local,
            liveLanguageModelIDs: DesktopLiveTranscription.languageHintModelIDs
        )
    }

    func saveProfiles(_ profiles: [DictationProfile]) async {
        guard !closed, !busy, recording == nil else {
            update("App profiles were not saved because dictation started. Reopen App profiles to try again.")
            return
        }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        let store = profileStore
        do {
            try await Task.detached { try store.save(profiles) }.value
            self.profiles = profiles
            profileWarning = nil
            update("App profiles saved. The first matching profile applies to your next recording.")
        } catch { update("App profiles could not be saved: \(error.localizedDescription)") }
    }
}
