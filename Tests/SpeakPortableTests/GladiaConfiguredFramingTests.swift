import Foundation
import XCTest
@testable import SpeakCore

final class GladiaConfiguredFramingTests: XCTestCase {
    func testArbitraryAlignedFragmentsProduceIdenticalFramesAndMinimalFinalPadding() async throws {
        for fragment in [2, 14, 254, 3_200, 8_000] {
            let fixture = GladiaConfiguredFixture()
            defer { fixture.client.cancel() }
            fixture.start()
            let socket = try XCTUnwrap(fixture.sockets.sockets.last)
            socket.completesSendsSynchronously = true
            let original = GladiaHarness.pcm(3, bytes: 6_602)
            var offset = 0
            while offset < original.count {
                let end = min(offset + fragment, original.count)
                fixture.client.sendAudio(original.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(socket.sentAudio.map(\.count), [3_200, 3_200])
            let finish = try await fixture.beginFinish(in: self)
            // The drain deadline is armed before the padded tail send runs.
            await waitUntil("padded final frame") { socket.sentAudio.count == 3 }
            XCTAssertEqual(socket.sentAudio.map(\.count), [3_200, 3_200, 1_600])
            let bytes = socket.sentAudio.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(bytes.prefix(original.count), original)
            XCTAssertEqual(bytes.dropFirst(original.count), Data(repeating: 0, count: 1_398))
            XCTAssertEqual(socket.sentTexts, [GladiaLiveProtocol.stopRecordingJSON])
            socket.endSession()
            let result = try await fixture.result(finish)
            XCTAssertNil(result)
            XCTAssertTrue(fixture.log.errors.isEmpty)
        }
    }

    func testSupportedRatesFrameOnlyAfterValidationAtOneHundredMilliseconds() {
        for rate in [8_000, 16_000, 32_000, 44_100, 48_000] {
            let fixture = GladiaConfiguredFixture(sampleRate: rate)
            defer { fixture.client.cancel() }
            fixture.start()
            let socket = fixture.sockets.sockets.last
            fixture.client.sendAudio(Data(repeating: 1, count: rate / 5))
            XCTAssertEqual(socket?.sentAudio.map(\.count), [rate / 5])
            XCTAssertTrue(fixture.log.errors.isEmpty)
        }
    }

    func testEmptySessionAddsNoAudioOrStopAndOddInputStillFails() async {
        let empty = GladiaConfiguredFixture()
        empty.start()
        empty.client.sendAudio(Data())
        let result = await empty.client.finishAndWait()
        XCTAssertNil(result)
        XCTAssertTrue(empty.sockets.sockets.first?.sent.isEmpty == true)
        XCTAssertTrue(empty.log.errors.isEmpty)
        let odd = GladiaConfiguredFixture()
        odd.start()
        odd.client.sendAudio(Data([1]))
        XCTAssertEqual(odd.log.errors.first as? GladiaStreamingError, .invalidPCM)
        XCTAssertTrue(odd.sockets.sockets.first?.sent.isEmpty == true)
    }

    func testTinyCallerFragmentsCountRetainedFramesRatherThanCallerChunks() throws {
        let fixture = GladiaConfiguredFixture()
        defer { fixture.client.cancel() }
        fixture.start(open: false)
        for _ in 0..<1_600 { fixture.client.sendAudio(Data([1, 2])) }
        XCTAssertEqual(fixture.client.admittedAudioBytes, 3_200)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 1)
        fixture.sessions.grant()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        socket.open()
        XCTAssertEqual(socket.sentAudio, [Data((0..<3_200).map { $0 % 2 == 0 ? 1 : 2 })])
        socket.completeSend()
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 0)
    }

    func testFiveSecondBoundIncludesResidualAndRefusesOversizedAdmissionWithoutSilentDrop() {
        let fixture = GladiaConfiguredFixture()
        fixture.start(open: false)
        fixture.client.sendAudio(Data(repeating: 1, count: 159_998))
        XCTAssertEqual(fixture.client.admittedAudioBytes, 159_998)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 50)
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.admittedAudioBytes, 160_000)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 50)
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.log.errors.first as? GladiaStreamingError, .sessionNotReady)
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 0)
        fixture.sessions.grant()
        XCTAssertTrue(fixture.sockets.sockets.isEmpty)
    }

    func testCancellationDropsResidualWithoutPublishingOrSendingItOnReplacement() throws {
        let fixture = GladiaConfiguredFixture()
        defer { fixture.client.cancel() }
        fixture.start()
        let old = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.cancel()
        XCTAssertTrue(old.sentAudio.isEmpty)
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        fixture.start()
        let next = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(2))
        XCTAssertEqual(next.sentAudio, [GladiaHarness.pcm(2)])
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }
}
