import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

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
            XCTAssertTrue(DesktopLiveTranscription.languageHintModelIDs.contains(option.id),
                          "Gladia's session request carries a selected language")
            let made = DesktopLiveTranscription.makeClient(
                model: option.id, apiKey: "k", language: "fr_FR",
                makeConnection: { _ in fatalError("Constructing a client must not open a socket") }
            )
            let client = try XCTUnwrap(made as? GladiaLiveClient)
            XCTAssertEqual(client.model, "solaria-1")
            XCTAssertEqual(client.sampleRate, 16_000)
            XCTAssertEqual(client.language, "fr_FR", "The selection reaches the shared client, as on iOS")
            XCTAssertEqual(client.endpoint.absoluteString, "https://api.gladia.io/v2/live")
            XCTAssertEqual(client.finalisationBudget, GladiaLive.finishBudget)
            XCTAssertEqual(client.currentStage, .idle)
        }
        XCTAssertNil(DesktopLiveTranscription.route(forID: "gladia/solaria-1"), "The batch model is not live")
    }

    /// The desktop route's own session request pins the selection as Gladia's
    /// code. Automatic, no selection and a language Gladia does not list let
    /// Gladia detect it, so the session is never refused for its language.
    func testDesktopSessionRequestCarriesTheSelectedLanguage() throws {
        let identifier = try XCTUnwrap(DesktopLiveTranscription.liveModels.first {
            DesktopLiveTranscription.route(forID: $0.id)?.provider == .gladia
        }?.id)
        let cases: [(String?, [String])] = [
            ("fr_FR", ["fr"]), ("pt_BR", ["pt"]), ("automatic", []), (nil, []), ("yue_HK", [])
        ]
        for (selection, languages) in cases {
            let label = String(describing: selection)
            let sessions = GladiaHeldSessions()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: identifier, apiKey: "synthetic", language: selection,
                initiateGladiaSession: sessions.initiator,
                makeConnection: { _ in fatalError("A held session request opens no socket") }
            ))
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("\(label): \($0)") })
            let body = try XCTUnwrap(sessions.bodies.first, label)
            client.cancel()
            let config = try XCTUnwrap(body["language_config"] as? [String: Any], label)
            XCTAssertEqual(config["languages"] as? [String], languages, label)
            XCTAssertEqual(config["code_switching"] as? Bool, languages.isEmpty, "Detection switches per utterance")
        }
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

    /// Gladia's failure reaches the client on a transport thread while the
    /// host is finishing. The session must end failed with the error, never
    /// as a success that the late report can no longer correct.
    func testDesktopSessionFinishingDuringAPendingFailureReportEndsFailed() async throws {
        let socket = GladiaHeldCancelSocket()
        let client = Self.client { _ in socket }
        let session = DesktopLiveSession(client: client)
        session.start()
        socket.open()
        session.sendAudio(Data(repeating: 3, count: 3_200))
        socket.completeSend()
        socket.emit(Self.transcript("Kept.", id: "00-01", isFinal: true))
        let cancelling = expectation(description: "The failed run's socket is being cancelled")
        let gate = DispatchSemaphore(value: 0)
        socket.holdNextCancel(entered: { cancelling.fulfill() }, until: gate)
        DispatchQueue.global().async {
            socket.emit(#"{"type":"error","error":{"message":"Upstream failure"}}"#)
        }
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertEqual(client.currentStage, .closed)
        XCTAssertEqual(session.snapshot().phase, .recording, "The host has not heard the failure yet")

        let finishing = Task { await session.finish() }
        let parked = Date().addingTimeInterval(5)
        while client.finishWaiterCount < 1, Date() < parked { await Task.yield() }
        XCTAssertEqual(client.finishWaiterCount, 1, "The host's finish waits for the pending report")
        gate.signal()
        let snapshot = await finishing.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.error, GladiaStreamingError.server(message: "Upstream failure").localizedDescription)
        XCTAssertEqual(snapshot.text, "Kept.")
    }

    private static func client(_ factory: AssemblyAISocketFactory) -> GladiaLiveClient {
        client { factory.make($0) }
    }

    private static func client(
        _ makeConnection: @escaping GladiaLiveClient.ConnectionFactory
    ) -> GladiaLiveClient {
        GladiaLiveClient(
            apiKey: "synthetic",
            initiateSession: { _, completion in
                let body = #"{"id":"s","url":"wss://api.gladia.io/v2/live?token=synthetic"}"#
                completion(.success((201, Data(body.utf8))))
                return GladiaNoRequest()
            },
            makeConnection: makeConnection,
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

/// Records every session request the client makes and never answers one.
private final class GladiaHeldSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var bodies: [[String: Any]] {
        lock.withLock { requests }.compactMap { request in
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    var initiator: GladiaLiveClient.SessionInitiator {
        { [self] request, _ in
            lock.withLock { requests.append(request) }
            return GladiaNoRequest()
        }
    }
}

/// One socket whose next `cancel()` can be held on the thread that calls it.
private final class GladiaHeldCancelSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var cancelHold: (entered: @Sendable () -> Void, gate: DispatchSemaphore)?

    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { completions.append(completion) }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }

    func cancel() {
        let hold = lock.withLock { () -> (entered: @Sendable () -> Void, gate: DispatchSemaphore)? in
            defer { cancelHold = nil }
            return cancelHold
        }
        guard let hold else { return }
        hold.entered()
        hold.gate.wait()
    }

    func holdNextCancel(entered: @escaping @Sendable () -> Void, until gate: DispatchSemaphore) {
        lock.withLock { cancelHold = (entered, gate) }
    }

    func open() { lock.withLock { opener }?() }

    func completeSend() {
        let completion = lock.withLock { completions.isEmpty ? nil : completions.removeFirst() }
        completion?(nil)
    }

    func emit(_ text: String) {
        let pending = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            defer { receiver = nil }
            return receiver
        }
        pending?(.success(.text(text)))
    }
}
