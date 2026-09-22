import Foundation
import SpeakDesktop
import CWindowsSupport

extension WindowsNative {
    static func configureProfiles(
        _ snapshot: WindowsProfilesCoordinator.Snapshot, coordinator: WindowsProfilesCoordinator
    ) throws {
        let strings = WindowsProfileStrings()
        let catalogue = snapshot.catalogue
        let transcription = (catalogue.batchModels.map { "Batch: " + $0.displayName }
            + catalogue.liveModels.map { "Live: " + $0.displayName }).map(strings.add)
        let polish = catalogue.polishModels.map { strings.add($0.displayName) }
        let languages = catalogue.languages.map { strings.add($0.displayName) }
        let drafts = snapshot.profiles.map { profile in
            let draft = DesktopProfileEditing.draft(for: profile, catalogue: catalogue)
            let transcription: Int32
            switch draft.transcription {
            case .appSetting: transcription = -1
            case .preserved: transcription = -2
            case .batch(let index): transcription = Int32(index)
            case .live(let index): transcription = Int32(catalogue.batchModels.count + index)
            }
            func index(_ choice: DesktopProfileEditing.CatalogueChoice) -> Int32 {
                switch choice {
                case .appSetting: return -1
                case .preserved: return -2
                case .index(let value): return Int32(value)
                }
            }
            return JSTIProfileDraft(
                id: strings.add(profile.id.uuidString), name: strings.add(draft.name),
                paths: strings.add(draft.executablePaths.joined(separator: "\r\n")),
                prompt: strings.add(draft.polishPrompt), output_language: strings.add(draft.polishOutputLanguage),
                notes: strings.add(draft.notes.joined(separator: "\n")), transcription: transcription,
                polish_mode: draft.polishMode == .appSetting ? 0 : (draft.polishMode == .disabled ? 1 : 2),
                polish_model: index(draft.polishModel), language: index(draft.language)
            )
        }
        let status = drafts.withUnsafeBufferPointer { drafts in
            transcription.withUnsafeBufferPointer { transcription in
                polish.withUnsafeBufferPointer { polish in
                    languages.withUnsafeBufferPointer { languages in
                        jsti_window_set_profiles(
                            drafts.baseAddress, drafts.count, transcription.baseAddress, transcription.count,
                            polish.baseAddress, polish.count, languages.baseAddress, languages.count,
                            strings.add(snapshot.notice), profilesEvent,
                            Unmanaged.passUnretained(coordinator).toOpaque()
                        )
                    }
                }
            }
        }
        withExtendedLifetime(strings) {}
        guard status == 0 else { throw WindowsNativeError(message: "App profiles could not be displayed.") }
    }
}

private final class WindowsProfileStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar>? {
        let bytes = Array(value.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { $0.deallocate() } }
}
