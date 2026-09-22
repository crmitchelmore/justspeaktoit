import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CWindowsSupport
import SpeakCore

/// Speaks Deepgram voice output in process through the native Windows player.
///
/// This is an engine for a host, not a user interface. Synthesized speech is a
/// 24 kHz mono PCM16 WAV written to a new file in a host-supplied app-owned
/// directory that Windows protects for the current user and SYSTEM only. Each
/// file is created exclusively, so an existing file is never opened, truncated
/// or removed. The native player pins the file read-only while Media
/// Foundation decodes it to the endpoint's own format. The file is removed only
/// when Windows confirms it can be: a player call that returns or throws does
/// not prove release, for example after a failed native destroy. A file that
/// cannot be removed yet stays owned by this engine, counted against a small
/// budget and retried, and is never reported as removed. Only files this
/// instance created are ever removed. The host supplies the request,
/// credential and directory; the engine owns no settings or credential lookup.
public final class WindowsVoiceOutput: Sendable {
    private let staging: WindowsVoiceOutputStaging
    private let output: DeepgramVoiceOutput

    /// - Parameters:
    ///   - stagingDirectory: A local file URL for a dedicated app-owned
    ///     directory whose parent exists. It is created, or its permissions
    ///     repaired, before each file. Anything else is refused here, before any
    ///     file-system call.
    ///   - session: Carries the synthesis request.
    ///   - backend: The native player. Tests inject a device-free engine.
    public convenience init(
        stagingDirectory: URL,
        session: URLSession = .shared,
        backend: any WindowsAudioPlaybackBackend = WindowsAudioPlaybackNativeBackend()
    ) throws {
        try self.init(
            staging: WindowsVoiceOutputStaging(directory: stagingDirectory), session: session, backend: backend
        )
    }

    init(staging: WindowsVoiceOutputStaging, session: URLSession, backend: any WindowsAudioPlaybackBackend) {
        self.staging = staging
        output = DeepgramVoiceOutput(session: session, playback: DeepgramVoiceOutput.Playback(
            store: { try staging.store($0) },
            play: { try await WindowsAudioPlayback.play(input: $0, backend: backend).playedDuration },
            discard: { try staging.discard($0) }
        ))
    }

    /// Speaks one request; see `DeepgramVoiceOutput.speak`. Cancelling the task
    /// stops the HTTP exchange or the native playback. On success the receipt
    /// says whether the file was removed; after a thrown outcome a file Windows
    /// still holds is reported by `retainedFileCount`.
    public func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String
    ) async throws -> DeepgramVoiceOutput.Outcome {
        try await output.speak(request, credential: credential)
    }

    /// Files this instance created that Windows would not let it remove yet,
    /// for example while a failed native release still pins one. Every later
    /// file operation retries them.
    public var retainedFileCount: Int { staging.retainedCount }

    /// Retries removal of retained files and reports any that remain. Call when
    /// the host shuts down.
    public func removeRetainedFiles() throws { try staging.removeRetained() }
}

public struct WindowsVoiceOutputError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

/// Exclusive private files for synthesized speech in one app-owned directory.
///
/// Every file this staging created stays owned, and counted, until Windows
/// confirms it is gone: while in use, while its removal runs and after a
/// removal failed. Beyond `maximumOwnedFiles` new speech is refused, so
/// leftovers can never accumulate without bound. Removal runs outside the
/// lock, so a slow or held deletion never blocks another caller's bookkeeping.
final class WindowsVoiceOutputStaging: @unchecked Sendable {
    static let maximumOwnedFiles = 8

    /// File-system operations, injectable so ownership can be tested without
    /// Windows or a pinned file.
    struct FileSystem: Sendable {
        let prepareDirectory: @Sendable (String) throws -> Void
        let createExclusive: @Sendable (String) throws -> Void
        let write: @Sendable (Data, URL) throws -> Void
        /// True when the file no longer exists.
        let remove: @Sendable (URL) -> Bool

        static let native = FileSystem(
            prepareDirectory: { path in try checked { jsti_private_directory_prepare(path, $0, $1) } },
            createExclusive: { path in try checked { jsti_private_file_create(path, $0, $1) } },
            write: { wav, file in
                let handle = try FileHandle(forWritingTo: file)
                do {
                    try handle.write(contentsOf: wav)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            },
            remove: { file in
                do {
                    try FileManager.default.removeItem(at: file)
                    return true
                } catch {
                    return !FileManager.default.fileExists(atPath: file.path)
                }
            }
        )

        private static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
            var buffer = [CChar](repeating: 0, count: 1_024)
            let status = action(&buffer, buffer.count)
            guard status == 0 else { throw WindowsVoiceOutputError(String(cString: buffer)) }
        }
    }

    private enum Phase {
        case inUse
        case pendingRemoval
    }

    private let directory: URL
    private let directoryPath: String
    private let makeName: @Sendable () -> String
    private let fileSystem: FileSystem
    private let lock = NSLock()
    private var owned: [URL: Phase] = [:]

    /// Refuses anything but a local file URL whose path survives the trip
    /// through a C string, so a truncated prefix can never be prepared.
    init(
        directory: URL,
        makeName: @escaping @Sendable () -> String = { "voice-output-\(UUID().uuidString).wav" },
        fileSystem: FileSystem = .native
    ) throws {
        guard directory.isFileURL, let path = Self.cString(directory.path) else {
            throw WindowsVoiceOutputError("Voice output needs a local app-owned folder for its temporary audio.")
        }
        self.directory = directory
        self.directoryPath = path
        self.makeName = makeName
        self.fileSystem = fileSystem
    }

    /// A path or name as it will cross into C, or `nil` when it is empty or an
    /// embedded NUL would silently shorten it to a different location.
    /// Foundation currently percent-encodes a NUL inside a file URL; this keeps
    /// the guarantee independent of that.
    static func cString(_ value: String) -> String? {
        value.isEmpty || value.utf8.contains(0) ? nil : value
    }

    var retainedCount: Int { lock.withLock { owned.values.filter { $0 == .pendingRemoval }.count } }
    var ownedCount: Int { lock.withLock { owned.count } }

    func store(_ wav: Data) throws -> URL {
        retryPendingRemovals()
        // One plain component: no separator, drive or stream colon, or NUL.
        guard let name = Self.cString(makeName()), name != ".", name != "..",
              !name.unicodeScalars.contains(where: { "/\\:".unicodeScalars.contains($0) }) else {
            throw WindowsVoiceOutputError("Voice output generated an invalid temporary file name.")
        }
        let file = directory.appendingPathComponent(name, isDirectory: false)
        let reserved = lock.withLock { () -> Bool in
            guard owned.count < Self.maximumOwnedFiles, owned[file] == nil else { return false }
            owned[file] = .inUse
            return true
        }
        guard reserved else {
            throw WindowsVoiceOutputError("Earlier synthesized audio is still held by Windows. Try again shortly.")
        }
        do {
            try fileSystem.prepareDirectory(directoryPath)
            try fileSystem.createExclusive(file.path)
        } catch {
            // Nothing was created, so nothing is removed: the path may be another file.
            lock.withLock { owned[file] = nil }
            throw error
        }
        // Exclusive creation proved no other file was at this path: from here
        // the file belongs to this job, and only this job removes it.
        do {
            try fileSystem.write(wav, file)
        } catch {
            try? discard(file)
            throw error
        }
        return file
    }

    /// Removes a file this staging created. It stays owned and counted until
    /// Windows confirms it is gone; throws while it is still present.
    func discard(_ file: URL) throws {
        let ours = lock.withLock { () -> Bool in
            guard owned[file] != nil else { return false }
            owned[file] = .pendingRemoval
            return true
        }
        guard ours else { return }
        retryPendingRemovals()
        guard lock.withLock({ owned[file] == nil }) else {
            throw WindowsVoiceOutputError("Synthesized audio is still held by Windows; it will be removed later.")
        }
    }

    func removeRetained() throws {
        retryPendingRemovals()
        let count = retainedCount
        guard count == 0 else {
            throw WindowsVoiceOutputError("\(count) synthesized audio file(s) could not be removed yet.")
        }
    }

    /// Pending files stay owned while their removal runs outside the lock.
    private func retryPendingRemovals() {
        let pending = lock.withLock { owned.filter { $0.value == .pendingRemoval }.map(\.key) }
        for file in pending where fileSystem.remove(file) {
            lock.withLock {
                if owned[file] == .pendingRemoval { owned[file] = nil }
            }
        }
    }
}
