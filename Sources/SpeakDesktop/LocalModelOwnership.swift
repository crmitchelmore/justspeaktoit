import Foundation

/// Which downloaded models a desktop host is using, downloading or removing,
/// by catalogue ID.
///
/// A model that a recording or transcription uses cannot be removed. A model's
/// files have one owner at a time, a download or a removal, so a removal never
/// deletes a download in progress and a download never writes into a folder
/// being deleted. Callers refuse to use a model while it is being removed.
///
/// Which model the speech runtime holds in memory is not tracked here: another
/// recognition can replace it at any moment, so only the runtime can decide,
/// under its own lock, whether the model being removed is still the one held.
public struct LocalModelOwnership: Sendable {
    private enum FileOwner: Sendable { case download, removal }

    private var users: [String: Int] = [:]
    private var fileOwners: [String: FileOwner] = [:]

    public init() {}

    public func isInUse(_ model: String) -> Bool { users[model] != nil }

    public func isDownloading(_ model: String) -> Bool { fileOwners[model] == .download }

    public func isRemoving(_ model: String) -> Bool { fileOwners[model] == .removal }

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

    /// Takes the model's files for a removal unless the model is in use, being
    /// downloaded or already being removed.
    public mutating func beginRemoval(_ model: String) -> Bool {
        guard !isInUse(model), fileOwners[model] == nil else { return false }
        fileOwners[model] = .removal
        return true
    }

    /// Gives up the files once the removal finishes, whether or not they could
    /// be deleted.
    public mutating func endRemoval(_ model: String) {
        if fileOwners[model] == .removal { fileOwners[model] = nil }
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
    /// model was meant to go. `release` must free the runtime's cache only if
    /// it still holds this model: another may have replaced it while this job
    /// waited. Returns why the files could not be deleted.
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
