import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopComparisonTests: XCTestCase {
    private let candidates = [
        DesktopComparisonCandidate(modelID: "first", displayName: "First", providerName: "Synthetic"),
        DesktopComparisonCandidate(modelID: "second", displayName: "Second", providerName: "Synthetic")
    ]

    func testFileIdenticalFrozenBytesLanguageAndIndependentFailures() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.wav")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: file)
        let observations = Observations()
        let round = try await DesktopComparisonRunner.file(
            audio: file, pending: pending(mode: .file, language: "en_GB"), candidates: candidates
        ) { audio, candidate, language in
            await observations.append(try Data(contentsOf: audio), language: language)
            if candidate.modelID == "second" { throw DesktopComparisonError.message("Synthetic provider failed.") }
            return comparisonResult("Raw result.", model: candidate.modelID)
        }
        let recorded = await observations.values
        XCTAssertEqual(recorded.map(\.0), [bytes, bytes])
        XCTAssertEqual(recorded.map(\.1), ["en_GB", "en_GB"])
        XCTAssertEqual(round.entries.map(\.modelID), ["first", "second"])
        XCTAssertEqual(round.entries[0].transcript, "Raw result.")
        XCTAssertEqual(round.entries[1].errorDescription, "Synthetic provider failed.")
        XCTAssertTrue(round.isValid)
        XCTAssertFalse(round.isJudged)
        XCTAssertEqual(Set(round.blindOrder), Set(round.entries.map(\.id)))
    }

    func testDeadlineDoesNotWaitForNonCooperativeProvider() async throws {
        let hold = Hold<String>()
        let started = ContinuousClock.now
        do {
            _ = try await DesktopComparisonDeadline.run(timeout: .milliseconds(30)) { await hold.value() }
            XCTFail("Expected deadline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("time limit"))
        }
        XCTAssertLessThan(DesktopComparisonRunner.milliseconds(started.duration(to: .now)), 1000)
        hold.complete("Late result")
    }

    func testCancelledFileReturnsRecoverableFailureEntriesNotSuccess() async throws {
        let hold = Hold<TranscriptionResult>()
        let task = Task {
            try await DesktopComparisonRunner.file(
                audio: URL(fileURLWithPath: "synthetic.wav"), pending: self.pending(mode: .batch),
                candidates: self.candidates
            ) { _, _, _ in await hold.value() }
        }
        task.cancel()
        let round = try await task.value
        XCTAssertTrue(round.entries.allSatisfy { $0.errorDescription == "Comparison cancelled." })
        XCTAssertTrue(round.entries.allSatisfy { $0.transcript.isEmpty })
        hold.complete(comparisonResult("Late", model: "late"))
    }

    func testSelectionValidationRejectsDuplicatesAndSingleton() {
        XCTAssertThrowsError(try DesktopComparisonRunner.validate([candidates[0]]))
        XCTAssertThrowsError(try DesktopComparisonRunner.validate([candidates[0], candidates[0]]))
    }

    func testPersistenceRelaunchBlindJudgingCanonicalExportAndScoreboard() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory)
        let entries = candidates.map { candidate in
            ModelComparisonEntry(modelID: candidate.modelID, modelDisplayName: candidate.displayName,
                                 providerDisplayName: candidate.providerName, transcript: candidate.modelID)
        }
        let round = ModelComparisonRound(
            inputMode: .file, sample: sample(), language: nil, originPlatform: "test", entries: entries,
            blindOrder: entries.reversed().map(\.id)
        )
        try await store.upsert(round)
        do {
            try await store.judge(id: round.id, ranksInBlindOrder: [1, 1])
            XCTFail("Duplicate ranks")
        } catch {}
        let unchanged = await store.rounds()
        XCTAssertFalse(unchanged[0].isJudged)
        try await store.judge(id: round.id, ranksInBlindOrder: [2, 1])
        let reopened = try DesktopComparisonStore(directory: directory)
        let rounds = await reopened.rounds()
        XCTAssertEqual(rounds[0].blindOrder, round.blindOrder)
        XCTAssertEqual(rounds[0].rank(for: entries[0].id), 1)
        XCTAssertTrue(rounds[0].isJudged)
        let json = try ModelComparisonExport.json(rounds: rounds)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ModelComparisonExport.Document.self, from: json)
        XCTAssertEqual(export.schemaVersion, ModelComparisonRound.schemaVersion)
        XCTAssertEqual(export.scoreboard.map(\.modelID), ModelComparisonScoreboard.scores(for: rounds).map(\.modelID))
        XCTAssertEqual(export.scoreboard[0].wins, 1)
        XCTAssertFalse(try XCTUnwrap(String(data: json, encoding: .utf8)).contains("audioData"))
        XCTAssertTrue(ModelComparisonExport.markdown(rounds: rounds).contains("## Scoreboard"))
    }

    func testStoreFailedWriteDoesNotChangeInMemoryRound() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory) { _, _ in throw CocoaError(.fileWriteUnknown) }
        let entry = candidates[0].entry()
        let round = ModelComparisonRound(
            inputMode: .file, sample: sample(), language: nil, originPlatform: "test",
            entries: [entry], blindOrder: [entry.id]
        )
        do { try await store.upsert(round); XCTFail("Write failed") } catch {}
        let rounds = await store.rounds()
        XCTAssertTrue(rounds.isEmpty)
    }

    func testCorruptSavedRoundsFailClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("not json".utf8)
        let file = directory.appendingPathComponent("rounds.json")
        try data.write(to: file)
        XCTAssertThrowsError(try DesktopComparisonStore(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

}

extension DesktopComparisonTests {
    func testReadinessBarrierSendsNoAudioUntilReadyAndTimesOutOneLaneIndependently() async throws {
        let ready = ComparisonClient(ready: true)
        let stalled = ComparisonClient(ready: false)
        let fanout = try live(ready, stalled)
        fanout.sendAudio(pcm([0, 100, 200]))
        try await fanout.prepare(timeout: .milliseconds(30))
        let capture = pcm([0, 100, 200, 300])
        fanout.sendAudio(capture)
        XCTAssertEqual(ready.audio, [capture])
        XCTAssertTrue(stalled.audio.isEmpty)
        let entries = await fanout.finish()
        XCTAssertEqual(entries[0].transcript, "Complete")
        XCTAssertTrue(entries[1].didFail)
        XCTAssertTrue(stalled.cancelled)
    }

    func testIdenticalPCMForSameRateAndExactCommonResamplingAcrossFrames() async throws {
        let first = ComparisonClient(ready: true)
        let second = ComparisonClient(ready: true)
        let fanout = try live(first, second, rates: [16_000, 16_000])
        try await fanout.prepare()
        fanout.sendAudio(pcm([0, 100]))
        fanout.sendAudio(pcm([200, 300, 400, 500, 600]))
        XCTAssertEqual(first.audio, second.audio)
        XCTAssertEqual(first.audio.reduce(Data(), +), pcm([0, 150, 300, 450, 600]))
        fanout.cancel()
    }

    func testProviderFailureCloseBeforeCompletionRetainsPartialAndDoesNotFailOtherLane() async throws {
        let first = ComparisonClient(ready: true)
        let second = ComparisonClient(ready: true)
        let fanout = try live(first, second)
        try await fanout.prepare()
        first.emit("Recovery", final: false)
        first.fail("Closed before completion")
        fanout.sendAudio(pcm([0, 1]))
        let entries = await fanout.finish()
        XCTAssertEqual(entries[0].transcript, "Recovery")
        XCTAssertEqual(entries[0].errorDescription, "Closed before completion")
        XCTAssertEqual(entries[1].transcript, "Complete")
        XCTAssertNil(entries[1].errorDescription)
    }

    func testCancellationBeforeReadinessAndLateCallbacksCannotContaminateReplacement() async throws {
        let first = ComparisonClient(ready: false)
        let second = ComparisonClient(ready: false)
        let old = try live(first, second)
        old.cancel()
        do { try await old.prepare(); XCTFail("Cancelled") } catch {}
        let nextFirst = ComparisonClient(ready: true)
        let nextSecond = ComparisonClient(ready: true)
        let next = try live(nextFirst, nextSecond)
        try await next.prepare()
        first.emit("Late old result", final: true)
        old.sendAudio(pcm([9]))
        next.sendAudio(pcm([10, 11]))
        XCTAssertTrue(first.audio.isEmpty)
        XCTAssertEqual(nextFirst.audio, [pcm([10, 11])])
        let results = await next.finish()
        XCTAssertTrue(results.allSatisfy { $0.transcript == "Complete" })
    }

    func testLiveFinishDeadlineRetainsTextAndRejectsLateCompletion() async throws {
        let first = ComparisonClient(ready: true, holdsFinish: true)
        let second = ComparisonClient(ready: true)
        let fanout = try live(first, second)
        try await fanout.prepare()
        first.emit("Partial", final: false)
        let entries = await fanout.finish(timeout: .milliseconds(30))
        XCTAssertEqual(entries[0].transcript, "Partial")
        XCTAssertTrue(entries[0].didFail)
        XCTAssertNil(entries[1].errorDescription)
        first.finishHold.complete("Late completion")
        first.emit("Late callback", final: true)
        XCTAssertEqual(entries[0].transcript, "Partial")
        XCTAssertTrue(first.cancelled)
    }

    func testConcurrentFinishIsOneOperationAndCancellationKeepsRecoveryText() async throws {
        let first = ComparisonClient(ready: true, holdsFinish: true)
        let second = ComparisonClient(ready: true)
        let fanout = try live(first, second)
        try await fanout.prepare()
        first.emit("Recovery", final: false)
        async let one = fanout.finish(timeout: .milliseconds(40))
        async let two = fanout.finish(timeout: .milliseconds(40))
        let outcomes = await (one, two)
        XCTAssertEqual(outcomes.0, outcomes.1)
        XCTAssertEqual(first.finishCount, 1)
        XCTAssertEqual(second.finishCount, 1)
        XCTAssertEqual(outcomes.0[0].transcript, "Recovery")
        first.finishHold.complete("Late")
        fanout.cancel()
        XCTAssertEqual(fanout.snapshot()[0].transcript, "Recovery")
    }

    func testAllReadinessTimeoutsFailWithoutStartingAudio() async throws {
        let first = ComparisonClient(ready: false)
        let second = ComparisonClient(ready: false)
        let fanout = try live(first, second)
        do { try await fanout.prepare(timeout: .milliseconds(20)); XCTFail("No ready lanes") } catch {}
        fanout.sendAudio(pcm([1, 2]))
        XCTAssertTrue(first.audio.isEmpty && second.audio.isEmpty)
        XCTAssertTrue(first.cancelled && second.cancelled)
    }

    func testCancelDuringNonCooperativeFinishReturnsWithoutWaitingForFinishBudget() async throws {
        let first = ComparisonClient(ready: true, holdsFinish: true)
        let second = ComparisonClient(ready: true)
        let fanout = try live(first, second)
        try await fanout.prepare()
        first.emit("Recovery", final: false)
        let finishing = Task { await fanout.finish(timeout: .seconds(30)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while first.finishCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(first.finishCount, 1)
        let started = ContinuousClock.now
        fanout.cancel()
        let results = await finishing.value
        XCTAssertLessThan(DesktopComparisonRunner.milliseconds(started.duration(to: .now)), 1000)
        XCTAssertEqual(results[0].transcript, "Recovery")
        XCTAssertTrue(results[0].didFail)
        first.finishHold.complete("Late completion")
    }

    func testCompletionPreservesPersistedBlindIdentityAndRejectsChangedCandidates() throws {
        let entries = candidates.map { $0.entry() }
        let pending = ModelComparisonRound(
            inputMode: .batch, sample: sample(), language: "en_GB", originPlatform: "test",
            entries: entries, blindOrder: entries.reversed().map(\.id)
        )
        var results = candidates.map { $0.entry() }
        results[0].transcript = "Raw"
        let completed = try DesktopComparisonRunner.completing(pending, entries: results, sample: sample())
        XCTAssertEqual(completed.id, pending.id)
        XCTAssertEqual(completed.createdAt, pending.createdAt)
        XCTAssertEqual(completed.blindOrder, pending.blindOrder)
        XCTAssertEqual(completed.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(completed.entries[0].transcript, "Raw")
        XCTAssertThrowsError(try DesktopComparisonRunner.completing(
            pending, entries: Array(results.reversed()), sample: sample()
        ))
    }

}

private extension DesktopComparisonTests {
    func pending(mode: ModelComparisonInputMode, language: String? = nil) -> ModelComparisonRound {
        let entries = candidates.map { $0.entry() }
        return ModelComparisonRound(
            inputMode: mode, sample: sample(), language: language, originPlatform: "test",
            entries: entries, blindOrder: ModelComparisonRound.makeBlindOrder(for: entries)
        )
    }

    func live(
        _ first: ComparisonClient, _ second: ComparisonClient, rates: [Int] = [24_000, 24_000]
    ) throws -> DesktopComparisonLive {
        try DesktopComparisonLive(lanes: [
            .init(candidate: candidates[0], client: first, sampleRate: rates[0]),
            .init(candidate: candidates[1], client: second, sampleRate: rates[1])
        ])
    }

    func pcm(_ samples: [Int16]) -> Data {
        samples.reduce(into: Data()) { result, sample in
            var sample = sample.littleEndian
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
    }

    func sample() -> ModelComparisonSample {
        .init(name: "Synthetic.wav", contentHash: String(repeating: "a", count: 64), durationSeconds: 1)
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private func comparisonResult(_ text: String, model: String) -> TranscriptionResult {
    TranscriptionResult(
        text: text, segments: [], confidence: nil, duration: 1, modelIdentifier: model,
        cost: nil, rawPayload: nil, debugInfo: nil
    )
}

private actor Observations {
    var values: [(Data, String?)] = []
    func append(_ bytes: Data, language: String?) { values.append((bytes, language)) }
}

private final class Hold<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CheckedContinuation<Value, Never>] = []
    private var settled: Value?
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let result: Value? = lock.withLock {
                if let settled { return settled }
                values.append(continuation)
                return nil
            }

            if let result { continuation.resume(returning: result) }
        }
    }
    func complete(_ value: Value) {
        let waiters = lock.withLock {
            settled = value
            defer { values = [] }
            return values
        }
        waiters.forEach { $0.resume(returning: value) }
    }
}

private final class ComparisonClient: FinalizingStreamingTranscriptionClient,
    StreamingAudioReadyProviding, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.cumulativeTranscript
    let isReadyForAudio: Bool
    let holdsFinish: Bool
    let finishHold = Hold<String>()
    private let lock = NSLock()
    private var received: [Data] = []
    private var isCancelled = false
    private var finishes = 0
    private var transcript: ((String, Bool) -> Void)?
    private var error: ((Error) -> Void)?
    var audio: [Data] { lock.withLock { received } }
    var cancelled: Bool { lock.withLock { isCancelled } }
    var finishCount: Int { lock.withLock { finishes } }
    init(ready: Bool, holdsFinish: Bool = false) { isReadyForAudio = ready; self.holdsFinish = holdsFinish }
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { transcript = onTranscript; error = onError }
    }
    func sendAudio(_ audioData: Data) { lock.withLock { received.append(audioData) } }
    func stop() { lock.withLock { isCancelled = true } }
    func finishAndWait() async -> String? {
        lock.withLock { finishes += 1 }
        return holdsFinish ? await finishHold.value() : "Complete"
    }
    func emit(_ text: String, final: Bool) { lock.withLock { transcript }?(text, final) }
    func fail(_ message: String) { lock.withLock { error }?(DesktopComparisonError.message(message)) }
}
