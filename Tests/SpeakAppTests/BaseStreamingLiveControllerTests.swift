import XCTest
@testable import SpeakApp
import SpeakCore

private actor SentChunkRecorder {
    private(set) var chunks: [Data] = []

    func append(_ data: Data) {
        chunks.append(data)
    }
}

private final class BlockingSendGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }

    func unblock() {
        semaphore.signal()
    }
}

final class BaseStreamingLiveControllerTests: XCTestCase {
    func testEnqueueAndFlushSendsAllChunksWithinTimeout() async {
        let controller = BaseStreamingLiveController(providerID: "test", logCategory: "Test")
        controller.enqueueAudioChunk(Data([0x01, 0x02]))
        controller.enqueueAudioChunk(Data([0x03, 0x04]))
        let recorder = SentChunkRecorder()
        let ok = await controller.flushPendingChunks(
            send: { data in await recorder.append(data) }, timeout: 1.0)
        XCTAssertTrue(ok)
        let sent = await recorder.chunks
        XCTAssertEqual(sent, [Data([0x01, 0x02]), Data([0x03, 0x04])])
        let ok2 = await controller.flushPendingChunks(send: { _ in XCTFail("should not be called") }, timeout: 0.1)
        XCTAssertTrue(ok2)
    }

    func testFlushTimeoutReturnsWhileSendIgnoresCancellation() async {
        let controller = BaseStreamingLiveController(providerID: "test", logCategory: "Test")
        controller.enqueueAudioChunk(Data([0xAA]))
        let gate = BlockingSendGate()
        let clock = ContinuousClock()
        let started = clock.now
        let ok = await controller.flushPendingChunks(
            send: { _ in await gate.wait() }, timeout: 0.05)
        let elapsed = started.duration(to: clock.now)

        XCTAssertFalse(ok)
        XCTAssertLessThan(elapsed, .milliseconds(300))
        gate.unblock()
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
