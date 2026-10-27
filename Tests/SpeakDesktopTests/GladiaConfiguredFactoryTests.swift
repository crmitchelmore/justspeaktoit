import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class GladiaConfiguredFactoryTests: XCTestCase {
    func testActualDesktopFactoryPreservesNativeTransportFramingAndRichDraftAtHealthyFinish() async throws {
        let sockets = AssemblyAISocketFactory()
        let sessions = GladiaDesktopInitiation()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: "gladia/solaria-1-streaming", apiKey: "synthetic-desktop", language: "en_GB",
            initiateGladiaSession: sessions.initiator,
            options: LiveClientOptions(
                keywords: [], assemblyAIKeyterms: [], modulate: .none,
                postStopFinalizeBudget: 0.5, stopGracePeriod: 0.05
            ), makeConnection: { sockets.make($0) }
        ))
        XCTAssertEqual(try XCTUnwrap(client.finalisationBudget), 3.55, accuracy: 0.000_001)
        let session = DesktopLiveSession(client: client)
        defer { session.cancel() }
        session.start()
        let socket = try XCTUnwrap(sockets.sockets.first)
        socket.open()
        let request = try XCTUnwrap(sessions.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "synthetic-desktop")
        XCTAssertNil(sockets.requests.first?.value(forHTTPHeaderField: "x-gladia-key"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["language_config"] as? [String: Any])?["languages"] as? [String], ["en"])
        let pcm = Data((0..<6_402).map { UInt8(truncatingIfNeeded: $0) })
        session.sendAudio(pcm.prefix(14)); session.sendAudio(pcm.dropFirst(14))
        socket.completeSend(); socket.completeSend()
        socket.emit(#"{"type":"transcript","data":{"id":"1","is_final":true,"utterance":{"text":"Confirmed."}}}"#)
        socket.emit(#"{"type":"transcript","data":{"id":"2","is_final":false,"utterance":{"text":"draft"}}}"#)
        XCTAssertEqual(session.snapshot().text, "Confirmed. draft")
        let tail = expectation(description: "configured residual reaches native transport")
        let stop = expectation(description: "configured stop follows residual and grace")
        socket.onSend = { message in
            if case .binary(let data) = message, data.count == 1_600 { tail.fulfill() }
            if case .text(let text) = message, text == #"{"type":"stop_recording"}"# { stop.fulfill() }
        }
        let finishing = ownedFinish(session)
        try await wait(tail)
        XCTAssertEqual(socket.binary.map(\.count), [3_200, 3_200, 1_600])
        let wire = socket.binary.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(wire.prefix(pcm.count), pcm)
        XCTAssertEqual(wire.dropFirst(pcm.count), Data(repeating: 0, count: 1_598))
        socket.completeSend()
        try await wait(stop)
        socket.completeSend()
        socket.emit(#"{"type":"end_session"}"#)
        try await wait(finishing.done)
        let result = await finishing.task.value
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.text, "Confirmed. draft", "Desktop retains the authoritative rich display")
        XCTAssertNil(result.error)
        XCTAssertEqual(socket.controls, [#"{"type":"stop_recording"}"#])
    }

    func testExistingDesktopConfigurationKeepsGraceRangeAndDefaultBeforeFactoryConsumption() throws {
        XCTAssertEqual(try DesktopConfiguration().liveOptions.stopGracePeriod, 0)
        for invalid in [-1.0, 2.1, .nan, .infinity] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [
                "liveStopGracePeriod": AnyCodable(.double(invalid))
            ]))
        }
        let options = try DesktopConfiguration(values: ["liveStopGracePeriod": AnyCodable(.double(2))]).liveOptions
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: "gladia/solaria-1-streaming", apiKey: "synthetic", language: nil, azureEndpoint: "",
            options: options, makeConnection: { _ in
                XCTFail("Pure construction opened a socket")
                return AssemblyAITestSocket()
            }
        ))
        XCTAssertEqual(client.finalisationBudget, 6.5)
    }

    private struct Finish {
        let task: Task<DesktopLiveSession.Snapshot, Never>
        let done: XCTestExpectation
    }
    private func ownedFinish(_ session: DesktopLiveSession) -> Finish {
        let done = XCTestExpectation(description: "desktop session finish returned")
        let exited = XCTestExpectation(description: "owned desktop finish exited")
        let task = Task {
            defer { exited.fulfill() }
            let result = await session.finish()
            done.fulfill()
            return result
        }
        addTeardownBlock {
            task.cancel(); session.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Finish(task: task, done: done)
    }

    private func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned desktop Gladia phase did not settle")
            throw GladiaDesktopTimeout()
        }
    }
}

private struct GladiaDesktopTimeout: Error {}
private final class GladiaDesktopRequest: GladiaLiveSessionRequest { func cancel() {} }
private final class GladiaDesktopInitiation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    var initiator: GladiaLiveClient.SessionInitiator {
        { [self] request, completion in
            lock.withLock { stored.append(request) }
            completion(.success((201, Data(#"{"url":"wss://api.gladia.io/v2/live?token=synthetic"}"#.utf8))))
            return GladiaDesktopRequest()
        }
    }
}
