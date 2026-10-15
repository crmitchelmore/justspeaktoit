import AVFoundation
import Foundation
import XCTest

@testable import SpeakApp

/// An idle engine keeps the input format its node was built with. When the
/// device changes rate meanwhile, `installTap` in that format raises an
/// Objective-C exception that aborts the app (Alpha 3.2.0 crash in
/// `PrimedLiveInput.startCapturing`). A stale engine must be replaced, never tapped.
final class LiveInputStaleFormatTests: XCTestCase {

    private func format(_ sampleRate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    // MARK: - Format check

    func testTapFormatMatchesHardware_SameRateAndChannels_IsTrue() {
        XCTAssertTrue(audioInputTapFormatMatchesHardware(format(48_000, 1), hardwareFormat: format(48_000, 1)))
    }

    func testTapFormatMatchesHardware_HardwareChangedRateOrChannels_IsFalse() {
        XCTAssertFalse(audioInputTapFormatMatchesHardware(format(48_000, 1), hardwareFormat: format(24_000, 1)))
        XCTAssertFalse(audioInputTapFormatMatchesHardware(format(48_000, 2), hardwareFormat: format(48_000, 1)))
    }

    func testTapFormatMatchesHardware_UnusableHardware_IsFalse() {
        let noDevice = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false
        )!
        XCTAssertFalse(audioInputTapFormatMatchesHardware(noDevice, hardwareFormat: noDevice))
    }

    // MARK: - Primer standby fallback

    private final class FakeEngine {
        let isStale: Bool
        var discarded = false
        init(isStale: Bool) { self.isStale = isStale }
    }

    private struct StaleFormat: Error {}

    private func start(_ engine: FakeEngine) throws -> String {
        if engine.isStale { throw StaleFormat() }
        return "running"
    }

    func testStartPreferringStandby_UsableStandby_IsStartedWithoutBuilding() {
        let standby = FakeEngine(isStale: false)
        var builds = 0

        let started = PrimedLiveInput.startPreferringStandby(
            standby,
            buildEngine: { builds += 1; return FakeEngine(isStale: false) },
            start: start,
            discard: { $0.discarded = true }
        )

        XCTAssertTrue(started?.engine === standby)
        XCTAssertEqual(started?.started, "running")
        XCTAssertEqual(builds, 0)
        XCTAssertFalse(standby.discarded)
    }

    func testStartPreferringStandby_StaleStandby_IsDiscardedForAFreshEngine() {
        let standby = FakeEngine(isStale: true)
        let fresh = FakeEngine(isStale: false)
        var log: [String] = []

        let started = PrimedLiveInput.startPreferringStandby(
            standby,
            buildEngine: { log.append("build"); return fresh },
            start: start,
            discard: { engine in
                engine.discarded = true
                log.append(engine === standby ? "discardStandby" : "discardFresh")
            }
        )

        XCTAssertTrue(started?.engine === fresh)
        XCTAssertTrue(standby.discarded)
        XCTAssertEqual(log, ["discardStandby", "build"])
    }

    func testStartPreferringStandby_FreshEngineAlsoFails_ReturnsNilAndDiscardsIt() {
        let fresh = FakeEngine(isStale: true)

        let started = PrimedLiveInput.startPreferringStandby(
            nil,
            buildEngine: { fresh },
            start: start,
            discard: { $0.discarded = true }
        )

        XCTAssertNil(started)
        XCTAssertTrue(fresh.discarded)
    }

    // MARK: - Engine store hand-out

    func testMakeEngine_AdoptedEngineNoLongerMatchingHardware_IsReleasedForAFreshOne() {
        var log: [String] = []
        let primed = FakeEngine(isStale: true)
        let store = LiveInputEngineStore<FakeEngine>(
            makeEngine: { log.append("build"); return FakeEngine(isStale: false) },
            primeInput: { _ in },
            currentInputDeviceID: { 42 },
            canCapture: { $0 !== primed }
        )
        let hooks = LiveInputEngineStore<FakeEngine>.AdoptionHooks(
            willHandOut: { _ in log.append("handOut") },
            release: { _ in log.append("release") }
        )
        let token = store.beginPreparation()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: hooks)

        let engine = store.makeEngine()
        store.restore(engine)
        store.discard(token, releasingClaimed: true)

        XCTAssertFalse(engine === primed)
        XCTAssertEqual(log, ["release", "build"])
    }

    func testMakeEngine_AdoptedEngineMatchingHardware_IsHandedOut() {
        let primed = FakeEngine(isStale: false)
        let store = LiveInputEngineStore<FakeEngine>(
            makeEngine: { FakeEngine(isStale: false) },
            primeInput: { _ in },
            currentInputDeviceID: { 42 },
            canCapture: { _ in true }
        )
        let hooks = LiveInputEngineStore<FakeEngine>.AdoptionHooks(willHandOut: { _ in }, release: { _ in })
        let token = store.beginPreparation()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: hooks)

        XCTAssertTrue(store.makeEngine() === primed)
    }
}
