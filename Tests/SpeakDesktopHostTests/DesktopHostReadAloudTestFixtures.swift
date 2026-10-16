import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// Fakes shared by `DesktopHostReadAloudTests`, split out to keep that file
// under the pinned file-length limit. No network, audio device or native
// window: the scripted engine and player stand in for both.

/// What Read aloud asked of the fake player and engine.
final class FakeSpeech: @unchecked Sendable {
    static let shared = FakeSpeech()
    struct Spoken: Equatable {
        let text: String
        let voice: String
    }

    private let lock = NSLock()
    private var active: FakePlayback.Speech?
    private var log: [String] = []
    private var requests: [Spoken] = []
    private var gate = Gate(open: true)
    private var playbackHook: (@Sendable () async throws -> Void)?

    var events: [String] { lock.withLock { log } }
    var spoken: [Spoken] { lock.withLock { requests } }

    /// With `holdingSegments`, each segment plays until `releaseSegments`, so
    /// a test can act while one is audible.
    func reset(holdingSegments: Bool = false) {
        lock.withLock {
            active = nil
            log = []
            requests = []
            gate = Gate(open: !holdingSegments)
            playbackHook = nil
        }
    }

    func releaseSegments() { lock.withLock { gate }.release() }

    func setPlaybackHook(_ hook: @escaping @Sendable () async throws -> Void) {
        lock.withLock { playbackHook = hook }
    }

    func begin(_ speech: FakePlayback.Speech) -> FakePlayback.Speech {
        lock.withLock {
            active = speech
            log.append("begin")
        }
        return speech
    }

    func spoke(_ request: DeepgramSpeechRequest) {
        lock.withLock { requests.append(Spoken(text: request.text, voice: request.voice.id)) }
    }

    /// Refuses segments of an ended speech, and stops when its task is cancelled.
    func play(_ speech: FakePlayback.Speech) async throws -> TimeInterval {
        let (gate, hook) = try lock.withLock {
            guard active == speech else { throw CancellationError() }
            log.append("play")
            return (self.gate, playbackHook)
        }
        if let hook {
            try await hook()
        } else {
            await gate.pass()
        }
        try Task.checkCancellation()
        guard lock.withLock({ active == speech }) else { throw CancellationError() }
        return 1
    }

    func end(_ speech: FakePlayback.Speech) {
        lock.withLock {
            guard active == speech else { return }
            active = nil
            log.append("end")
        }
    }
}

extension FakePlayback: DesktopHostSpeechPlayback {
    struct Speech: Hashable, Sendable {
        let recordID: UUID
        let id = UUID()
    }

    func beginSpeech(recordID: UUID) throws -> Speech { FakeSpeech.shared.begin(Speech(recordID: recordID)) }
    func playToCompletion(_ speech: Speech, path: String) async throws -> TimeInterval {
        try await FakeSpeech.shared.play(speech)
    }
    func endSpeech(_ speech: Speech) { FakeSpeech.shared.end(speech) }
}

/// Behaves like the shared engine at its boundaries: an empty key stops it
/// before anything is spoken, and each request plays once through `play`.
struct FakeVoiceOutput: DesktopHostVoiceOutput {
    func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String,
        through play: @escaping @Sendable (URL) async throws -> TimeInterval
    ) async throws -> DeepgramVoiceOutput.Outcome {
        guard !(try await credential()).isEmpty else { throw DeepgramSpeechError.missingCredential }
        FakeSpeech.shared.spoke(request)
        _ = try await play(URL(fileURLWithPath: "/speech/segment.wav"))
        return .nothingToSpeak
    }
}

extension FakePlatform: DesktopHostReadAloudPlatform {
    typealias ReadAloudState = DesktopHostReadAloudState<FakePlayback.Speech, FakeVoiceOutput>
    static func makeVoiceOutput(stagingDirectory directory: URL) throws -> FakeVoiceOutput { FakeVoiceOutput() }
    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        _ = try await credential()
        try Task.checkCancellation()
        return try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: selection.sampleRate))
    }
    static let deepgramKeyHint = "save it in the test"
}
