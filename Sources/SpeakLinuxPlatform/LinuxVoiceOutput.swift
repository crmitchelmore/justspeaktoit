import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Speaks Deepgram voice output through a host-owned player, using the shared
/// `DeepgramVoiceOutput` engine the Windows and Apple apps use.
///
/// Synthesized speech is a mono PCM16 WAV written to a new 0600 file in a
/// private (0700) app-owned folder. Each file is created exclusively, so an
/// existing file is never opened, truncated or replaced, and only files this
/// instance created are ever removed. The host supplies the request,
/// credential and player; the engine owns no settings or credential lookup.
public final class LinuxVoiceOutput: Sendable {
    private let staging: LinuxVoiceOutputStaging
    private let session: URLSession

    /// - Parameter stagingDirectory: A dedicated folder whose parent exists.
    ///   It is created, or its permissions tightened, before each file.
    public init(stagingDirectory: URL, session: URLSession = .shared) throws {
        staging = try LinuxVoiceOutputStaging(directory: stagingDirectory)
        self.session = session
    }

    /// Speaks one request through `play`, which must stop when its task is
    /// cancelled and return the seconds it rendered once the file is released.
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

    /// Files this instance created and has not removed yet.
    public var ownedFileCount: Int { staging.ownedCount }
}

/// Exclusive private files for synthesized speech in one app-owned folder.
final class LinuxVoiceOutputStaging: @unchecked Sendable {
    /// Refuses new speech rather than letting leftovers accumulate.
    static let maximumOwnedFiles = 4

    let directory: URL
    private let lock = NSLock()
    private var owned: Set<String> = []

    init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.isEmpty else {
            throw LinuxNativeError(message: "Read aloud needs a local folder for its audio.")
        }
        self.directory = directory.standardizedFileURL
    }

    var ownedCount: Int { lock.withLock { owned.count } }

    func store(_ data: Data) throws -> URL {
        try LinuxFiles.preparePrivateDirectory(directory)
        let url = directory.appendingPathComponent("speech-\(UUID().uuidString).wav")
        try lock.withLock {
            guard owned.count < Self.maximumOwnedFiles else {
                throw LinuxNativeError(message: "Earlier Read aloud audio is still being removed. Try again shortly.")
            }
            owned.insert(url.path)
        }
        do {
            try LinuxFiles.createPrivateFile(url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return url
        } catch {
            try? discard(url)
            throw error
        }
    }

    /// Removes a file `store` created. Other paths are refused untouched.
    func discard(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard lock.withLock({ owned.contains(path) }) else {
            throw LinuxNativeError(message: "Read aloud refused to remove a file it did not create.")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // Already gone.
        }
        _ = lock.withLock { owned.remove(path) }
    }
}
