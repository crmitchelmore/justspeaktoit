import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The canonical Cartesia live route on desktop hosts: admitted from the shared
/// catalogue and routing, built as the shared client over the host's
/// transport, and folded by the shared desktop session.
final class CartesiaDesktopFactoryTests: XCTestCase {
    private var canonical: ModelCatalog.Option? {
        ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia }
    }

    func testCanonicalRouteIsAdmittedWithoutCopiedMetadata() throws {
        let option = try XCTUnwrap(canonical)
        // The persisted identifier and API model name stay exactly as shipped.
        XCTAssertEqual(option.id, "cartesia/ink-2-streaming")
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(option.id) \n"))
        XCTAssertEqual(route, LiveTranscriptionRouting.route(for: option.id))
        XCTAssertEqual(route.apiModelName, "ink-2")
        XCTAssertEqual(route.sampleRate, LiveTranscriptionProviderID.cartesia.expectedSampleRate)
        let projected = DesktopLiveTranscription.liveModels.filter {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia
        }
        XCTAssertEqual(projected.map(\.id), [option.id])
        XCTAssertEqual(projected.first?.displayName, option.displayName)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: option.id))
        XCTAssertEqual(provider.id, LiveTranscriptionProviderID.cartesia.rawValue)
        XCTAssertEqual(provider.displayName, LiveTranscriptionProviderID.cartesia.displayName)
        XCTAssertEqual(provider.apiKeyIdentifier, LiveTranscriptionProviderID.cartesia.apiKeyIdentifier)
        XCTAssertEqual(provider.website, LiveTranscriptionProviderID.cartesia.apiKeyURL?.absoluteString)
        XCTAssertFalse(DesktopLiveTranscription.languageHintModelIDs.contains(option.id))
        XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: option.id), 100)

        let client = DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "key", language: "fr_FR", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            }
        )
        XCTAssertTrue(client is CartesiaLiveClient)
        XCTAssertEqual(client?.finalShape, .standaloneSegments)
        XCTAssertEqual(client?.finishFlushesBufferedAudio, true)
        XCTAssertEqual(client?.finalisationBudget, CartesiaLiveClient.finishBudget)
    }

    func testSelectedLanguageNeverReachesTheRequest() throws {
        let option = try XCTUnwrap(canonical)
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "synthetic", language: "fr_FR", makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { client.cancel() }
        let url = try XCTUnwrap(factory.requests.first?.url)
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        XCTAssertEqual(names, ["model", "encoding", "sample_rate", "cartesia_version"])
        XCTAssertEqual(factory.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
    }

    func testSessionReturnsTheWholeTranscriptOnceTheServerClosesTheStream() async throws {
        let (session, socket) = try makeSession()
        socket.open()
        session.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        socket.cartesiaTurn("First turn.")
        XCTAssertEqual(session.snapshot().text, "First turn.")

        let closeSent = expectation(description: "Close command sent after the drain")
        socket.onSend = { if case .text(CartesiaLiveProtocol.closeCommand) = $0 { closeSent.fulfill() } }
        let finish = Task { await session.finish() }
        await fulfillment(of: [closeSent], timeout: 2)
        socket.completeSend()
        socket.cartesiaTurn(" Second turn.")
        socket.fail()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "First turn. Second turn.")
        XCTAssertNil(snapshot.error)
    }

    func testSessionKeepsTheBestVisibleDraftWhenTheLastTurnIsNeverConfirmed() async throws {
        let (session, socket) = try makeSession()
        socket.open()
        socket.cartesiaTurn("Confirmed.")
        socket.emit(Self.event("turn.start"))
        socket.emit(Self.event("turn.update", "Trailing"))
        XCTAssertEqual(session.snapshot().text, "Confirmed. Trailing")

        let closeSent = expectation(description: "Close command sent")
        socket.onSend = { if case .text(CartesiaLiveProtocol.closeCommand) = $0 { closeSent.fulfill() } }
        let finish = Task { await session.finish() }
        await fulfillment(of: [closeSent], timeout: 2)
        socket.completeSend()
        socket.emit(Self.event("turn.update", "Trailing words"))
        socket.fail()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Confirmed. Trailing words", "The flushed draft stays visible as recovery text")
        XCTAssertEqual(snapshot.error, CartesiaStreamingError.incompleteTurn.localizedDescription)
    }

    func testServerFailureDuringFinishIsReportedAndTheDraftIsKept() async throws {
        let (session, socket) = try makeSession()
        socket.open()
        socket.emit(Self.event("turn.start"))
        socket.emit(Self.event("turn.update", "Partial words"))
        let closeSent = expectation(description: "Close command sent")
        socket.onSend = { if case .text(CartesiaLiveProtocol.closeCommand) = $0 { closeSent.fulfill() } }
        let finish = Task { await session.finish() }
        await fulfillment(of: [closeSent], timeout: 2)
        socket.completeSend()
        socket.emit(#"{"type":"error","status_code":500,"title":"Synthetic","message":"Synthetic failure"}"#)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Partial words")
        XCTAssertNotNil(snapshot.error)
    }

    private func makeSession() throws -> (DesktopLiveSession, AssemblyAITestSocket) {
        let option = try XCTUnwrap(canonical)
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "synthetic", makeConnection: { factory.make($0) }
        ))
        let session = DesktopLiveSession(client: client)
        session.start()
        return (session, try XCTUnwrap(factory.sockets.first))
    }

    static func event(_ type: String, _ transcript: String? = nil) -> String {
        var object: [String: String] = ["type": type, "request_id": "synthetic"]
        object["transcript"] = transcript
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}

private extension AssemblyAITestSocket {
    func cartesiaTurn(_ text: String) {
        emit(CartesiaDesktopFactoryTests.event("turn.start"))
        emit(CartesiaDesktopFactoryTests.event("turn.update", text))
        emit(CartesiaDesktopFactoryTests.event("turn.end", text))
    }
}
