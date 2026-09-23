import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

/// Holds the exact catalogue and original list shown by one native editor.
/// Callbacks validate synchronously without an actor hop; persistence follows
/// in the same settings queue as model/key changes before the next recording.
final class WindowsProfilesCoordinator: @unchecked Sendable {
    typealias Snapshot = DesktopHostProfilesSnapshot

    private let lock = NSLock()
    private var opening = false
    private var snapshot: Snapshot?
    private let save: ([DictationProfile]) -> Void

    init(save: @escaping ([DictationProfile]) -> Void) { self.save = save }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !opening else { return false }
        opening = true
        return true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        snapshot = nil
        opening = false
    }

    func show(_ snapshot: Snapshot) throws {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
        do {
            try WindowsNative.configureProfiles(snapshot, coordinator: self)
            jsti_window_request_profiles()
        } catch {
            cancel()
            throw error
        }
    }

    func apply(_ values: UnsafeBufferPointer<JSTIProfileDraft>) throws {
        lock.lock()
        let saved = snapshot
        lock.unlock()
        guard let saved else { throw WindowsNativeError(message: "Reopen app profiles before applying changes.") }
        let drafts = try values.map { try Self.draft($0, catalogue: saved.catalogue) }
        let result = DesktopProfileEditing.merge(drafts, into: saved.profiles, catalogue: saved.catalogue)
        switch result {
        case .failure(let failure): throw WindowsNativeError(message: failure.message)
        case .success(let profiles):
            save(profiles)
            cancel()
        }
    }

    private static func draft(
        _ value: JSTIProfileDraft, catalogue: DesktopProfileEditing.Catalogue
    ) throws -> DesktopProfileEditing.Draft {
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map(String.init(cString:)) ?? "" }
        let identifier = text(value.id)
        guard identifier.isEmpty || UUID(uuidString: identifier) != nil, (0...2).contains(value.polish_mode) else {
            throw WindowsNativeError(message: "The profile could not be read. Reopen the editor and try again.")
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
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func profilesEvent(
    _ action: Int32, _ drafts: UnsafePointer<JSTIProfileDraft>?, _ count: Int,
    _ context: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int32 {
    guard let context else { return -1 }
    let coordinator = Unmanaged<WindowsProfilesCoordinator>.fromOpaque(context).takeUnretainedValue()
    guard action == 1 else { coordinator.cancel(); return 0 }
    do {
        guard count <= 1000, count >= 0, count == 0 || drafts != nil else {
            throw WindowsNativeError(message: "The profile list could not be read.")
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
