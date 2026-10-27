#if os(iOS)
import AVFoundation
import Foundation
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterIOSProgressivePlaybackTests: XCTestCase {
    func testNativeBufferConvertsPCM16LittleEndianToStandardFloatWithoutChangingFrames() throws {
        let pcm = Data([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0x01, 0x00, 0x00, 0xff])
        let buffer = try OpenRouterIOSProgressivePlayback.nativeBuffer(for: pcm)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.frameLength, 5)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: samples, count: 5)), [
            -1, 0, Float(32_767) / 32_768, Float(1) / 32_768, Float(-256) / 32_768
        ])
        for malformed in [Data(), Data([0]), Data(count: 4_802)] {
            XCTAssertThrowsError(try OpenRouterIOSProgressivePlayback.nativeBuffer(for: malformed))
        }
    }

    func testReservesBeforeSchedulingAndRejectsEleventhSecondAfterFiveSecondHeadroomWait() async throws {
        let fixture = ProgressivePlaybackFixture()
        let player = fixture.player()
        let owner = try player.start()
        fixture.scheduled = { XCTAssertGreaterThanOrEqual(player.queuedFrames, 2_400) }
        for _ in 0..<100 { try await player.enqueue(fixture.chunk, session: owner) }
        XCTAssertEqual(player.queuedFrames, 240_000)
        XCTAssertEqual(fixture.buffers.count, 100)
        do {
            try await player.enqueue(fixture.chunk, session: owner)
            XCTFail("A full ten-second queue must not accept another chunk")
        } catch {
            guard case OpenRouterIOSVoiceOutputError.playbackFailed = error else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(fixture.sleeps, 5)
        XCTAssertEqual(fixture.buffers.count, 100)
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertFalse(player.isActive)
    }

    func testOldBufferAndOldInterruptionCannotChangeNewGeneration() async throws {
        let inspected = expectation(description: "Actual old completion inspected")
        let fixture = ProgressivePlaybackFixture()
        fixture.inspected = { inspected.fulfill() }
        let player = fixture.player()
        let first = try player.start()
        try await player.enqueue(fixture.chunk, session: first)
        let oldCompletion = try XCTUnwrap(fixture.buffers.first)
        let second = try player.start()
        try await player.enqueue(fixture.chunk, session: second)
        oldCompletion()
        let result = await XCTWaiter.fulfillment(of: [inspected], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(player.queuedFrames, 2_400)
        player.receiveSessionEvent(
            Notification(name: AVAudioSession.mediaServicesWereResetNotification), session: first
        )
        player.stop(session: first)
        XCTAssertTrue(player.isActive)
        XCTAssertEqual(fixture.stops, 1)
        player.stop(session: second)
    }

    func testCurrentInterruptionDropsLeaseWithoutRestoringOverSystemOwner() async throws {
        let configuration = LeaseConfigurationFixture(category: .ambient)
        let fixture = ProgressivePlaybackFixture()
        fixture.acquire = { try .acquire(using: configuration.access) }
        let player = fixture.player()
        let owner = try player.start()
        XCTAssertEqual(configuration.writes.count, 1)
        player.receiveSessionEvent(Notification(name: AVAudioSession.mediaServicesWereLostNotification), session: owner)
        XCTAssertFalse(player.isActive)
        XCTAssertEqual(configuration.writes.count, 1)
        do {
            try await player.finish(session: owner)
            XCTFail("Interruption must remain observable to this generation")
        } catch {
            guard case OpenRouterIOSVoiceOutputError.interrupted = error else { return XCTFail("Wrong error") }
        }
    }

    func testDrainUsesScheduledDurationPlusFiveSecondsAndRejectsMalformedPCM() async throws {
        let fixture = ProgressivePlaybackFixture()
        let player = fixture.player()
        let owner = try player.start()
        try await player.enqueue(fixture.chunk, session: owner)
        do {
            try await player.finish(session: owner)
            XCTFail("A missing playback completion must reach its bounded drain deadline")
        } catch {
            guard case OpenRouterIOSVoiceOutputError.playbackFailed = error else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(fixture.sleeps, 6, "100ms scheduled duration plus five seconds, sampled each second")
        XCTAssertEqual(fixture.stops, 1)
        for pcm in [Data(), Data([0]), Data(count: 4_802)] {
            let next = try player.start()
            do {
                try await player.enqueue(pcm, session: next)
                XCTFail("Only nonempty aligned chunks of at most 100ms are accepted")
            } catch { XCTAssertFalse(player.isActive) }
        }
        XCTAssertEqual(fixture.buffers.count, 1)
    }

    func testCancelledQueuedStartLeavesExistingOwnedOutputUntouched() async throws {
        let returned = expectation(description: "Cancelled start returned")
        let fixture = ProgressivePlaybackFixture()
        let player = fixture.player()
        let owner = try player.start()
        try await player.enqueue(fixture.chunk, session: owner)
        let task = Task { @MainActor in
            defer { returned.fulfill() }
            do {
                _ = try player.start()
                XCTFail("Cancelled queued start must refuse before stopping")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        task.cancel()
        let result = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(player.isActive)
        XCTAssertEqual(player.queuedFrames, 2_400)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.stops, 0)
        player.stop(session: owner)
    }

    func testOldCancelledDrainCannotStopReplacementOutput() async throws {
        let draining = expectation(description: "Old drain reached actual sleep")
        let returned = expectation(description: "Old cancelled drain returned")
        let fixture = ProgressivePlaybackFixture()
        fixture.wait = { draining.fulfill(); try await Task.sleep(for: .seconds(30)) }
        let player = fixture.player()
        let first = try player.start()
        try await player.enqueue(fixture.chunk, session: first)
        let task = Task {
            defer { returned.fulfill() }
            do { try await player.finish(session: first); XCTFail("Old drain must cancel") } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        defer { task.cancel(); player.stop() }
        let entered = await XCTWaiter.fulfillment(of: [draining], timeout: 2)
        XCTAssertEqual(entered, .completed)
        let second = try player.start()
        try await player.enqueue(fixture.chunk, session: second)
        task.cancel()
        let result = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(player.isActive)
        XCTAssertEqual(player.queuedFrames, 2_400)
        XCTAssertEqual(fixture.stops, 1)
    }

    func testCompletedBufferReleasesReservationAndDrainReturnsWithoutStoppingNewGeneration() async throws {
        let inspected = expectation(description: "Owned completion inspected")
        let fixture = ProgressivePlaybackFixture()
        fixture.inspected = { inspected.fulfill() }
        let player = fixture.player()
        let owner = try player.start()
        try await player.enqueue(fixture.chunk, session: owner)
        try XCTUnwrap(fixture.buffers.first)()
        let result = await XCTWaiter.fulfillment(of: [inspected], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(player.queuedFrames, 0)
        try await player.finish(session: owner)
        XCTAssertEqual(fixture.sleeps, 0)
        let next = try player.start()
        do {
            try await player.finish(session: owner)
            XCTFail("Old drain cannot finish the new generation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(player.isActive)
        XCTAssertEqual(fixture.stops, 1)
        player.stop(session: next)
    }
}

@MainActor
private final class ProgressivePlaybackFixture {
    let chunk = Data(count: 4_800)
    var buffers: [@Sendable () -> Void] = []
    var starts = 0
    var stops = 0
    var sleeps = 0
    var instant = ContinuousClock().now
    var scheduled: () -> Void = {}
    var inspected: () -> Void = {}
    var wait: (() async throws -> Void)?
    var acquire: () throws -> OpenRouterIOSAudioSessionLease? = { nil }

    func player() -> OpenRouterIOSProgressivePlayback {
        var dependencies = OpenRouterIOSProgressivePlayback.Dependencies()
        dependencies.makeOutput = {
            .init(start: { self.starts += 1 }, schedule: { _, completion in
                self.scheduled()
                self.buffers.append(completion)
            }, stop: { self.stops += 1 })
        }
        dependencies.acquireLease = { try self.acquire() }
        dependencies.activate = {}
        dependencies.notifications = NotificationCenter()
        dependencies.now = { self.instant }
        dependencies.sleep = {
            if let wait = self.wait { try await wait(); return }
            self.sleeps += 1
            self.instant = self.instant.advanced(by: .seconds(1))
        }
        dependencies.inspectedCompletion = { self.inspected() }
        return OpenRouterIOSProgressivePlayback(dependencies: dependencies)
    }
}
#endif
