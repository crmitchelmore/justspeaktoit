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
/// Foundation decodes it to the endpoint's own format, and the file is removed
/// only after playback has been destroyed and its threads joined. Only files
/// this instance created are ever removed. The host supplies the request,
/// credential and directory; the engine owns no settings or credential lookup.
public final class WindowsVoiceOutput: Sendable {
    private let staging: WindowsVoiceOutputStaging
    private let output: DeepgramVoiceOutput

    /// - Parameters:
    ///   - stagingDirectory: A dedicated app-owned directory whose parent
    ///     exists. It is created, or its permissions repaired, before each file.
    ///   - session: Carries the synthesis request.
    ///   - backend: The native player. Tests inject a device-free engine.
    public convenience init(
        stagingDirectory: URL,
        session: URLSession = .shared,
        backend: any WindowsAudioPlaybackBackend = WindowsAudioPlaybackNativeBackend()
    ) {
        self.init(staging: WindowsVoiceOutputStaging(directory: stagingDirectory), session: session, backend: backend)
    }

    init(staging: WindowsVoiceOutputStaging, session: URLSession, backend: any WindowsAudioPlaybackBackend) {
        self.staging = staging
        output = DeepgramVoiceOutput(session: session, playback: DeepgramVoiceOutput.Playback(
            store: { try staging.store($0) },
            play: { try await WindowsAudioPlayback.play(input: $0, backend: backend).playedDuration },
            discard: { staging.discard($0) }
        ))
    }

    /// Speaks one request; see `DeepgramVoiceOutput.speak`. Cancelling the task
    /// stops the HTTP exchange or the native playback. The call returns after
    /// the native player has released the file and removal was attempted.
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
final class WindowsVoiceOutputStaging: @unchecked Sendable {
    /// Beyond this many unremovable files new speech is refused, so leftovers
    /// can never accumulate without bound.
    static let maximumRetainedFiles = 8

    private let directory: URL
    private let makeName: @Sendable () -> String
    private let lock = NSLock()
    private var retained: [URL] = []

    init(
        directory: URL,
        makeName: @escaping @Sendable () -> String = { "voice-output-\(UUID().uuidString).wav" }
    ) {
        self.directory = directory
        self.makeName = makeName
    }

    var retainedCount: Int { lock.withLock { retained.count } }

    func store(_ wav: Data) throws -> URL {
        retryRetained()
        guard retainedCount < Self.maximumRetainedFiles else {
            throw WindowsVoiceOutputError("Earlier synthesized audio is still held by Windows. Try again shortly.")
        }
        try directory.path.withCString { path in
            try Self.checked { jsti_private_directory_prepare(path, $0, $1) }
        }
        let file = directory.appendingPathComponent(makeName(), isDirectory: false)
        try file.path.withCString { path in
            try Self.checked { jsti_private_file_create(path, $0, $1) }
        }
        // Exclusive creation proved no other file was at this path: from here
        // the file belongs to this job, and only a failure here removes it.
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
            discard(file)
            throw error
        }
        return file
    }

    func discard(_ file: URL) {
        retryRetained()
        guard !Self.remove(file) else { return }
        lock.withLock { retained.append(file) }
    }

    func removeRetained() throws {
        retryRetained()
        let count = retainedCount
        guard count == 0 else {
            throw WindowsVoiceOutputError("\(count) synthesized audio file(s) could not be removed yet.")
        }
    }

    private func retryRetained() {
        let pending = lock.withLock { () -> [URL] in
            defer { retained.removeAll() }
            return retained
        }
        guard !pending.isEmpty else { return }
        let remaining = pending.filter { !Self.remove($0) }
        lock.withLock { retained.append(contentsOf: remaining) }
    }

    /// True when the file no longer exists.
    private static func remove(_ file: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: file)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: file.path)
        }
    }

    private static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let status = action(&buffer, buffer.count)
        guard status == 0 else { throw WindowsVoiceOutputError(String(cString: buffer)) }
    }
}
