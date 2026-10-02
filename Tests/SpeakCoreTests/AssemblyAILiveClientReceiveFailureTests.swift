import Foundation
@testable import SpeakCore
import XCTest

/// ENOTCONN can be spurious around the handshake, so the client re-arms its
/// receive loop after one, but a socket that keeps failing is treated as lost
/// (pre-Begin host fallback) instead of being spun on indefinitely.
final class AssemblyAILiveClientReceiveFailureTests: XCTestCase {
    private static let notConnected = NSError(domain: NSPOSIXErrorDomain, code: 57)

    func testSpuriousNotConnectedReceiveFailureRearmsWithoutFallback() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)

        socket.failReceive(Self.notConnected)
        socket.emit(#"{"type":"Begin"}"#)
        client.sendAudio(Data(repeating: 4, count: 3_200))

        let didSendFrame = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(didSendFrame)
        XCTAssertEqual(factory.requests.count, 1)
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testPersistentNotConnectedBeforeBeginFallsBackToGlobal() async {
        let europe = TestLiveWebSocket()
        let global = TestLiveWebSocket()
        let factory = TestSocketFactory([europe, global])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStartEurope = await eventually { europe.state == .running }
        XCTAssertTrue(didStartEurope)

        for _ in 0..<400 { europe.failReceive(Self.notConnected) }

        let didStartGlobal = await eventually(timeout: 4) { global.state == .running }
        XCTAssertTrue(didStartGlobal)
        XCTAssertEqual(factory.requests.map { $0.url?.host }, [
            AssemblyAIStreamingEndpoint.europe.rawValue,
            AssemblyAIStreamingEndpoint.global.rawValue
        ])
    }

    private func makeClient(_ factory: TestSocketFactory) -> AssemblyAILiveClient {
        AssemblyAILiveClient(
            postStopFinalizeBudget: 0.05,
            stopGracePeriod: 0,
            socketFactory: factory.make
        )
    }
}
