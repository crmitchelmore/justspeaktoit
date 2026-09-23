import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Stands in for a platform's private store and native player and records the
/// order in which the voice output uses them. Files are numbered URLs; no file
/// system or audio device is touched.
final class VoiceOutputProbe: @unchecked Sendable {
    enum Play: Sendable {
        case render(TimeInterval)
        case fail
        /// Waits for task cancellation, then takes a moment to release, as a
        /// native player joins its threads.
        case untilCancelled
        case untilReleased
        /// Cancellation arrives at the completion boundary, after the audio
        /// was rendered: the player still returns a positive duration.
        case cancelThenRender(TimeInterval)
    }

    struct PlayerFailure: Error, Equatable {}
    struct StoreFailure: Error, Equatable {}
    struct StillHeld: Error, Equatable {}

    private let lock = NSLock()
    private let behaviour: Play
    private let failStore: Bool
    private let cancelDuringStore: Bool
    private let discardFails: Bool
    private var log: [String] = []
    private var stored: [Data] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(
        play: Play = .render(0.1), failStore: Bool = false, cancelDuringStore: Bool = false,
        discardFails: Bool = false
    ) {
        self.behaviour = play
        self.failStore = failStore
        self.cancelDuringStore = cancelDuringStore
        self.discardFails = discardFails
    }

    var events: [String] { lock.withLock { log } }
    var storedAudio: [Data] { lock.withLock { stored } }

    var playback: DeepgramVoiceOutput.Playback {
        DeepgramVoiceOutput.Playback(
            store: { try self.store($0) },
            play: { try await self.play($0) },
            discard: { try self.discard($0) }
        )
    }

    func releasePlayback() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }

    private func record(_ event: String) { lock.withLock { log.append(event) } }

    private func store(_ wav: Data) throws -> URL {
        if cancelDuringStore { withUnsafeCurrentTask { $0?.cancel() } }
        guard !failStore else {
            record("store failed")
            throw StoreFailure()
        }
        let number = lock.withLock { () -> Int in
            stored.append(wav)
            log.append("store \(stored.count)")
            return stored.count
        }
        return URL(fileURLWithPath: "/voice-output-probe/\(number)")
    }

    /// A platform that cannot remove the file yet keeps owning it and says so.
    private func discard(_ file: URL) throws {
        record("discard \(file.lastPathComponent)")
        if discardFails { throw StillHeld() }
    }

    private func play(_ file: URL) async throws -> TimeInterval {
        let name = file.lastPathComponent
        record("play \(name)")
        defer { record("released \(name)") }
        switch behaviour {
        case .render(let seconds):
            return seconds
        case .fail:
            throw PlayerFailure()
        case .untilCancelled:
            try? await Task.sleep(for: .seconds(30))
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
            }
            throw CancellationError()
        case .untilReleased:
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    guard !released else { return true }
                    waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
            return 0.1
        case .cancelThenRender(let seconds):
            withUnsafeCurrentTask { $0?.cancel() }
            return seconds
        }
    }
}

struct CredentialLookupFailure: Error, Equatable {}

/// Supplies a fixture key and counts how often the voice output asks for it.
final class CredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let value: String
    private let holdUntilReleased: Bool
    private var calls = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ value: String = "fixture-key", holdUntilReleased: Bool = false) {
        self.value = value
        self.holdUntilReleased = holdUntilReleased
    }

    var count: Int { lock.withLock { calls } }

    /// Ignores cancellation while held, like a slow platform credential store.
    func supply() async throws -> String {
        lock.withLock { calls += 1 }
        if holdUntilReleased {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    guard !released else { return true }
                    waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        return value
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
}

/// Runs the real voice output and synthesis transport against a local stub
/// and a recording stand-in for the platform store and player.
class DeepgramVoiceOutputTestCase: XCTestCase {
    var session: URLSession!
    let audio = DeepgramSpeechFixture.streamedWAV(pcm: DeepgramSpeechFixture.pcm(frames: 2_400))

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func respondWithAudio() {
        let audio = audio
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
    }

    func speak(
        _ probe: VoiceOutputProbe, credential: CredentialProbe = CredentialProbe()
    ) async throws -> DeepgramVoiceOutput.Outcome {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        return try await DeepgramVoiceOutput(session: session, playback: probe.playback)
            .speak(request) { try await credential.supply() }
    }

    func assertCancelled(
        _ task: Task<DeepgramVoiceOutput.Outcome, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let outcome = try await task.value
            XCTFail("Cancellation reported \(outcome)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    func eventually(
        _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}
