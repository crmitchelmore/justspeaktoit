import XCTest

@testable import SpeakApp

final class TTSProgressivePlaybackStateTests: XCTestCase {
    func testBoundedQueueReservesIncomingFramesAndNeverExceedsTenSeconds() throws {
        var state = TTSProgressivePlaybackState()
        let owner = try state.begin(sampleRate: 24_000, mode: .bounded)
        for _ in 0..<99 { try state.reserve(frames: 2400, owner: owner) }
        try state.reserve(frames: 1200, owner: owner)
        XCTAssertEqual(state.scheduledFrames, 238_800)
        XCTAssertFalse(try state.hasHeadroom(for: 2400, owner: owner))
        XCTAssertThrowsError(try state.reserve(frames: 2400, owner: owner)) {
            XCTAssertEqual($0 as? TTSProgressivePlaybackState.Failure, .queueFull)
        }
        XCTAssertEqual(state.scheduledFrames, 238_800, "Refused admission must not change the actual player's counters")
        try state.reserve(frames: 1200, owner: owner)
        XCTAssertEqual(state.scheduledSeconds, 10)
        XCTAssertThrowsError(try state.reserve(frames: 1, owner: owner))
        XCTAssertEqual(state.scheduledFrames, 240_000)
    }

    func testStaleCompletionCannotReleaseReplacementHeadroomOrDrainIt() throws {
        var state = TTSProgressivePlaybackState()
        let old = try state.begin(sampleRate: 24_000, mode: .bounded)
        try state.reserve(frames: 2400, owner: old)
        let replacement = try state.begin(sampleRate: 24_000, mode: .bounded)
        try state.reserve(frames: 1200, owner: replacement)
        XCTAssertFalse(state.complete(frames: 2400, owner: old))
        XCTAssertEqual(state.scheduledFrames, 1200)
        XCTAssertEqual(state.scheduledBuffers, 1)
        XCTAssertThrowsError(try state.requireCurrent(old)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(state.complete(frames: 1200, owner: replacement))
        XCTAssertEqual(state.scheduledFrames, 0)
    }

    func testStopInvalidatesOwnerAndResetsPendingFramesBeforeNewRun() throws {
        var state = TTSProgressivePlaybackState()
        let owner = try state.begin(sampleRate: 24_000, mode: .bounded)
        try state.reserve(frames: 2400, owner: owner)
        state.stop()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.scheduledFrames, 0)
        XCTAssertEqual(state.scheduledBuffers, 0)
        XCTAssertThrowsError(try state.reserve(frames: 2400, owner: owner)) { XCTAssertTrue($0 is CancellationError) }
        let next = try state.begin(sampleRate: 24_000, mode: .bounded)
        XCTAssertNotEqual(owner, next)
        XCTAssertFalse(state.complete(frames: 2400, owner: owner))
        try state.requireCurrent(next)
    }

    func testStrictChunkRefusalDoesNotMutateBudget() throws {
        var state = TTSProgressivePlaybackState()
        let owner = try state.begin(sampleRate: 24_000, mode: .bounded)
        for invalid in [0, -1, 2401] {
            XCTAssertThrowsError(try state.reserve(frames: invalid, owner: owner)) {
                XCTAssertEqual($0 as? TTSProgressivePlaybackState.Failure, .invalidChunk)
            }
        }
        XCTAssertEqual(state.scheduledFrames, 0)
        XCTAssertEqual(state.scheduledBuffers, 0)
        XCTAssertThrowsError(try state.begin(sampleRate: 0, mode: .bounded))
        XCTAssertThrowsError(try state.begin(sampleRate: Int.max, mode: .bounded))
    }

    func testLegacyReservationRetainsLargerChunkAndUnboundedQueueSemantics() throws {
        var state = TTSProgressivePlaybackState()
        let owner = try state.begin(sampleRate: 24_000, mode: .legacy)
        try state.reserve(frames: 480_000, owner: owner)
        XCTAssertEqual(state.scheduledSeconds, 20)
        XCTAssertEqual(state.scheduledBuffers, 1)
        XCTAssertTrue(state.complete(frames: 480_000, owner: owner))
    }

    func testCurrentRunDrainsOnlyAfterAllOfItsBuffersComplete() throws {
        var state = TTSProgressivePlaybackState()
        let owner = try state.begin(sampleRate: 24_000, mode: .bounded)
        try state.reserve(frames: 1200, owner: owner)
        try state.reserve(frames: 2400, owner: owner)
        XCTAssertFalse(state.complete(frames: 1200, owner: owner))
        XCTAssertEqual(state.scheduledFrames, 2400)
        XCTAssertEqual(state.scheduledBuffers, 1)
        XCTAssertTrue(state.complete(frames: 2400, owner: owner))
        XCTAssertEqual(state.scheduledFrames, 0)
    }
}
