import Foundation
import SpeakCore

/// Which downloaded models a desktop host is using, downloading or removing,
/// and which its speech runtime may still hold in memory, by catalogue ID.
///
/// A model that a recording or transcription uses cannot be removed. A model's
/// files have one owner at a time, a download or a removal, so a removal never
/// deletes a download in progress and a download never writes into a folder
/// being deleted. Callers refuse to use a model while it is being removed.
///
/// The runtime keeps the last model it loaded and replaces it when it loads
/// another, and the host runs one recognition at a time. A removal therefore
/// frees that cache only when the removed model may be the one held, so
/// removing a different model keeps the loaded one ready.
public struct LocalModelOwnership: Sendable {
    /// What one recognition did with the runtime.
    public enum Recognition: Equatable, Sendable {
        /// The runtime was not asked to run the model, as for silence.
        case skipped
        /// The runtime was asked to run the model but did not finish, so it
        /// may or may not have replaced the model it held.
        case interrupted
        /// The runtime finished with the model, so it holds that model only.
        case completed
    }

    /// A removal the ledger admitted, returned to it by `endRemoval`.
    public struct Removal: Equatable, Sendable {
        public let model: String
        /// The runtime may hold the model, so the removal also frees its cache.
        public let freesRuntime: Bool
    }

    private enum FileOwner: Sendable { case download, removal }

    private var users: [String: Int] = [:]
    private var fileOwners: [String: FileOwner] = [:]
    private var resident: Set<String> = []

    public init() {}

    public func isInUse(_ model: String) -> Bool { users[model] != nil }

    public func isDownloading(_ model: String) -> Bool { fileOwners[model] == .download }

    public func isRemoving(_ model: String) -> Bool { fileOwners[model] == .removal }

    /// Whether the runtime may still hold `model` in memory.
    public func mayBeLoaded(_ model: String) -> Bool { resident.contains(model) }

    /// One more recording or transcription uses `model` until `endUse`.
    public mutating func beginUse(_ model: String) { users[model, default: 0] += 1 }

    public mutating func endUse(_ model: String) {
        guard let count = users[model] else { return }
        users[model] = count > 1 ? count - 1 : nil
    }

    /// Takes the model's files for a download unless a download or a removal
    /// already has them.
    public mutating func beginDownload(_ model: String) -> Bool {
        guard fileOwners[model] == nil else { return false }
        fileOwners[model] = .download
        return true
    }

    public mutating func endDownload(_ model: String) {
        if fileOwners[model] == .download { fileOwners[model] = nil }
    }

    /// Takes the model's files for a removal. Nil while the model is in use,
    /// being downloaded or already being removed.
    public mutating func beginRemoval(_ model: String) -> Removal? {
        guard !isInUse(model), fileOwners[model] == nil else { return nil }
        fileOwners[model] = .removal
        return Removal(model: model, freesRuntime: resident.contains(model))
    }

    /// Gives up the files once the removal finishes, whether or not they could
    /// be deleted: its teardown frees the runtime's cache either way.
    public mutating func endRemoval(_ removal: Removal) {
        if fileOwners[removal.model] == .removal { fileOwners[removal.model] = nil }
        if removal.freesRuntime { resident.remove(removal.model) }
    }

    /// Records what one recognition of `model` did with the runtime.
    public mutating func record(_ recognition: Recognition, of model: String) {
        switch recognition {
        case .skipped: break
        case .interrupted: resident.insert(model)
        case .completed: resident = [model]
        }
    }
}

/// Runs a recognizer and reports what it did with the runtime, for
/// `LocalModelOwnership.record(_:of:)`.
public final class LocalRecognitionProbe: DesktopLocalRecognizer, @unchecked Sendable {
    private let recognizer: any DesktopLocalRecognizer
    private let lock = NSLock()
    private var outcome = LocalModelOwnership.Recognition.skipped

    public init(_ recognizer: any DesktopLocalRecognizer) { self.recognizer = recognizer }

    public var recognition: LocalModelOwnership.Recognition { lock.withLock { outcome } }

    public func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        lock.withLock { outcome = .interrupted }
        let text = try await recognizer.transcribe(
            samples: samples, modelFile: modelFile, model: model, language: language
        )
        lock.withLock { outcome = .completed }
        return text
    }
}

/// Removes downloaded models off the caller's actor, one at a time.
///
/// Deleting a model can take a while, and freeing the speech runtime's cached
/// model waits for any recognition the runtime is running. A host actor doing
/// either itself could not serve cancellation, recording or settings until it
/// finished, so both run on this serial queue while the caller only awaits.
/// One queue keeps teardown to one thread however many models are removed.
public final class LocalModelTeardown: @unchecked Sendable {
    private let queue = DispatchQueue(label: "JustSpeakToIt.local-models.teardown", qos: .utility)

    public init() {}

    /// Deletes the files, then runs `release` whatever the outcome, since the
    /// model was meant to go. Returns why the files could not be deleted.
    public func remove(
        _ deleteFiles: @escaping @Sendable () throws -> Void, release: @escaping @Sendable () -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                var failure: String?
                do { try deleteFiles() } catch { failure = error.localizedDescription }
                release()
                continuation.resume(returning: failure)
            }
        }
    }
}
