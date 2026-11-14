#if os(iOS)
import Foundation
import SpeakCore

/// Runs downloaded `local/...` transcription models in process.
///
/// The app target implements this with WhisperKit and registers it at launch
/// (`IOSLocalTranscriptionEngines.register`), so SpeakiOSLib and the
/// extensions that link it never carry the WhisperKit runtime. Where no engine
/// is registered, such as the keyboard extension, a downloaded model reports
/// itself unavailable rather than falling back to an upload.
public protocol IOSLocalTranscriptionEngine: AnyObject, Sendable {
    /// Whether `model` is fully downloaded and prepared. Must be cheap: it is
    /// read synchronously when Settings and recording start check availability.
    func isInstalled(_ model: LocalTranscriptionModel) -> Bool

    /// Bytes the installed model takes on disk, or `nil` when not installed.
    func installedSizeBytes(_ model: LocalTranscriptionModel) -> Int64?

    /// Whether the runtime recommends `model` for this device's memory and
    /// neural engine. Advice only: an unrecommended model can still be used.
    func isRecommendedOnThisDevice(_ model: LocalTranscriptionModel) -> Bool

    /// Downloads and prepares `model`, reporting a 0...1 fraction.
    func install(_ model: LocalTranscriptionModel, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Deletes `model`'s files.
    func remove(_ model: LocalTranscriptionModel) throws

    /// Transcribes a completed recording. `language` is a locale identifier, or
    /// `nil` to detect the language.
    func transcribe(fileAt url: URL, model: LocalTranscriptionModel, language: String?) async throws -> String
}

/// The process's downloaded-model engine, if the host registered one.
public enum IOSLocalTranscriptionEngines {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var engine: IOSLocalTranscriptionEngine?
    }

    private static let storage = Storage()

    public static func register(_ engine: IOSLocalTranscriptionEngine?) {
        storage.lock.lock()
        storage.engine = engine
        storage.lock.unlock()
    }

    public static var current: IOSLocalTranscriptionEngine? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.engine
    }
}

/// Why a downloaded model could not be used. None of these fall back to a
/// cloud provider.
public enum IOSLocalTranscriptionError: LocalizedError, Equatable {
    case engineUnavailable
    case unknownModel(String)
    case notDownloaded(String)
    case invalidRepository(String)
    case missingModelName
    case insufficientSpace(neededMB: Int)
    case modelInUse(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Downloaded models can only run in the Just Speak to It app."
        case .unknownModel(let identifier):
            return "\"\(identifier)\" is not a downloaded model this app knows."
        case .notDownloaded(let name):
            return "\(name) is not downloaded. Download it in Settings › Transcription › Downloaded Models."
        case .invalidRepository(let repository):
            return "\"\(repository)\" is not a Hugging Face repository. Use the owner/repo form."
        case .missingModelName:
            return "Enter the model folder name from the repository."
        case .insufficientSpace(let neededMB):
            return "Not enough free space. This model needs about \(neededMB) MB."
        case .modelInUse(let name):
            return "\(name) is transcribing a recording. Try again when it finishes."
        }
    }
}

/// `Application Support/LocalModels` in this app's own container. Excluded
/// from backup: downloads can be fetched again.
public enum IOSLocalModelsDirectory {
    public static func root(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalModels", isDirectory: true)
    }

    /// Creates `url` if needed and marks it excluded from backup.
    public static func prepare(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(excluded)
    }
}
#endif
