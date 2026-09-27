import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopLocalLiveTranscriptionTests: XCTestCase {
    /// Names each decoded window by how many speech bursts it holds, so a test
    /// can see exactly which audio each pass covered.
    private final class Recognizer: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [[Float]] = []
        var failure: Error?
        var delay: Double = 0

        var calls: [[Float]] { lock.withLock { windows } }

        func recognize(_ samples: [Float]) async throws -> String {
            lock.withLock { windows.append(samples) }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            try Task.checkCancellation()
            if let failure { throw failure }
            return "[BLANK_AUDIO] " + (0..<Self.bursts(in: samples)).map { "word\($0 + 1)" }.joined(separator: " ")
        }

        static func bursts(in samples: [Float]) -> Int {
            let energies = DesktopEnergyVAD.frameEnergies(samples[...], sampleRate: 16_000)
            var count = 0
            var inBurst = false
            for energy in energies {
                let speech = energy > 0.05
                if speech && !inBurst { count += 1 }
                inBurst = speech
            }
            return count
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Bool)] = []
        private var failures: [String] = []
        func add(_ text: String, _ final: Bool) { lock.withLock { items.append((text, final)) } }
        func fail(_ error: Error) { lock.withLock { failures.append(error.localizedDescription) } }
        var finals: [String] { lock.withLock { items.filter(\.1).map(\.0) } }
        var interims: [String] { lock.withLock { items.filter { !$0.1 }.map(\.0) } }
        var errors: [String] { lock.withLock { failures } }
    }

    private static func pcm(speech seconds: Double) -> Data { pcm(seconds, amplitude: 0.3) }
    private static func pcm(silence seconds: Double) -> Data { pcm(seconds, amplitude: 0) }

    private static func pcm(_ seconds: Double, amplitude: Float) -> Data {
        let count = Int(seconds * 16_000)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = amplitude * sin(Float(index) * 2 * .pi * 220 / 16_000)
            var sample = Int16(max(-1, min(1, value)) * 32_767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func configuration() -> DesktopLocalLiveConfiguration {
        var configuration = DesktopLocalLiveConfiguration()
        configuration.step = 0.5
        configuration.poll = 0.005
        return configuration
    }

    /// Feeds audio in 100 ms frames, giving the loop a chance to run.
    private func feed(_ client: DesktopLocalLiveClient, _ data: Data) async {
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 3_200)
            client.sendAudio(data.subdata(in: offset..<end))
            offset = end
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testSelectionsKeepTheCatalogueIdentifierAndOnlyQualifiedModelsAreLive() {
        let options = DesktopLocalLiveTranscription.options(host: .windows)
        XCTAssertEqual(options.map(\.id), ["local/whisperkit/tiny#live", "local/whisperkit/base#live"])
        XCTAssertTrue(options.allSatisfy { $0.displayName.hasSuffix("(on-device, live)") })
        XCTAssertEqual(
            DesktopLocalLiveTranscription.catalogueID(forSelection: "local/whisperkit/tiny#live"), "local/whisperkit/tiny"
        )
        XCTAssertNil(DesktopLocalLiveTranscription.catalogueID(forSelection: "local/whisperkit/tiny"))
        XCTAssertNil(DesktopLocalLiveTranscription.model(forSelection: "local/whisperkit/small#live", host: .windows),
                     "Small has no live receipt")
        XCTAssertTrue(DesktopLocalLiveTranscription.options(host: .unsupported).isEmpty)
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: "local/whisperkit/base#live"),
                       "Whisper Base (on-device, live)")
    }

    func testModelSlotsHoldLocalLiveSelectionsAsLiveAndLocal() throws {
        let local = DesktopLocalTranscription.options(host: .windows)
        let localLive = DesktopLocalLiveTranscription.options(host: .windows)
        var slots = DesktopModelSlots(live: [], local: local, localLive: localLive)
        let entry = try XCTUnwrap(slots.entries.first { $0.option.id == "local/whisperkit/tiny#live" })
        XCTAssertTrue(entry.isLive && entry.isLocal)
        XCTAssertTrue(try XCTUnwrap(slots.entries.first { $0.option.id == "local/whisperkit/tiny" }).isLocal)
        try slots.update(discovered: [], retaining: [])
        XCTAssertEqual(slots.entries.filter { $0.isLive && $0.isLocal }.map(\.option.id), localLive.map(\.id))
        let imported = ModelCatalog.Option(id: "local/whispercpp/huggingface/o/r/ggml-x-bin", displayName: "x")
        let count = slots.entries.count
        try slots.appendLocal([imported, local[0]])
        XCTAssertEqual(slots.entries.count, count + 1, "Known identifiers keep their slot")
        XCTAssertTrue(slots.entries.last?.isLocal == true && slots.entries.last?.isLive == false)
        try slots.update(discovered: [], retaining: [])
        XCTAssertTrue(slots.visibleIndices.contains(count), "An imported model survives discovery refreshes")
    }

    func testPausesCommitPhrasesAndTheStopDecodesTheTail() async throws {
        let recognizer = Recognizer()
        let events = Events()
        let client = DesktopLocalLiveClient(configuration: configuration()) { try await recognizer.recognize($0) }
        client.start(onTranscript: events.add, onError: events.fail)

        await feed(client, Self.pcm(silence: 0.6) + Self.pcm(speech: 0.8) + Self.pcm(silence: 1.2))
        await waitUntil { !events.finals.isEmpty }
        XCTAssertEqual(events.finals, ["word1"], "A pause commits the phrase once")
        await feed(client, Self.pcm(speech: 0.6) + Self.pcm(silence: 0.2) + Self.pcm(speech: 0.4))
        let final = await client.finishAndWait()

        XCTAssertEqual(final, "word1 word1 word2", "The tail decode covers everything after the last commit")
        XCTAssertEqual(events.finals, ["word1", "word1 word2"])
        XCTAssertFalse(events.finals.joined().contains("BLANK"), "Non-speech markers never reach the transcript")
        XCTAssertTrue(recognizer.calls.allSatisfy { $0.count >= 17_600 }, "Windows are padded to whisper.cpp's minimum")
        XCTAssertTrue(recognizer.calls.allSatisfy { Recognizer.bursts(in: $0) <= 2 },
                      "Committed audio is never decoded again")
        XCTAssertTrue(events.errors.isEmpty)
        XCTAssertGreaterThan(client.statistics.passes, 0)
    }

    func testSilenceIsNeverDecodedAndAnEmptyRecordingStaysEmpty() async {
        let recognizer = Recognizer()
        let events = Events()
        let client = DesktopLocalLiveClient(configuration: configuration()) { try await recognizer.recognize($0) }
        client.start(onTranscript: events.add, onError: events.fail)
        await feed(client, Self.pcm(silence: 3) + Self.pcm(0.5, amplitude: 0.001))
        let final = await client.finishAndWait()
        XCTAssertNil(final)
        XCTAssertTrue(recognizer.calls.isEmpty, "Whisper invents text for silence, so it never sees any")
        XCTAssertTrue(events.finals.isEmpty)
    }

    func testLongPhrasesAreCutAtTheirQuietestPointBelowWhispersInputLimit() async {
        let recognizer = Recognizer()
        let events = Events()
        var configuration = configuration()
        configuration.maximumWindow = 3
        let client = DesktopLocalLiveClient(configuration: configuration) { try await recognizer.recognize($0) }
        client.start(onTranscript: events.add, onError: events.fail)
        // Two-second bursts with 0.3 s gaps: never a commit-length pause.
        for _ in 0..<3 { await feed(client, Self.pcm(speech: 2) + Self.pcm(silence: 0.3)) }
        _ = await client.finishAndWait()
        XCTAssertGreaterThanOrEqual(events.finals.count, 2)
        XCTAssertTrue(recognizer.calls.allSatisfy { Double($0.count) / 16_000 <= 3.6 },
                      "No pass exceeds the window limit plus one step")
    }

    func testRecognizerFailureIsReportedAndCancellationIsSilent() async {
        struct Broken: LocalizedError { var errorDescription: String? { "runtime crashed" } }
        let recognizer = Recognizer()
        recognizer.failure = Broken()
        let events = Events()
        let client = DesktopLocalLiveClient(configuration: configuration()) { try await recognizer.recognize($0) }
        client.start(onTranscript: events.add, onError: events.fail)
        await feed(client, Self.pcm(speech: 1.2))
        await waitUntil { !events.errors.isEmpty }
        XCTAssertEqual(events.errors, ["runtime crashed"])

        let slow = Recognizer()
        slow.delay = 5
        let quiet = Events()
        let cancelled = DesktopLocalLiveClient(configuration: configuration()) { try await slow.recognize($0) }
        cancelled.start(onTranscript: quiet.add, onError: quiet.fail)
        await feed(cancelled, Self.pcm(speech: 1.2))
        await waitUntil { !slow.calls.isEmpty }
        cancelled.cancel()
        let final = await cancelled.finishAndWait()
        XCTAssertNil(final)
        XCTAssertTrue(quiet.errors.isEmpty, "A cancelled pass is not a failure")
    }

    func testTheSharedLiveSessionDisplaysCommittedTextPlusTheCurrentHypothesis() async {
        let recognizer = Recognizer()
        let client = DesktopLocalLiveClient(configuration: configuration()) { try await recognizer.recognize($0) }
        let session = DesktopLiveSession(client: client)
        session.start()
        var data = Self.pcm(speech: 0.8) + Self.pcm(silence: 1.2) + Self.pcm(speech: 0.8)
        while !data.isEmpty {
            let chunk = data.prefix(3_200)
            session.sendAudio(Data(chunk))
            data.removeFirst(chunk.count)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await waitUntil { session.snapshot().text == "word1 word1" }
        XCTAssertEqual(session.snapshot().text, "word1 word1")
        let finished = await session.finish()
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertEqual(finished.text, "word1 word1")
    }
}
