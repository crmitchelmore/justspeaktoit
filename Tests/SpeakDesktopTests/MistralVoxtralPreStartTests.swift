import Foundation
import XCTest
@testable import SpeakCore

/// Audio offered before `start()`: held under the same frame and encoded-byte
/// bounds as a live run, carried in capture order into the next session, and
/// never evicted silently. A chunk that cannot be held is reported through that
/// start's `onError`, because there is no callback to report it to earlier.
final class MistralVoxtralPreStartTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture

    func testHeldAudioIsCarriedIntoTheSessionInCaptureOrder() {
        let fixture = Fixture()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.client.sendAudio(Data())
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 2, "Empty chunks are ignored, not held")
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.start()
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 2)
        fixture.client.sendAudio(Fixture.frame(2))
        fixture.becomeReady()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.appendedAudio, (0..<3).map { Fixture.frame($0) })
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testAnOddChunkBeforeStartIsReportedByTheNextStartAndNothingMisalignedIsSent() {
        let fixture = Fixture()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.client.sendAudio(Data([1, 2, 3]))
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0, "What was held is released with the refusal")
        fixture.start()
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.invalidPCM])
        XCTAssertTrue(fixture.factory.sockets.isEmpty, "A refused opening never opens a socket")
    }

    func testTooMuchAudioBeforeStartIsReportedInsteadOfEvictingOpeningWords() {
        let fixture = Fixture()
        let cost = MistralVoxtralLiveClient.appendFrameByteCount(pcmBytes: 3_200)
        let fit = fixture.client.maximumBufferedBytes / cost
        for index in 0..<fit { fixture.client.sendAudio(Fixture.frame(index)) }
        XCTAssertEqual(fixture.client.bufferedAudioFrames, fit, "Every opening frame is held; none is evicted")
        fixture.client.sendAudio(Fixture.frame(fit))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
        fixture.start()
        XCTAssertEqual(
            fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.overflowBeforeStart]
        )
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
    }

    func testTinyChunksBeforeStartAreBoundedByCount() {
        let fixture = Fixture()
        let limit = MistralVoxtralLiveClient.maximumBufferedFrames
        for _ in 0..<limit { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertEqual(fixture.client.bufferedAudioFrames, limit)
        fixture.client.sendAudio(Data([1, 0]))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
        fixture.start()
        XCTAssertEqual(
            fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.overflowBeforeStart]
        )
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
    }

    func testAHeldOpeningAtTheBoundsStillSharesThemWithLiveAudio() {
        let fixture = Fixture()
        let cost = MistralVoxtralLiveClient.appendFrameByteCount(pcmBytes: 3_200)
        let fit = fixture.client.maximumBufferedBytes / cost
        for index in 0..<fit { fixture.client.sendAudio(Fixture.frame(index)) }
        fixture.start()
        XCTAssertTrue(fixture.events.errors.isEmpty, "An opening within the bounds starts normally")
        XCTAssertEqual(fixture.client.bufferedAudioFrames, fit)
        fixture.client.sendAudio(Fixture.frame(fit))
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("Live audio beyond the shared bounds is a visible stall")
        }
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testStopBeforeStartReleasesHeldAudioAndItsRefusal() {
        let fixture = Fixture()
        fixture.client.sendAudio(Data([1]))
        fixture.client.stop()
        fixture.client.sendAudio(Fixture.frame(0))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0, "A stopped client holds nothing for a later start")
        fixture.start()
        XCTAssertTrue(fixture.events.errors.isEmpty, "An explicit stop discards the earlier refusal")
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
        fixture.client.cancel()
    }
}
