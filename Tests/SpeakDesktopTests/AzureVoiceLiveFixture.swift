import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Azure Voice Live client through the injected
/// transport seam. The fake socket, clock and recorders are the ones the other
/// lifecycle tests use, and the Realtime-family frame helpers come from the
/// OpenAI fixture; only Azure's correlated error frames are defined here. The
/// key and resource are synthetic; no credential, recording or provider text
/// is used.
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

    /// Transcripts, errors and finish results in the order the host saw them.
    let log = AzureVoiceLiveLog()

    func start() {
        client.start(onTranscript: { [events, log] in
            events.transcript($0, final: $1)
            log.record(.transcript($0, final: $1))
        }, onError: { [events, log] in
            events.fail($0)
            log.record(.error("\($0)"))
        })
    }

    /// The transport's handshake, our configuration completing, then Azure's acknowledgement.
    func becomeReady() {
        socket.open()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
    }

    func finish() -> Task<String?, Never> {
        let client = client, log = log
        return Task {
            let transcript = await client.finishAndWait()
            log.record(.finished(transcript))
            return transcript
        }
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

    /// Completes the send in flight and every send it releases, until the
    /// named frame type has been handed to the transport.
    func completeSends(until type: String) {
        for _ in 0..<64 where !socket.types.contains(type) { socket.completeSend() }
        XCTAssertTrue(socket.types.contains(type), "\(type) was never sent")
    }

    /// Finishes a ready run through the commit and the barrier: every admitted
    /// frame, the commit and the barrier leave, and the commit is acknowledged
    /// by the item it created. Returns once the barrier has been handed over.
    func finishThroughBarrier(committing item: String) async -> Task<String?, Never> {
        let finish = finish()
        await waitForFinishers()
        completeSends(until: "input_audio_buffer.commit")
        socket.committed(item)
        socket.completeSend()
        XCTAssertEqual(socket.azureSessionUpdates.count, 2, "The barrier follows the commit")
        socket.completeSend()
        return finish
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

    /// A Voice Live `error` frame, optionally naming the client event behind it.
    func azureError(code: String, type: String = "invalid_request_error", eventID: String? = nil) {
        var details: [String: Any] = ["type": type, "code": code, "message": "Synthetic failure"]
        if let eventID { details["event_id"] = eventID }
        azureEmit(["type": "error", "event_id": "event_synthetic", "error": details])
    }

    func azureEmit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        emit(text)
    }
}

final class AzureVoiceLiveLog: @unchecked Sendable {
    enum Entry: Equatable {
        case transcript(String, final: Bool)
        case error(String)
        case finished(String?)
    }

    private let lock = NSLock()
    private var values: [Entry] = []

    var entries: [Entry] { lock.withLock { values } }

    func record(_ entry: Entry) { lock.withLock { values.append(entry) } }
}

/// The client event identities of one run, for correlating frames.
struct AzureVoiceLiveEventIDs {
    let session: String
    let commit: String
    let barrier: String
}

extension AzureVoiceLiveClient {
    var currentEventIDs: AzureVoiceLiveEventIDs {
        synchronized {
            AzureVoiceLiveEventIDs(session: run.sessionEventID, commit: run.commitEventID, barrier: run.barrierEventID)
        }
    }
}
