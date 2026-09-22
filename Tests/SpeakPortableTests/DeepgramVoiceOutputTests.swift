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
    }

    struct PlayerFailure: Error, Equatable {}
    struct StoreFailure: Error, Equatable {}

    private let lock = NSLock()
    private let behaviour: Play
    private let failStore: Bool
    private let cancelDuringStore: Bool
    private var log: [String] = []
    private var stored: [Data] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(play: Play = .render(0.1), failStore: Bool = false, cancelDuringStore: Bool = false) {
        self.behaviour = play
        self.failStore = failStore
        self.cancelDuringStore = cancelDuringStore
    }

    var events: [String] { lock.withLock { log } }
    var storedAudio: [Data] { lock.withLock { stored } }

    var playback: DeepgramVoiceOutput.Playback {
        DeepgramVoiceOutput.Playback(
            store: { try self.store($0) },
            play: { try await self.play($0) },
            discard: { self.record("discard \($0.lastPathComponent)") }
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
        }
    }
}

private struct CredentialLookupFailure: Error, Equatable {}

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

final class DeepgramVoiceOutputTests: XCTestCase {
    private var session: URLSession!
    private let audio = DeepgramSpeechFixture.streamedWAV(pcm: DeepgramSpeechFixture.pcm(frames: 2_400))

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testWhitespaceText_ReturnsNothingToSpeakWithoutCredentialRequestFileOrPlayback() async throws {
        let probe = VoiceOutputProbe(), credential = CredentialProbe()
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let erase = PronunciationEntry(word: "\\bum\\b", pronunciation: "", replacement: " ", isRegex: true)
        let cases: [(String, [PronunciationEntry])] = [("", []), (" \n\t ", []), ("um um", [erase])]
        for (text, entries) in cases {
            let request = try DeepgramSpeechRequest(text: text, modelID: nil, voiceID: nil, pronunciation: entries)
            let outcome = try await output.speak(request) { try await credential.supply() }
            XCTAssertEqual(outcome, .nothingToSpeak)
        }
        XCTAssertEqual(credential.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testSpokenRequest_StoresCanonicalAudioPlaysItAndDiscardsItAfterPlayback() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .render(0.1)), credential = CredentialProbe(" fixture-key\n")
        let api = PronunciationEntry(word: "API", pronunciation: "A P I", replacement: "A P I")
        let request = try DeepgramSpeechRequest(
            text: "Hello API", modelID: "flux", voiceID: "deepgram/flux-hannah-en", pronunciation: [api]
        )
        let outcome = try await DeepgramVoiceOutput(session: session, playback: probe.playback)
            .speak(request) { try await credential.supply() }

        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertEqual(receipt.voice.id, "flux-hannah-en")
        XCTAssertEqual(receipt.characterCount, "Hello A P I".unicodeScalars.count)
        XCTAssertEqual(receipt.audioDuration, 0.1, accuracy: 1e-12)
        XCTAssertEqual(receipt.playedDuration, 0.1)
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
        let canonical = DeepgramSpeechFixture.canonicalWAV(pcm: DeepgramSpeechFixture.pcm(frames: 2_400))
        XCTAssertEqual(probe.storedAudio, [canonical])
        XCTAssertEqual(credential.count, 1)
        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.path, "/v2/speak")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token fixture-key")
    }

    func testMissingUnsafeOrFailingCredential_StopsBeforeTheNetwork() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe()
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        let cases: [(String, DeepgramSpeechError)] = [
            ("", .missingCredential), ("  \n", .missingCredential), ("two words", .invalidCredential),
            ("key\r\nX-Injected: 1", .invalidCredential), ("k\u{E9}y", .invalidCredential),
            (String(repeating: "k", count: 4_097), .invalidCredential)
        ]
        for (value, expected) in cases {
            do {
                _ = try await output.speak(request) { value }
                XCTFail("Credential \(expected) was accepted")
            } catch { XCTAssertEqual(error as? DeepgramSpeechError, expected) }
        }
        do {
            _ = try await output.speak(request) { throw CredentialLookupFailure() }
            XCTFail("The host's lookup failure was hidden")
        } catch { XCTAssertEqual(error as? CredentialLookupFailure, CredentialLookupFailure()) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testProviderFailure_StopsBeforeStoringOrPlaying() async throws {
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0, status: 401), Data()) }
        let probe = VoiceOutputProbe()
        do {
            _ = try await speak(probe)
            XCTFail("An unauthorised request reported speech")
        } catch { XCTAssertEqual(error as? DeepgramSpeechError, .unauthorized(statusCode: 401)) }
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationBeforeTheRequest_NeverReadsTheCredential() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(), credential = CredentialProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.speak(probe, credential: credential)
        }
        await assertCancelled(task)
        XCTAssertEqual(credential.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationWhileReadingTheCredential_SendsNoRequest() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(), credential = CredentialProbe(holdUntilReleased: true)
        let task = Task { try await self.speak(probe, credential: credential) }
        await eventually { credential.count == 1 }
        task.cancel()
        credential.release()
        await assertCancelled(task)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationDuringTheExchange_StopsTheTransferAndStoresNothing() async throws {
        let started = expectation(description: "Synthesis started")
        let stopped = expectation(description: "Synthesis stopped")
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let probe = VoiceOutputProbe()
        let task = Task { try await self.speak(probe) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await assertCancelled(task)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationAfterTheResponse_DiscardsTheFileWithoutPlaying() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(cancelDuringStore: true)
        await assertCancelled(Task { try await self.speak(probe) })
        XCTAssertEqual(probe.events, ["store 1", "discard 1"])
    }

    func testCancellationDuringPlayback_DiscardsOnlyAfterThePlayerReleasesTheFile() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .untilCancelled)
        let task = Task { try await self.speak(probe) }
        await eventually { probe.events.contains("play 1") }
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    func testPlaybackFailure_IsReportedAfterTheFileIsDiscarded() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .fail)
        do {
            _ = try await speak(probe)
            XCTFail("A failed playback reported speech")
        } catch { XCTAssertEqual(error as? VoiceOutputProbe.PlayerFailure, VoiceOutputProbe.PlayerFailure()) }
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    func testStoreFailure_NeitherPlaysNorDiscardsAnotherFile() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(failStore: true)
        do {
            _ = try await speak(probe)
            XCTFail("A failed store reported speech")
        } catch { XCTAssertEqual(error as? VoiceOutputProbe.StoreFailure, VoiceOutputProbe.StoreFailure()) }
        XCTAssertEqual(probe.events, ["store failed"])
    }

    func testPlaybackThatRendersNothing_IsNotReportedAsSpeech() async throws {
        respondWithAudio()
        for rendered in [0, -1, TimeInterval.nan] {
            let probe = VoiceOutputProbe(play: .render(rendered))
            do {
                _ = try await speak(probe)
                XCTFail("\(rendered) seconds were reported as speech")
            } catch { XCTAssertEqual(error as? DeepgramVoiceOutput.Failure, .noAudioPlayed) }
            XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
        }
    }

    func testSecondRequestWhileSpeaking_IsRefusedWithoutCredentialOrNetwork() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .untilReleased)
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let request = try DeepgramSpeechRequest(text: "First", modelID: nil, voiceID: nil)
        let first = Task { try await output.speak(request) { "fixture-key" } }
        await eventually { probe.events.contains("play 1") }

        let refused = CredentialProbe()
        do {
            _ = try await output.speak(request) { try await refused.supply() }
            XCTFail("A concurrent request was admitted")
        } catch { XCTAssertEqual(error as? DeepgramVoiceOutput.Failure, .busy) }
        XCTAssertEqual(refused.count, 0)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)

        probe.releasePlayback()
        guard case .spoken = try await first.value else { return XCTFail("The first request did not speak") }
        guard case .spoken = try await output.speak(request, credential: { "fixture-key" }) else {
            return XCTFail("Admission was not released")
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }

    // MARK: - Helpers

    private func respondWithAudio() {
        let audio = audio
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
    }

    private func speak(
        _ probe: VoiceOutputProbe, credential: CredentialProbe = CredentialProbe()
    ) async throws -> DeepgramVoiceOutput.Outcome {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        return try await DeepgramVoiceOutput(session: session, playback: probe.playback)
            .speak(request) { try await credential.supply() }
    }

    private func assertCancelled(
        _ task: Task<DeepgramVoiceOutput.Outcome, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let outcome = try await task.value
            XCTFail("Cancellation reported \(outcome)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private func eventually(
        _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}
