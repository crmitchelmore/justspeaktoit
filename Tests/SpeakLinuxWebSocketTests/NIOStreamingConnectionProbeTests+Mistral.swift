import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakLinuxWebSocket

/// The shared Mistral Voxtral client over the NIO transport against the
/// probe's Voxtral peer, the same scenarios the Windows WinHTTP adapter passes.
/// The client builds its own request; only scheme, host and port are
/// redirected to loopback. Key and audio are synthetic.
extension NIOStreamingConnectionProbeTests {
    func testMistralClientReplaysHeldAudioStreamsLiveAudioAndReturnsTheRevisedDone() async throws {
        let outcome = try await recordMistral("complete", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "Hello world.", "\(outcome.events.errors)")
        XCTAssertEqual(outcome.events.texts, ["helo", "helo wrld"])
        XCTAssertTrue(outcome.events.errors.isEmpty, "\(outcome.events.errors)")
        XCTAssertFalse(outcome.events.finals.contains(true), "The consumed done is not also delivered as a final")
    }

    func testMistralClientAssemblesFragmentedUnicodeEvents() async throws {
        let heard = mistralUnicodeHead + mistralUnicodeTail
        let outcome = try await recordMistral("fragment", heard: heard)
        let transcript = try XCTUnwrap(outcome.transcript, "\(outcome.events.errors)")
        XCTAssertEqual(Array(transcript.unicodeScalars), Array((heard + ".").unicodeScalars))
        XCTAssertEqual(outcome.events.texts.last.map { Array($0.unicodeScalars) }, Array(heard.unicodeScalars))
        XCTAssertTrue(outcome.events.errors.isEmpty, "\(outcome.events.errors)")
    }

    func testMistralClientReportsAPeerDisconnectBeforeDoneWithoutWaitingOutItsDeadline() async throws {
        let outcome = try await recordMistral("disconnect", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "helo wrld", "The folded draft is returned for recovery")
        XCTAssertEqual(outcome.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertLessThan(outcome.elapsed, MistralVoxtralRealtime.finishBudget)
    }

    func testMistralClientReportsAMissingDoneAtItsWholeFinishDeadline() async throws {
        let outcome = try await recordMistral("silent", heard: "helo wrld")
        XCTAssertEqual(outcome.transcript, "helo wrld", "The folded draft is returned for recovery")
        XCTAssertEqual(outcome.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertGreaterThanOrEqual(outcome.elapsed, MistralVoxtralRealtime.finishBudget - 0.25)
        XCTAssertLessThan(outcome.elapsed, MistralVoxtralRealtime.finishBudget + 3)
    }
}

private extension NIOStreamingConnectionProbeTests {
    struct MistralOutcome {
        let transcript: String?
        let elapsed: TimeInterval
        let events: MistralLoopbackEvents
    }

    /// Ten 100 ms frames are offered before the session exists; ten more follow
    /// once the peer's deltas prove the session is streaming; then finish.
    func recordMistral(_ scenario: String, heard folded: String) async throws -> MistralOutcome {
        let port = try XCTUnwrap(probePort)
        let events = MistralLoopbackEvents()
        let client = MistralVoxtralLiveClient(apiKey: "jsti-loopback-synthetic", makeConnection: { request in
            NIOStreamingConnection(request: mistralLoopbackRequest(request, port: port, scenario: scenario))
        })
        let heard = expectation(description: "Peer deltas folded into the interim text")
        heard.assertForOverFulfill = false
        client.start(onTranscript: { text, isFinal in
            events.transcript(text, final: isFinal)
            if text == folded { heard.fulfill() }
        }, onError: { events.fail($0) })
        for index in 0..<10 { client.sendAudio(mistralLoopbackFrame(index)) }
        await fulfillment(of: [heard], timeout: 10)
        for index in 10..<20 { client.sendAudio(mistralLoopbackFrame(index)) }
        let started = Date()
        let transcript = await client.finishAndWait()
        return MistralOutcome(transcript: transcript, elapsed: Date().timeIntervalSince(started), events: events)
    }
}

private let mistralUnicodeHead = "\u{754C} \u{2014} caf\u{E9}"
private let mistralUnicodeTail = " e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"

private func mistralLoopbackRequest(_ request: URLRequest, port: Int, scenario: String) -> URLRequest {
    var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } ?? URLComponents()
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

private func mistralLoopbackFrame(_ index: Int) -> Data {
    Data((0..<3_200).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
}

private final class MistralLoopbackEvents: @unchecked Sendable {
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
