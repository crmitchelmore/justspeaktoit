#if os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakWindowsPlatform

/// Records the exact bytes the player was given when it opened the file,
/// before any release, while the shared device-free engine plays them.
final class VoiceOutputRecordingBackend: WindowsAudioPlaybackBackend, @unchecked Sendable {
    struct Opened {
        let path: String
        let bytes: Data?
    }

    let engine = PlaybackTestBackend()
    private let lock = NSLock()
    private var values: [Opened] = []

    var opened: [Opened] { lock.withLock { values } }

    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: path))
        lock.withLock { values.append(Opened(path: path, bytes: bytes)) }
        return try engine.open(path: path, completion: completion)
    }
}

/// Holds a real native pin on the input (read-only, write and delete sharing
/// denied, no device touched) behind a device-free player. Its release can
/// fail while the pin stays, as a failed native destroy leaves the input, or
/// succeed while another holder keeps the file open.
final class PinnedInputBackend: WindowsAudioPlaybackBackend, @unchecked Sendable {
    final class Handle: WindowsAudioPlaybackHandle, @unchecked Sendable {
        let path: String
        private let pin: any WindowsAudioPlaybackHandle
        private let completion: @Sendable (WindowsAudioPlaybackCompletion) -> Void
        private let keepPinAfterRelease: Bool
        private let lock = NSLock()
        private var failuresRemaining: Int
        private var pinReleased = false

        init(
            path: String, pin: any WindowsAudioPlaybackHandle, failures: Int, keepPinAfterRelease: Bool,
            completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
        ) {
            self.path = path
            self.pin = pin
            self.failuresRemaining = failures
            self.keepPinAfterRelease = keepPinAfterRelease
            self.completion = completion
        }

        var isPinReleased: Bool { lock.withLock { pinReleased } }

        func start() throws { completion(WindowsAudioPlaybackCompletion(status: .finished, played: 0.1)) }
        func pause() {}
        func resume() {}
        func cancel() {}
        func snapshot() -> WindowsAudioPlaybackSnapshot {
            WindowsAudioPlaybackSnapshot(state: .ended, position: 0.1, duration: 0.1)
        }

        func destroy() throws {
            let fail = lock.withLock { () -> Bool in
                guard failuresRemaining > 0 else { return false }
                failuresRemaining -= 1
                return true
            }
            if fail { throw WindowsAudioPlaybackError("Injected release failure: the input is still pinned.") }
            if !keepPinAfterRelease { try releasePin() }
        }

        func releasePin() throws {
            try pin.destroy()
            lock.withLock { pinReleased = true }
        }
    }

    private let failures: Int
    private let keepPinAfterRelease: Bool
    private let lock = NSLock()
    private var values: [Handle] = []

    init(failures: Int, keepPinAfterRelease: Bool = false) {
        self.failures = failures
        self.keepPinAfterRelease = keepPinAfterRelease
    }

    var handles: [Handle] { lock.withLock { values } }

    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        let pin = try WindowsAudioPlaybackNativeBackend().open(path: path) { _ in }
        let handle = Handle(
            path: path, pin: pin, failures: failures, keepPinAfterRelease: keepPinAfterRelease, completion: completion
        )
        lock.withLock { values.append(handle) }
        return handle
    }
}

/// In-memory file operations whose removals can be refused or held, so the
/// staging's ownership budget is tested deterministically.
final class StagingFileSystemProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<String> = []
    private var prepared: [String] = []
    private var pinned = false
    private var created = 0
    private var heldRemoval: PlaybackTestGate?

    var creations: Int { lock.withLock { created } }
    var existing: Int { lock.withLock { files.count } }
    var preparedPaths: [String] { lock.withLock { prepared } }

    var fileSystem: WindowsVoiceOutputStaging.FileSystem {
        WindowsVoiceOutputStaging.FileSystem(
            prepareDirectory: { path in self.lock.withLock { self.prepared.append(path) } },
            createExclusive: { path in try self.create(path) },
            write: { _, _ in },
            remove: { self.remove($0) }
        )
    }

    func pin(_ value: Bool) { lock.withLock { pinned = value } }
    func holdNextRemoval(_ gate: PlaybackTestGate) { lock.withLock { heldRemoval = gate } }

    private func create(_ path: String) throws {
        let inserted = lock.withLock { () -> Bool in
            guard files.insert(path).inserted else { return false }
            created += 1
            return true
        }
        guard inserted else { throw WindowsVoiceOutputError("The synthetic file already exists.") }
    }

    private func remove(_ file: URL) -> Bool {
        let gate = lock.withLock { () -> PlaybackTestGate? in
            defer { heldRemoval = nil }
            return heldRemoval
        }
        if let gate { _ = gate.wait() }
        return lock.withLock {
            guard !pinned else { return false }
            files.remove(file.path)
            return true
        }
    }
}

/// Synthesis runs through the real shared transport against a local stub; no
/// vendor key or network is used. The fake engines prove ordering and file
/// ownership only; audible output is claimed solely by the endpoint test.
class WindowsVoiceOutputTestCase: XCTestCase {
    var session: URLSession!
    var parent: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = StubURLProtocol.makeSession()
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: parent)
        try super.tearDownWithError()
    }

    var directory: URL { parent.appendingPathComponent("VoiceOutput") }

    func request(_ text: String) throws -> DeepgramSpeechRequest {
        try DeepgramSpeechRequest(text: text, modelID: "aura-2", voiceID: "deepgram/aura-2-thalia-en")
    }

    func respond(with body: Data, contentType: String = "audio/wav") {
        StubURLProtocol.handler = { request in
            .respond(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType]
                )!,
                body
            )
        }
    }

    /// A quiet 200 Hz square wave, like the other playback tests.
    static func pcm(frames: Int) -> Data {
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = UInt16(bitPattern: (frame / 60).isMultiple(of: 2) ? 512 : -512)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return pcm
    }

    static func canonicalWAV(frames: Int) -> Data {
        PCMWaveWriter.wavData(pcm: pcm(frames: frames), sampleRate: 24_000)!
    }

    /// The header Deepgram streams before synthesis ends: RIFF `24 00 ff 7f`,
    /// data `00 00 ff 7f` (see DeepgramSpeechWAV's documented sentinels).
    static func streamedWAV(frames: Int) -> Data {
        var wav = canonicalWAV(frames: frames)
        wav.replaceSubrange(4..<8, with: [0x24, 0x00, 0xFF, 0x7F])
        wav.replaceSubrange(40..<44, with: [0x00, 0x00, 0xFF, 0x7F])
        return wav
    }
}
#endif
