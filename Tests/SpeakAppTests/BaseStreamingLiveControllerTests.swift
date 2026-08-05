import XCTest
@testable import SpeakApp
import SpeakCore

final class BaseStreamingLiveControllerTests: XCTestCase {
    func testEnqueueAndFlushSendsAllChunksWithinTimeout() async {
        let controller = BaseStreamingLiveController(providerID: "test", logCategory: "Test")
        controller.enqueueAudioChunk(Data([0x01, 0x02]))
        controller.enqueueAudioChunk(Data([0x03, 0x04]))
        var sent: [Data] = []
        let ok = await controller.flushPendingChunks(send: { data in sent.append(data) }, timeout: 1.0)
        XCTAssertTrue(ok)
        XCTAssertEqual(sent.count, 2)
        let ok2 = await controller.flushPendingChunks(send: { _ in XCTFail("should not be called") }, timeout: 0.1)
        XCTAssertTrue(ok2)
    }

    func testFlushTimeoutReturnsFalse() async {
        let controller = BaseStreamingLiveController(providerID: "test", logCategory: "Test")
        controller.enqueueAudioChunk(Data([0xAA]))
        let ok = await controller.flushPendingChunks(send: { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }, timeout: 0.1)
        XCTAssertFalse(ok)
    }

    func testStoppingStatePreventsFallback() {
        let controller = BaseStreamingLiveController(providerID: "test", logCategory: "Test")
        XCTAssertFalse(controller.isCurrentlyStopping)
        controller.markStopping()
        XCTAssertTrue(controller.isCurrentlyStopping)
        controller.resetStopping()
        XCTAssertFalse(controller.isCurrentlyStopping)
    }
}
