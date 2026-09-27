import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Holds the exact catalogue and stored list one editor opened with. Save is
/// validated synchronously on the GTK thread against that snapshot; the
/// accepted list is saved in the settings queue, before the next recording.
final class LinuxProfilesCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var opening = false
    private var snapshot: DesktopHostProfilesSnapshot?
    private let save: ([DictationProfile]) -> Void

    init(save: @escaping ([DictationProfile]) -> Void) { self.save = save }

    /// Claims the editor; false while one is already open or opening.
    func begin() -> Bool {
        lock.withLock {
            guard !opening else { return false }
            opening = true
            return true
        }
    }

    func cancel() {
        lock.withLock {
            snapshot = nil
            opening = false
        }
    }

    func show(_ snapshot: DesktopHostProfilesSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
        do {
            try Self.present(snapshot, coordinator: self)
        } catch {
            cancel()
            throw error
        }
    }

    func apply(_ values: UnsafeBufferPointer<JSTIProfileDraft>) throws {
        guard let saved = lock.withLock({ snapshot }) else {
            throw DesktopHostError(message: "Reopen App profiles before saving changes.")
        }
        let drafts = try values.map { try Self.draft($0, catalogue: saved.catalogue) }
        switch DesktopProfileEditing.merge(drafts, into: saved.profiles, catalogue: saved.catalogue) {
        case .failure(let failure): throw DesktopHostError(message: failure.message)
        case .success(let profiles):
            save(profiles)
            cancel()
        }
    }

    static func draft(
        _ value: JSTIProfileDraft, catalogue: DesktopProfileEditing.Catalogue
    ) throws -> DesktopProfileEditing.Draft {
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map(String.init(cString:)) ?? "" }
        let identifier = text(value.id)
        guard identifier.isEmpty || UUID(uuidString: identifier) != nil, (0...2).contains(value.polish_mode) else {
            throw DesktopHostError(message: "The profile could not be read. Reopen the editor and try again.")
        }
        let transcription: DesktopProfileEditing.TranscriptionChoice
        switch value.transcription {
        case -1: transcription = .appSetting
        case -2: transcription = .preserved
        default:
            let index = Int(value.transcription)
            transcription = index < catalogue.batchModels.count
                ? .batch(index: index) : .live(index: index - catalogue.batchModels.count)
        }
        func choice(_ index: Int32) -> DesktopProfileEditing.CatalogueChoice {
            switch index {
            case -1: return .appSetting
            case -2: return .preserved
            default: return .index(Int(index))
            }
        }
        return DesktopProfileEditing.Draft(
            id: UUID(uuidString: identifier), name: text(value.name),
            executablePaths: text(value.paths).components(separatedBy: .newlines), transcription: transcription,
            polishMode: value.polish_mode == 0 ? .appSetting : (value.polish_mode == 1 ? .disabled : .enabled),
            polishModel: choice(value.polish_model), polishPrompt: text(value.prompt),
            polishOutputLanguage: text(value.output_language), language: choice(value.language)
        )
    }

    private static func present(_ snapshot: DesktopHostProfilesSnapshot, coordinator: LinuxProfilesCoordinator) throws {
        let strings = LinuxWindow.Strings()
        let catalogue = snapshot.catalogue
        let transcription: [UnsafePointer<CChar>?] = (catalogue.batchModels.map { "Batch: " + $0.displayName }
            + catalogue.liveModels.map { "Live: " + $0.displayName }).map { strings.add(DesktopHostModels.uiText($0)) }
        let polish: [UnsafePointer<CChar>?] = catalogue.polishModels.map {
            strings.add(DesktopHostModels.uiText($0.displayName))
        }
        let languages: [UnsafePointer<CChar>?] = catalogue.languages.map { strings.add($0.displayName) }
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
                paths: strings.add(draft.executablePaths.joined(separator: "\n")),
                prompt: strings.add(draft.polishPrompt), output_language: strings.add(draft.polishOutputLanguage),
                notes: strings.add(draft.notes.joined(separator: "\n")), transcription: transcription,
                polish_mode: draft.polishMode == .appSetting ? 0 : (draft.polishMode == .disabled ? 1 : 2),
                polish_model: index(draft.polishModel), language: index(draft.language)
            )
        }
        let status = withExtendedLifetime(strings) {
            drafts.withUnsafeBufferPointer { drafts in
                transcription.withUnsafeBufferPointer { transcription in
                    polish.withUnsafeBufferPointer { polish in
                        languages.withUnsafeBufferPointer { languages in
                            jsti_window_set_profiles(
                                drafts.baseAddress, drafts.count, transcription.baseAddress, transcription.count,
                                polish.baseAddress, polish.count, languages.baseAddress, languages.count,
                                snapshot.notice, linuxProfilesEvent, Unmanaged.passUnretained(coordinator).toOpaque()
                            )
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw DesktopHostError(message: "App profiles could not be displayed.") }
    }

    /// The App profiles group's note: profiles match only where the desktop
    /// reveals the focused application.
    static func note(for session: LinuxDesktopSession) -> String {
        let purpose = "Use a different model, language or post-processing when you dictate into a particular app."
        switch session.displayServer {
        case .x11:
            return purpose + " Profiles match the window focused when you start dictation."
        case .wayland:
            return purpose + " This is a Wayland session: the desktop does not tell apps which window is focused, "
                + "so profiles cannot match here and your normal settings always apply. They work in an X11 session."
        case .unknown:
            return purpose + " Profiles match only in an X11 session."
        }
    }
}

// The editor's Save (action 1) or Cancel (action 0), on the GTK thread. The
// native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func linuxProfilesEvent(
    _ action: Int32, _ drafts: UnsafePointer<JSTIProfileDraft>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let context else { return -1 }
    let coordinator = Unmanaged<LinuxProfilesCoordinator>.fromOpaque(context).takeUnretainedValue()
    guard action == 1 else { coordinator.cancel(); return 0 }
    do {
        guard count >= 0, count <= 1000, count == 0 || drafts != nil else {
            throw DesktopHostError(message: "The profile list could not be read.")
        }
        try coordinator.apply(UnsafeBufferPointer(start: drafts, count: count))
        return 0
    } catch {
        if let output = errorBuffer, capacity > 0 {
            let bytes = Array(error.localizedDescription.utf8)
            let copied = min(bytes.count, capacity - 1)
            for index in 0..<copied { output[index] = CChar(bitPattern: bytes[index]) }
            output[copied] = 0
        }
        return -1
    }
}
