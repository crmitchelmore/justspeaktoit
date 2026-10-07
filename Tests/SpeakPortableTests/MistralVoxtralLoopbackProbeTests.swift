import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The actual shared Mistral Voxtral client over the Apple `URLSession`
/// adapter, against the same bounded Voxtral peer the WinHTTP runtime probe
/// uses (`scripts/websocket-loopback-probe.py`). Explicitly enabled only with
/// that local peer; the key and audio are synthetic. FoundationNetworking is
/// not a qualified WebSocket transport for any host, so it is skipped there.
final class MistralVoxtralLoopbackProbeTests: XCTestCase {
    func testClientReplaysHeldAudioStreamsLiveAudioAndReturnsTheRevisedDone() async throws {
        let outcome = try await record("complete", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "Hello world.", "\(outcome.errors)")
        XCTAssertEqual(outcome.texts, ["helo", "helo wrld"])
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
        XCTAssertFalse(outcome.finals.contains(true), "The consumed done is not also delivered as a final")
    }

    func testClientAssemblesFragmentedUnicodeEvents() async throws {
        let heard = "\u{754C} \u{2014} caf\u{E9}" + " e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
        let outcome = try await record("fragment", heard: heard)
        let transcript = try XCTUnwrap(outcome.transcript, "\(outcome.errors)")
        XCTAssertEqual(Array(transcript.unicodeScalars), Array((heard + ".").unicodeScalars))
        XCTAssertEqual(outcome.texts.last.map { Array($0.unicodeScalars) }, Array(heard.unicodeScalars))
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    }

    func testClientReportsAPeerDisconnectBeforeDoneWithoutWaitingOutItsDeadline() async throws {
        let outcome = try await record("disconnect", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "helo wrld", "The folded draft is returned for recovery")
        XCTAssertEqual(outcome.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertLessThan(outcome.elapsed, MistralVoxtralRealtime.finishBudget)
    }

    func testClientReportsAMissingDoneAtItsWholeFinishDeadline() async throws {
        let outcome = try await record("silent", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "helo wrld", "The folded draft is returned for recovery")
        XCTAssertEqual(outcome.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertGreaterThanOrEqual(outcome.elapsed, MistralVoxtralRealtime.finishBudget - 0.25)
        XCTAssertLessThan(outcome.elapsed, MistralVoxtralRealtime.finishBudget + 3)
    }
}

private extension MistralVoxtralLoopbackProbeTests {
    struct Outcome {
        let transcript: String?
        let elapsed: TimeInterval
        let texts: [String]
        let finals: [Bool]
        let errors: [Error]
    }

    /// Ten 100 ms frames are offered before the session exists, ten more once
    /// the peer's deltas prove it is streaming, then the client finishes.
    func record(_ scenario: String, heard folded: String) async throws -> Outcome {
        #if canImport(FoundationNetworking)
        throw XCTSkip("FoundationNetworking is not a qualified WebSocket transport; Windows uses WinHTTP.")
        #else
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Set JSTI_WEBSOCKET_PROBE_PORT only with the local WebSocket probe server.")
        }
        let port = try XCTUnwrap(Int(value))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let events = LoopbackEvents()
        let client = MistralVoxtralLiveClient(apiKey: "jsti-loopback-synthetic", makeConnection: { request in
            URLSessionStreamingConnection(session: session, request: Self.loopback(request, port: port, scenario))
        })
        let heard = expectation(description: "Peer deltas folded into the interim text")
        heard.assertForOverFulfill = false
        client.start(onTranscript: { text, isFinal in
            events.transcript(text, final: isFinal)
            if text == folded { heard.fulfill() }
        }, onError: { events.fail($0) })
        for index in 0..<10 { client.sendAudio(Self.frame(index)) }
        await fulfillment(of: [heard], timeout: 10)
        for index in 10..<20 { client.sendAudio(Self.frame(index)) }
        let started = Date()
        let transcript = await client.finishAndWait()
        return Outcome(transcript: transcript, elapsed: Date().timeIntervalSince(started),
                       texts: events.texts, finals: events.finals, errors: events.errors)
        #endif
    }

    /// The client's own request, redirected to the loopback peer.
    static func loopback(_ request: URLRequest, port: Int, _ scenario: String) -> URLRequest {
        var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            ?? URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        var local = request
        local.url = components.url
        local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        local.setValue(scenario, forHTTPHeaderField: "X-JSTI-Mistral-Scenario")
        return local
    }

    /// The generated 100 ms frame the peer expects at this index.
    static func frame(_ index: Int) -> Data {
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
    }
}

private final class LoopbackEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var textValues: [String] = []
    private var finalValues: [Bool] = []
    private var failures: [Error] = []
    var texts: [String] { lock.withLock { textValues } }
    var finals: [Bool] { lock.withLock { finalValues } }
    var errors: [Error] { lock.withLock { failures } }
    func transcript(_ text: String, final: Bool) {
        lock.withLock {
            textValues.append(text)
            finalValues.append(final)
        }
    }
    func fail(_ error: Error) { lock.withLock { failures.append(error) } }
}
