import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// The desktop projection admits Gladia's canonical live route, and the shared
/// client drives a `DesktopLiveSession` through its whole-session finish.
final class GladiaDesktopFactoryTests: XCTestCase {
    func testProjectionAdmitsTheCanonicalGladiaRouteWithItsMetadata() throws {
        let canonical = ModelCatalog.liveTranscription.filter {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .gladia
        }
        XCTAssertFalse(canonical.isEmpty)
        for option in canonical {
            XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == option.id })
            let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(option.id) "))
            XCTAssertEqual(route, LiveTranscriptionRouting.route(for: option.id))
            XCTAssertEqual(route.sampleRate, 16_000)
            let milliseconds = DesktopLiveTranscription.captureFrameMilliseconds(forID: option.id)
            XCTAssertEqual(route.sampleRate * 2 * milliseconds / 1_000, 3_200, "100 ms of 16 kHz PCM16 mono")
            let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: option.id))
            XCTAssertEqual(provider.apiKeyIdentifier, "gladia.apiKey")
            XCTAssertEqual(provider.displayName, "Gladia")
            XCTAssertFalse(DesktopLiveTranscription.languageHintModelIDs.contains(option.id),
                           "The canonical language capability is unchanged")
            let made = DesktopLiveTranscription.makeClient(
                model: option.id, apiKey: "k", language: "fr_FR",
                makeConnection: { _ in fatalError("Constructing a client must not open a socket") }
            )
            let client = try XCTUnwrap(made as? GladiaLiveClient)
            XCTAssertEqual(client.model, "solaria-1")
            XCTAssertEqual(client.sampleRate, 16_000)
            XCTAssertNil(client.language, "A route without the language capability forwards no hint")
            XCTAssertEqual(client.endpoint.absoluteString, "https://api.gladia.io/v2/live")
            XCTAssertEqual(client.finalisationBudget, GladiaLive.finishBudget)
            XCTAssertEqual(client.currentStage, .idle)
        }
        XCTAssertNil(DesktopLiveTranscription.route(forID: "gladia/solaria-1"), "The batch model is not live")
    }

    func testDesktopSessionReplacesTextWithGladiasWholeTranscript() async throws {
        let factory = AssemblyAISocketFactory()
        let session = DesktopLiveSession(client: Self.client(factory))
        session.start()
        let socket = try XCTUnwrap(factory.sockets.first)
        XCTAssertNil(factory.requests.first?.value(forHTTPHeaderField: "x-gladia-key"))
        socket.open()
        session.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        socket.emit(Self.transcript("Hello desktop.", id: "00-01", isFinal: true))
        let stopped = expectation(description: "stop_recording sent")
        socket.onSend = { message in
            if case .text(let text) = message, text.contains("stop_recording") { stopped.fulfill() }
        }
        let finishing = Task { await session.finish() }
        await fulfillment(of: [stopped], timeout: 5)
        socket.completeSend()
        socket.emit(Self.transcript("And the tail.", id: "00-02", isFinal: true))
        socket.emit(#"{"type":"end_session"}"#)
        let snapshot = await finishing.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "Hello desktop. And the tail.")
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(socket.binary, [Data(repeating: 1, count: 3_200)])
    }

    func testDesktopSessionKeepsTheVisibleDraftWhenGladiaFails() async throws {
        let factory = AssemblyAISocketFactory()
        let session = DesktopLiveSession(client: Self.client(factory))
        session.start()
        let socket = try XCTUnwrap(factory.sockets.first)
        socket.open()
        session.sendAudio(Data(repeating: 2, count: 3_200))
        socket.completeSend()
        socket.emit(Self.transcript("Kept.", id: "00-01", isFinal: true))
        socket.emit(Self.transcript("Visible draft", id: "00-02", isFinal: false))
        socket.emit(#"{"type":"error","error":{"message":"Upstream failure"}}"#)
        let snapshot = await session.finish()
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Kept. Visible draft")
        XCTAssertEqual(snapshot.error, GladiaStreamingError.server(message: "Upstream failure").localizedDescription)
        XCTAssertEqual(socket.cancels, 1)
    }

    private static func client(_ factory: AssemblyAISocketFactory) -> GladiaLiveClient {
        GladiaLiveClient(
            apiKey: "synthetic",
            initiateSession: { _, completion in
                let body = #"{"id":"s","url":"wss://api.gladia.io/v2/live?token=synthetic"}"#
                completion(.success((201, Data(body.utf8))))
                return GladiaNoRequest()
            },
            makeConnection: { factory.make($0) },
            schedule: { _, _ in }
        )
    }

    private static func transcript(_ text: String, id: String, isFinal: Bool) -> String {
        #"{"type":"transcript","data":{"id":"\#(id)","is_final":\#(isFinal),"utterance":{"text":"\#(text)"}}}"#
    }
}

private final class GladiaNoRequest: GladiaLiveSessionRequest {
    func cancel() {}
}
