import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The former `ModulateLiveController` behaviour, proven on the shared path:
/// WAV-framed PCM, query options, diarised text, per-utterance boundaries and
/// the `done` duration, segments and raw utterances History keeps.
@MainActor
final class ModulateSharedRouteParityTests: XCTestCase {
    func testDiarisedUtterancesKeepLabelsBoundariesTimingsAndRawPayload() async throws {
        let requests = RequestLog()
        let fixture = try makeFixture(requests: requests)
        fixture.settings.modulateSpeakerDiarizationEnabled = true
        fixture.settings.modulateEmotionSignalEnabled = true
        try await fixture.start()
        fixture.send(Data(repeating: 1, count: 3_200))
        fixture.socket.completeSends()
        fixture.socket.emit(Self.utterance("Hello.", id: Self.first, speaker: 1, startMs: 0))
        fixture.socket.emit(Self.utterance("Hello.", id: Self.first, speaker: 1, startMs: 0))
        fixture.socket.emit(Self.utterance("Hi there.", id: Self.second, speaker: 2, startMs: 1_500))
        fixture.updates.deliverAll()

        let labelled = "Speaker 1: Hello.\nSpeaker 2: Hi there."
        XCTAssertEqual(fixture.delegate.partials.last, labelled)
        XCTAssertEqual(fixture.delegate.boundaries, ["Hello.", "Hi there."], "Each utterance is announced once")
        XCTAssertEqual(fixture.delegate.events.last, .boundary("Hi there."), "The boundary follows its text")
        let query = try XCTUnwrap(requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(query.queryItems?.first { $0.name == "speaker_diarization" }?.value, "true")
        XCTAssertEqual(query.queryItems?.first { $0.name == "emotion_signal" }?.value, "true")
        XCTAssertEqual(query.queryItems?.first { $0.name == "accent_signal" }?.value, "false")
        XCTAssertEqual(
            fixture.socket.binary.first?.prefix(4), Data("RIFF".utf8), "The first frame carries the WAV header"
        )

        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [""]
        }
        socket.emit(#"{"type":"done","duration_ms":4200}"#)
        await stopping.value

        let result = try XCTUnwrap(fixture.delegate.results.last)
        XCTAssertEqual(result.text, labelled)
        XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello.", "Speaker 2: Hi there."])
        XCTAssertEqual(result.segments.map(\.startTime), [0, 1.5])
        XCTAssertEqual(result.segments.map(\.endTime), [1, 2.5])
        XCTAssertEqual(result.duration, 4.2)
        XCTAssertEqual(result.modelIdentifier, "modulate/velma-2-stt-streaming")
        XCTAssertEqual(result.cost?.totalCost, TranscriptionPricing.estimatedCost(
            modelID: "modulate/velma-2-stt-streaming", durationSeconds: 4.2
        )?.totalCost)
        let payload = try XCTUnwrap(result.rawPayload.flatMap { $0.data(using: .utf8) })
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(raw["duration_ms"] as? Int, 4_200)
        XCTAssertEqual((raw["utterances"] as? [[String: Any]])?.compactMap { $0["speaker"] as? Int }, [1, 2])
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testOneSpeakerStaysUnlabelledAndALateUtteranceJoinsTheResult() async throws {
        let fixture = try makeFixture()
        fixture.settings.modulateSpeakerDiarizationEnabled = true
        try await fixture.start()
        fixture.socket.emit(Self.utterance("First.", id: Self.first, speaker: 1, startMs: 0))
        fixture.updates.deliverAll()
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [""]
        }
        socket.emit(Self.utterance("Late.", id: Self.second, speaker: 1, startMs: 1_000))
        socket.emit(#"{"type":"done","duration_ms":2000}"#)
        await stopping.value

        XCTAssertEqual(fixture.delegate.results.last?.text, "First. Late.")
        XCTAssertEqual(fixture.delegate.results.last?.segments.map(\.text), ["First.", "Late."])
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testProviderErrorFailsOnceAndKeepsTheTextAsRecovery() async throws {
        let fixture = try makeFixture()
        try await fixture.start()
        fixture.socket.emit(Self.utterance("Kept.", id: Self.first, speaker: 1, startMs: 0))
        fixture.socket.emit(#"{"type":"error","error":"quota exceeded"}"#)
        fixture.updates.deliverAll()
        await fixture.controller.stop()
        fixture.updates.deliverAll()

        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertEqual(fixture.delegate.errors.first?.localizedDescription, "quota exceeded")
        XCTAssertTrue(fixture.delegate.results.isEmpty, "A failed stream must not publish terminal success")
        XCTAssertEqual(fixture.delegate.partials.last, "Kept.")
    }

    private func makeFixture(requests: RequestLog = RequestLog()) throws -> SharedClientParityFixture {
        try SharedClientParityFixture(model: "modulate/velma-2-stt-streaming") { context in
            ModulateLiveClient(
                apiKey: "synthetic", sampleRate: context.route.sampleRate, options: context.options.modulate,
                makeConnection: { [socket = context.socket] request in
                    requests.append(request.url)
                    return socket
                },
                schedule: { [clock = context.clock] in clock.schedule($0, action: $1) }
            )
        }
    }

    private static let first = "8F1A2B3C-0000-4000-8000-000000000001"
    private static let second = "8F1A2B3C-0000-4000-8000-000000000002"

    private static func utterance(_ text: String, id: String, speaker: Int, startMs: Int) -> String {
        #"{"type":"utterance","utterance":{"utterance_uuid":""# + id + #"","text":""# + text
            + #"","start_ms":"# + String(startMs) + #","duration_ms":1000,"speaker":"# + String(speaker)
            + #","language":"en","emotion":null,"accent":null}}"#
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var first: URL? { lock.withLock { urls.first } }
    func append(_ url: URL?) { if let url { lock.withLock { urls.append(url) } } }
}
