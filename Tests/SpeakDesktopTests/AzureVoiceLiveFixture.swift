import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Azure Voice Live client through the injected
/// transport seam. The fake socket, clock and recorders are the ones the other
/// lifecycle tests use, and the Realtime-family frame helpers come from the
/// OpenAI fixture; only Azure's error and barrier helpers are defined here.
/// Every payload is generated: the key is synthetic and no credential,
/// recording or provider text is used or logged.
final class AzureVoiceLiveFixture: @unchecked Sendable {
    static let endpoint = "https://synthetic.services.ai.azure.com"
    static let credentials = "synthetic-key:uksouth"

    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: AzureVoiceLiveClient

    init(
        model: String = "azure-speech", credentials: String = AzureVoiceLiveFixture.credentials,
        endpoint: String = AzureVoiceLiveFixture.endpoint, language: String? = nil, sampleRate: Int = 24_000
    ) {
        let factory = factory, clock = clock
        client = AzureVoiceLiveClient(
            credentials: credentials, endpoint: endpoint, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }
    var finishBudget: TimeInterval { client.finishBudget }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// The real handshake, our configuration completing, then its acknowledgement.
    func becomeReady() {
        socket.open()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
    }

    /// Completes every send the client hands over until nothing is in flight.
    func completeSends(_ count: Int) {
        for _ in 0..<count { socket.completeSend() }
    }

    func finish() -> Task<String?, Never> {
        let client = client
        return Task { await client.finishAndWait() }
    }

    /// Waits until `count` finish callers are registered on the current run, so
    /// no frame races the registration and no fixed sleep is needed.
    func waitForFinishers(_ count: Int = 1) async {
        await settle { client.pendingFinishCount >= count }
    }

    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }

    /// 100 ms of generated 24 kHz PCM16 mono whose bytes identify the frame.
    static func frame(_ index: Int, count: Int = 4_800) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
    }
}

extension AssemblyAITestSocket {
    /// Every `session.update` sent: the configuration, then the finalisation barrier.
    var azureSessionUpdates: [[String: Any]] { objects.filter { $0["type"] as? String == "session.update" } }

    var azureCommits: [[String: Any]] { objects.filter { $0["type"] as? String == "input_audio_buffer.commit" } }

    /// Fulfils once the client hands the finalisation barrier to the transport.
    func fulfillOnAzureBarrier(_ expectation: XCTestExpectation) {
        onSend = { message in
            guard case .text(let text) = message, text.contains("\"session.update\""),
                  text.contains("-barrier") else { return }
            expectation.fulfill()
        }
    }

    /// A Voice Live `error` frame, optionally naming the client event behind it.
    func azureError(code: String, eventID: String? = nil) {
        var details: [String: Any] = ["type": "invalid_request_error", "code": code, "message": "Synthetic failure"]
        if let eventID { details["event_id"] = eventID }
        azureEmit(["type": "error", "error": details])
    }

    /// The acknowledgement Azure sends for each `session.update`, in order.
    func azureAcknowledge() { acknowledge(sessionType: nil) }

    func azureEmit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        emit(text)
    }
}

extension AzureVoiceLiveClient {
    /// The client event identities of the current run, for correlating frames.
    var currentEventIDs: (commit: String, barrier: String) {
        lock.withLock { (run.commitEventID, run.barrierEventID) }
    }
}
