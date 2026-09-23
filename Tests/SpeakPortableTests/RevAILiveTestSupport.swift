import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Rev.ai client through its injected transport and
/// scheduler. The scripted socket, factory and clock are the Cartesia suite's
/// (`CartesiaLiveTestSupport.swift`); only Rev.ai's frames and the event log
/// are its own. Every handshake, send completion, server frame, closure and
/// deadline happens only when a test says so: no sleeps, no network, no
/// credential. Payloads are generated.
final class RevAILiveFixture: @unchecked Sendable {
    let factory = CartesiaSocketFactory()
    let clock = CartesiaTestClock()
    let log = RevAIEventLog()
    let client: RevAILiveClient

    init(token: String = "synthetic-token", language: String? = "en_GB", sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = RevAILiveClient(
            accessToken: token, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: CartesiaTestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [log] in log.transcript($0, final: $1) }, onError: { [log] in log.fail($0) })
    }

    /// The handshake followed by `connected`, the frame that permits audio.
    func startAndConnect() {
        start()
        socket.open()
        socket.revAIConnected()
    }

    /// Admits one frame and completes its send, so it is on the wire.
    func stream(_ frame: Data) {
        client.sendAudio(frame)
        socket.completeSend()
    }

    /// Every socket this fixture creates completes sends synchronously.
    func useSynchronousSends() { factory.configure { $0.setSendMode(.synchronous) } }

    /// Runs `finishAndWait()` and records its return in the ordered log.
    func finish() -> Task<String?, Never> {
        let client = client, log = log
        return Task {
            let transcript = await client.finishAndWait()
            log.finished(transcript)
            return transcript
        }
    }

    /// Fulfils when the client hands `EOS` to the first socket.
    func expectEndOfStream(_ test: XCTestCase) -> XCTestExpectation {
        let sent = test.expectation(description: "EOS handed to the transport")
        socket.onSend { message in
            if case .text(let text) = message, text == RevAILiveClient.endOfStreamToken { sent.fulfill() }
        }
        return sent
    }

    /// Waits, within a bound, until `count` finish callers are registered on
    /// the active run. It polls a condition; it never sleeps for an outcome.
    func waitForFinishes(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if client.pendingFinishes >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Only \(client.pendingFinishes) of \(count) finishes registered", file: file, line: line)
    }

    /// 100 ms of generated 16 kHz PCM16 mono with a recognisable fill byte.
    static func frame(_ fill: UInt8, count: Int = 3_200) -> Data { Data(repeating: fill, count: count) }
}

extension CartesiaTestSocket {
    /// Rev.ai's `connected` message, as the documented example session sends it.
    func revAIConnected() { emit(#"{"type":"connected","id":"s1d24ax2fd21"}"#) }

    /// A partial hypothesis: word elements only, as Rev.ai sends them.
    func revAIPartial(_ words: [String]) {
        emit(Self.revAIHypothesis("partial", words.map { ["type": "text", "value": $0] }))
    }

    /// A final hypothesis carrying its whole text in one element.
    func revAIFinal(_ text: String) { emit(Self.revAIHypothesis("final", [["type": "text", "value": text]])) }

    /// A final that ends its segment without words.
    func revAIEmptyFinal() { emit(Self.revAIHypothesis("final", [])) }

    /// `EOS` frames handed to this socket.
    var endOfStreamFrames: Int { texts.filter { $0 == RevAILiveClient.endOfStreamToken }.count }

    static func revAIHypothesis(_ type: String, _ elements: [[String: String]]) -> String {
        let object: [String: Any] = ["type": type, "ts": 0.5, "end_ts": 1.5, "elements": elements]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            XCTFail("Invalid synthetic Rev.ai hypothesis")
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The final of Rev.ai's documented example session: `punct` elements
    /// carry the space and the full stop.
    static let revAIDocumentedFinal = """
    {"type":"final","ts":1.01,"end_ts":3.2,"elements":[\
    {"type":"text","value":"One","ts":1.04,"end_ts":1.55,"confidence":1.0},\
    {"type":"punct","value":" "},\
    {"type":"text","value":"two","ts":1.84,"end_ts":2.15,"confidence":1.0},\
    {"type":"punct","value":"."}]}
    """
}

/// Transcript callbacks, errors and finish returns in the order they happened.
final class RevAIEventLog: @unchecked Sendable {
    enum Entry: Equatable {
        case transcript(String, final: Bool)
        case error(String)
        case finished(String?)
    }

    private let lock = NSLock()
    private var entriesValue: [Entry] = []
    private var errorsValue: [Error] = []

    var entries: [Entry] { lock.withLock { entriesValue } }
    var errors: [Error] { lock.withLock { errorsValue } }
    var transcripts: [Entry] { entries.filter { if case .transcript = $0 { true } else { false } } }

    func transcript(_ text: String, final: Bool) {
        lock.withLock { entriesValue.append(.transcript(text, final: final)) }
    }

    func fail(_ error: Error) {
        lock.withLock {
            errorsValue.append(error)
            entriesValue.append(.error(Self.describe(error)))
        }
    }

    func finished(_ transcript: String?) { lock.withLock { entriesValue.append(.finished(transcript)) } }

    static func describe(_ error: Error) -> String {
        if let live = error as? RevAILiveError { return "\(live)" }
        if let streaming = error as? RevAIStreamingError { return "\(streaming)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        if let url = error as? URLError { return "URLError(\(url.code.rawValue))" }
        return "\(type(of: error))"
    }

    static func urlError(_ code: URLError.Code) -> Entry { .error(describe(URLError(code))) }
    static let stalled = Entry.error(#"transportStalled(provider: "Rev.ai")"#)
}
