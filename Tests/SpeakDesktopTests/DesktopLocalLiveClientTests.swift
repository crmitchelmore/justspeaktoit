import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// The sliding-window live client against a deterministic recogniser that
/// names each tone burst in the audio it is given by its amplitude.
final class DesktopLocalLiveClientTests: XCTestCase {
    private final class BurstRecognizer: DesktopLocalRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var silentFrom: Int?
        var failure: Error?

        var decodeCount: Int { lock.withLock { calls } }

        /// From the next decode on, the recogniser hears nothing.
        func goSilent() { lock.withLock { silentFrom = calls } }

        func transcribe(
            samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
        ) async throws -> String {
            try Task.checkCancellation()
            let silent = lock.withLock { () -> Bool in
                calls += 1
                return silentFrom.map { calls > $0 } ?? false
            }
            if let failure { throw failure }
            return silent ? "" : Self.label(samples)
        }

        /// One word per burst of at least 90 ms: alpha, beta or gamma by peak.
        static func label(_ samples: [Float]) -> String {
            let levels = DesktopLocalLiveClient.frameLevels(samples)
            var words: [String] = []
            var run = 0
            var peak: Float = 0
            func close() {
                if run >= 3 {
                    let names: [(Float, String)] = [(0.2, "alpha"), (0.3, "beta"), (0.4, "gamma")]
                    words.append(names.min { abs($0.0 - peak) < abs($1.0 - peak) }!.1)
                }
                run = 0
                peak = 0
            }
            for (index, level) in levels.enumerated() {
                if level > 0.02 {
                    run += 1
                    let start = index * DesktopLocalLiveClient.frameSamples
                    let end = min(samples.count, start + DesktopLocalLiveClient.frameSamples)
                    peak = max(peak, samples[start..<end].map(abs).max() ?? 0)
                } else { close() }
            }
            close()
            return words.joined(separator: " ")
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Bool)] = []
        private var errors: [String] = []
        var interims: [String] { lock.withLock { items.filter { !$0.1 }.map(\.0) } }
        var finals: [String] { lock.withLock { items.filter(\.1).map(\.0) } }
        var failures: [String] { lock.withLock { errors } }
        func add(_ text: String, _ final: Bool) { lock.withLock { items.append((text, final)) } }
        func fail(_ error: Error) { lock.withLock { errors.append(error.localizedDescription) } }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "decoder exploded" }
    }

    private var tuning: DesktopLocalLiveClient.Tuning {
        var tuning = DesktopLocalLiveClient.Tuning()
        tuning.step = 0.5
        tuning.minimumWindow = 0.5
        tuning.pause = 0.5
        tuning.maximumWindow = 2
        return tuning
    }

    private func model() throws -> WhisperCppModel { try XCTUnwrap(WhisperCppModels.live.first) }

    private static func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }

    private static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    /// Feeds 100 ms chunks, letting the worker catch up after each one.
    private func feed(_ samples: [Float], to client: DesktopLocalLiveClient) async {
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + 1_600)
            client.append(Array(samples[start..<end]))
            await client.waitUntilIdle()
            start = end
        }
    }

    private func makeClient(_ recognizer: BurstRecognizer) throws -> (DesktopLocalLiveClient, Events) {
        let client = DesktopLocalLiveClient(
            model: try model(), modelFile: URL(fileURLWithPath: "/models/ggml-tiny.bin"), language: "en-GB",
            recognizer: recognizer, tuning: tuning
        )
        let events = Events()
        client.start(onTranscript: { events.add($0, $1) }, onError: { events.fail($0) })
        return (client, events)
    }

    func testAPauseConfirmsASegmentAndFinishingReturnsTheWholeSession() async throws {
        let recognizer = BurstRecognizer()
        let (client, events) = try makeClient(recognizer)
        await feed(Self.tone(1, amplitude: 0.2) + Self.silence(1) + Self.tone(1, amplitude: 0.3), to: client)
        XCTAssertEqual(events.finals, ["alpha"], "The pause confirms the first utterance once")
        XCTAssertEqual(events.interims.first, "alpha", "Text appears while speaking")
        XCTAssertEqual(events.interims.last, "beta", "Each window after the pause starts afresh")
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "alpha beta")
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertGreaterThan(client.decodeCount, 3)
        XCTAssertTrue(events.failures.isEmpty)
    }

    func testSilenceIsNeverDecodedAndFinishesEmpty() async throws {
        let recognizer = BurstRecognizer()
        let (client, events) = try makeClient(recognizer)
        await feed(Self.silence(3), to: client)
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(recognizer.decodeCount, 0, "Whisper invents text for silence, so it never runs")
        XCTAssertTrue(events.interims.isEmpty && events.finals.isEmpty)
    }

    func testAnEmptyTailDecodeKeepsTheWordsAlreadyShown() async throws {
        let recognizer = BurstRecognizer()
        let (client, events) = try makeClient(recognizer)
        await feed(Self.tone(1.2, amplitude: 0.4), to: client)
        XCTAssertEqual(events.interims.last, "gamma")
        recognizer.goSilent()
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "gamma")
    }

    func testALongUtteranceIsCutAtTheMaximumWindow() async throws {
        let recognizer = BurstRecognizer()
        let (client, events) = try makeClient(recognizer)
        // Two bursts separated by a dip too short to confirm as a pause.
        await feed(Self.tone(1.2, amplitude: 0.2) + Self.silence(0.3) + Self.tone(1.2, amplitude: 0.3), to: client)
        XCTAssertEqual(events.finals.first, "alpha", "The window is cut at its quietest point, the dip")
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "alpha beta")
    }

    func testARecogniserFailureIsReportedOnce() async throws {
        let recognizer = BurstRecognizer()
        recognizer.failure = Failure()
        let (client, events) = try makeClient(recognizer)
        await feed(Self.tone(1.5, amplitude: 0.2), to: client)
        XCTAssertEqual(events.failures, ["decoder exploded"])
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testCancellingStopsDecoding() async throws {
        let recognizer = BurstRecognizer()
        let (client, _) = try makeClient(recognizer)
        await feed(Self.tone(0.6, amplitude: 0.2), to: client)
        let before = recognizer.decodeCount
        client.cancel()
        client.append(Self.tone(2, amplitude: 0.2))
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(recognizer.decodeCount, before)
    }

    func testPCMIsDecodedAsLittleEndianLinear16() async throws {
        let recognizer = BurstRecognizer()
        let (client, _) = try makeClient(recognizer)
        let pcm = Self.tone(1, amplitude: 0.3).map { Int16($0 * 32_767) }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        client.sendAudio(data)
        await client.waitUntilIdle()
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "beta")
    }

    func testTheSharedLiveSessionShowsHypothesesAndAdoptsTheFinalTranscript() async throws {
        let recognizer = BurstRecognizer()
        let client = DesktopLocalLiveClient(
            model: try model(), modelFile: URL(fileURLWithPath: "/models/ggml-tiny.bin"), language: nil,
            recognizer: recognizer, tuning: tuning
        )
        let session = DesktopLiveSession(client: client)
        session.start()
        var start = 0
        let audio = Self.tone(1, amplitude: 0.2) + Self.silence(1) + Self.tone(1, amplitude: 0.3)
        var shown: [String] = []
        while start < audio.count {
            let chunk = audio[start..<min(audio.count, start + 1_600)].map { Int16($0 * 32_767) }
            session.sendAudio(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            await client.waitUntilIdle()
            shown.append(session.snapshot().text)
            start += 1_600
        }
        XCTAssertTrue(shown.contains("alpha"))
        XCTAssertTrue(shown.contains("alpha beta"), "Confirmed text stays while the next hypothesis extends it")
        let final = await session.finish()
        XCTAssertEqual(final.text, "alpha beta")
        XCTAssertEqual(final.phase, .finished)
    }
}
