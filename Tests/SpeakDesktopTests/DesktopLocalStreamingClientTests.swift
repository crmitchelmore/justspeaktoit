import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopLocalStreamingClientTests: XCTestCase {
    /// Replies with a numbered transcript so tests can see which window ran.
    private final class Recognizer: DesktopLocalRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int] = []
        private var languages: [String?] = []

        var calls: [Int] { lock.withLock { counts } }
        var requestedLanguages: [String?] { lock.withLock { languages } }

        func transcribe(
            samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
        ) async throws -> String {
            try Task.checkCancellation()
            let index = lock.withLock {
                counts.append(samples.count)
                languages.append(language)
                return counts.count
            }
            return "words \(index)"
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, Bool)] = []
        var all: [(String, Bool)] { lock.withLock { values } }
        func record(_ text: String, _ isFinal: Bool) { lock.withLock { values.append((text, isFinal)) } }
    }

    private let model = WhisperCppModels.all[0]

    private func pcm(seconds: Double, amplitude: Int16) -> Data {
        let count = Int(seconds * 16_000)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = index.isMultiple(of: 2) ? amplitude : -amplitude
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    private func send(_ client: DesktopLocalStreamingClient, _ data: Data) {
        let frame = 3_200
        var offset = 0
        while offset < data.count {
            client.sendAudio(data.subdata(in: offset..<min(offset + frame, data.count)))
            offset += frame
        }
    }

    private func makeClient(_ recognizer: Recognizer, language: String? = nil) -> DesktopLocalStreamingClient {
        DesktopLocalStreamingClient(
            recognizer: recognizer, model: model, modelFile: URL(fileURLWithPath: "model.bin"), language: language
        )
    }

    func testOptionsUseLiveIdentifiersOfExecutableBatchModels() {
        for host in [LocalModelHostSupport.windows, .linux] {
            let options = DesktopLocalStreaming.options(host: host)
            XCTAssertFalse(options.isEmpty)
            XCTAssertEqual(
                options.map(\.id),
                DesktopLocalTranscription.models(host: host).map {
                    LocalModelIdentity.whisperLiveModelID(forBatchModelID: $0.catalogueID)
                }
            )
            XCTAssertTrue(options.allSatisfy { $0.id.hasPrefix(LocalModelIdentity.whisperLivePrefix) })
            let slots = DesktopModelSlots(
                live: [], local: DesktopLocalTranscription.options(host: host), localLive: options
            )
            XCTAssertEqual(
                slots.entries.filter { $0.isLocal && $0.isLive }.map(\.option.id), options.map(\.id)
            )
            for option in options {
                XCTAssertNotNil(DesktopLocalStreaming.model(forLiveID: option.id, host: host))
            }
        }
        XCTAssertTrue(DesktopLocalStreaming.options(host: .unsupported).isEmpty)
        XCTAssertEqual(
            DesktopLocalStreaming.model(forLiveID: " local/streaming/whisperkit/base ", host: .windows)?.catalogueID,
            "local/whisperkit/base"
        )
        XCTAssertNil(DesktopLocalStreaming.model(forLiveID: "local/whisperkit/base", host: .windows))
        XCTAssertEqual(
            DesktopHistorySearch.modelDisplayName(for: "local/streaming/whisperkit/small"),
            "Whisper Small (on-device, live)"
        )
    }

    func testSilentSessionNeverReachesTheModelAndStaysEmpty() async {
        let recognizer = Recognizer()
        let client = makeClient(recognizer)
        client.start(onTranscript: { _, _ in }, onError: { error in XCTFail("\(error)") })
        send(client, pcm(seconds: 3, amplitude: 0))
        let result = await client.finishAndWait()
        XCTAssertNil(result)
        XCTAssertTrue(recognizer.calls.isEmpty)
    }

    func testPauseCommitsAStandaloneFinalAndFinishReturnsTheSession() async {
        let recognizer = Recognizer()
        let events = Events()
        let client = makeClient(recognizer, language: "en-GB")
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        client.start(onTranscript: { events.record($0, $1) }, onError: { error in XCTFail("\(error)") })
        send(client, pcm(seconds: 0.5, amplitude: 4_000))
        send(client, pcm(seconds: 1, amplitude: 0))
        let deadline = Date().addingTimeInterval(5)
        while !events.all.contains(where: { $0.1 }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        send(client, pcm(seconds: 0.5, amplitude: 4_000))
        let result = await client.finishAndWait()

        let finals = events.all.filter { $0.1 }.map { $0.0 }
        XCTAssertEqual(finals.count, 1)
        guard let first = finals.first else { return }
        XCTAssertEqual(result?.hasPrefix(first), true)
        XCTAssertEqual(result?.split(separator: " ").count, 4, "One delivered final plus the drained remainder")
        XCTAssertTrue(recognizer.calls.allSatisfy { $0 >= 16_000 }, "Short windows are padded to a second")
        XCTAssertTrue(recognizer.requestedLanguages.allSatisfy { $0 == "en" })
    }

    func testLongSpeechCommitsBeforeTheWindowLimit() async {
        let recognizer = Recognizer()
        let events = Events()
        let client = DesktopLocalStreamingClient(
            recognizer: recognizer, model: model, modelFile: URL(fileURLWithPath: "model.bin"), language: nil,
            tuning: .init(interimInterval: 60, maximumWindow: 2)
        )
        client.start(onTranscript: { events.record($0, $1) }, onError: { error in XCTFail("\(error)") })
        // A steady tone becomes noise after about four seconds, so a 20 ms
        // gap each second keeps it speech whenever the worker commits.
        for _ in 0..<5 {
            send(client, pcm(seconds: 0.02, amplitude: 0))
            send(client, pcm(seconds: 1, amplitude: 4_000))
        }
        _ = await client.finishAndWait()
        XCTAssertTrue(recognizer.calls.allSatisfy { $0 <= 32_000 })
        XCTAssertGreaterThanOrEqual(recognizer.calls.count, 3)
    }

    func testCancelStopsCallbacksAndIsIdempotent() async {
        let recognizer = Recognizer()
        let events = Events()
        let client = makeClient(recognizer)
        client.start(onTranscript: { events.record($0, $1) }, onError: { _ in })
        client.cancel()
        client.cancel()
        send(client, pcm(seconds: 2, amplitude: 4_000))
        let result = await client.finishAndWait()
        XCTAssertNil(result)
        XCTAssertTrue(events.all.isEmpty)
    }
}
