import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Speaks Deepgram voice output through a host-owned player.
///
/// This is an engine for a host, not a user interface. Synthesized speech is a
/// 24 kHz mono PCM16 WAV written to a new file in a host-supplied app-owned
/// directory that only the current user can open (0700, files 0600). Each file
/// is created exclusively, so an existing file is never opened, truncated or
/// removed, and it is removed once its segment has played or failed. The
/// player reads the whole file before it starts, so nothing holds it open.
/// Speech left behind by an earlier run of the app, for example after a
/// crash, is removed when the engine is created. The host supplies the
/// request, credential, directory and player; the engine owns no settings or
/// credential lookup.
public final class LinuxVoiceOutput: Sendable {
    private let staging: LinuxVoiceOutputStaging
    private let session: URLSession

    /// - Parameters:
    ///   - stagingDirectory: A local file URL for a dedicated app-owned
    ///     directory. It is created, or its permissions tightened, before each
    ///     file.
    ///   - session: Carries the synthesis request.
    public init(stagingDirectory: URL, session: URLSession = .shared) throws {
        let staging = try LinuxVoiceOutputStaging(directory: stagingDirectory)
        staging.removeLeftovers()
        self.staging = staging
        self.session = session
    }

    /// Speaks one request through `play`, for example the app's shared
    /// playback, so speech and other audio never overlap; see
    /// `DeepgramVoiceOutput.speak`. `play` must stop when its task is
    /// cancelled. Cancelling the calling task stops the HTTP exchange or the
    /// playback.
    public func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String,
        through play: @escaping @Sendable (URL) async throws -> TimeInterval
    ) async throws -> DeepgramVoiceOutput.Outcome {
        let staging = staging
        let output = DeepgramVoiceOutput(session: session, playback: DeepgramVoiceOutput.Playback(
            store: { try staging.store($0) }, play: play, discard: { try staging.discard($0) }
        ))
        return try await output.speak(request, credential: credential)
    }

    /// Files this instance created that are still on disk.
    public var stagedFileCount: Int { staging.ownedCount }
}

/// Exclusive private files for synthesized speech in one app-owned directory.
/// Only files this staging created are ever removed, apart from earlier
/// runs' leftovers, which match only this staging's own file names.
final class LinuxVoiceOutputStaging: @unchecked Sendable {
    static let prefix = "voice-output-"

    let directory: URL
    private let lock = NSLock()
    private var owned: Set<URL> = []

    /// Refuses anything but a local file URL whose path survives the trip
    /// through a C string, so a truncated prefix can never be prepared.
    init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.isEmpty, !directory.path.utf8.contains(0) else {
            throw LinuxNativeError(message: "Voice output needs a local app-owned folder for its temporary audio.")
        }
        self.directory = directory
    }

    var ownedCount: Int { lock.withLock { owned.count } }

    func store(_ wav: Data) throws -> URL {
        try LinuxFiles.preparePrivateDirectory(directory)
        let file = directory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).wav", isDirectory: false)
        // Refuses an existing path or link, so nothing else is ever opened.
        try LinuxFiles.createPrivateFile(file)
        lock.withLock { _ = owned.insert(file) }
        do {
            let handle = try FileHandle(forWritingTo: file)
            do {
                try handle.write(contentsOf: wav)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? discard(file)
            throw error
        }
        return file
    }

    /// Removes a file this staging created; throws while it is still present.
    func discard(_ file: URL) throws {
        guard lock.withLock({ owned.contains(file) }) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw error }
        }
        lock.withLock { _ = owned.remove(file) }
    }

    /// Removes speech an earlier run left in this app-owned folder.
    func removeLeftovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(".wav") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }
}
