import Foundation
import XCTest
@testable import SpeakCore

final class LiveStreamWarmUpPolicyTests: XCTestCase {
    func testOnDeviceProvider_HasNothingToWarm() {
        XCTAssertNil(LiveTranscriptionProviderID.apple.streamingHost)
        XCTAssertEqual(LiveTranscriptionProviderID.apple.streamWarmUp, .unsupported)
    }

    func testEveryCloudProvider_DeclaresAHostToWarm() {
        for provider in LiveTranscriptionProviderID.allCases where provider != .apple {
            guard let host = provider.streamingHost else {
                XCTFail("\(provider.rawValue) has no streaming host declared")
                continue
            }
            XCTAssertFalse(host.isEmpty, "\(provider.rawValue) declares an empty host")
            XCTAssertEqual(
                provider.streamWarmUp,
                .endpointHandshake(host: host),
                "\(provider.rawValue) should warm its endpoint only"
            )
        }
    }

    func testBillingSensitiveProviders_AreNotPreConnected() {
        // AssemblyAI meters session duration and Deepgram drops a socket that
        // receives no audio, so neither may be held open before the hotkey.
        // Both must resolve to the credential-free endpoint handshake.
        for provider in [LiveTranscriptionProviderID.assemblyai, .deepgram, .soniox] {
            guard let host = provider.streamingHost else {
                XCTFail("\(provider.rawValue) has no streaming host declared")
                continue
            }
            XCTAssertEqual(provider.streamWarmUp, .endpointHandshake(host: host))
        }
    }
}

final class LiveStreamWarmTrackerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRequest_ReturnsTheProviderHost() {
        var tracker = LiveStreamWarmTracker()
        XCTAssertEqual(
            tracker.hostNeedingWarmUp(for: .soniox, now: self.base),
            LiveTranscriptionProviderID.soniox.streamingHost
        )
    }

    func testRequestWhileInFlight_DoesNotWarmTwice() {
        var tracker = LiveStreamWarmTracker()
        XCTAssertNotNil(tracker.hostNeedingWarmUp(for: .soniox, now: self.base))
        XCTAssertNil(tracker.hostNeedingWarmUp(for: .soniox, now: self.base))
    }

    func testWarmHost_StaysFreshUntilTheIdleTimeoutExpires() {
        var tracker = LiveStreamWarmTracker(freshness: 90)
        guard let host = tracker.hostNeedingWarmUp(for: .deepgram, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        tracker.markWarmed(host: host, at: self.base)

        XCTAssertTrue(tracker.isWarm(host: host, now: self.base.addingTimeInterval(89)))
        XCTAssertNil(tracker.hostNeedingWarmUp(for: .deepgram, now: self.base.addingTimeInterval(89)))

        XCTAssertFalse(tracker.isWarm(host: host, now: self.base.addingTimeInterval(91)))
        XCTAssertEqual(
            tracker.hostNeedingWarmUp(for: .deepgram, now: self.base.addingTimeInterval(91)),
            host
        )
    }

    func testProviderChange_WarmsTheNewHostImmediately() {
        var tracker = LiveStreamWarmTracker()
        guard let sonioxHost = tracker.hostNeedingWarmUp(for: .soniox, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        tracker.markWarmed(host: sonioxHost, at: self.base)

        XCTAssertEqual(
            tracker.hostNeedingWarmUp(for: .deepgram, now: self.base.addingTimeInterval(1)),
            LiveTranscriptionProviderID.deepgram.streamingHost
        )
    }

    func testFailedHandshake_IsRetriedOnTheNextTrigger() {
        var tracker = LiveStreamWarmTracker()
        guard let host = tracker.hostNeedingWarmUp(for: .cartesia, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        tracker.markFailed(host: host)

        XCTAssertFalse(tracker.isWarm(host: host, now: self.base))
        XCTAssertEqual(tracker.hostNeedingWarmUp(for: .cartesia, now: self.base), host)
    }

    func testDisabledOrOnDeviceProvider_ClearsWarmState() {
        var tracker = LiveStreamWarmTracker()
        guard let host = tracker.hostNeedingWarmUp(for: .gladia, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        tracker.markWarmed(host: host, at: self.base)

        XCTAssertNil(tracker.hostNeedingWarmUp(for: .gladia, now: self.base, enabled: false))
        XCTAssertFalse(tracker.isWarm(host: host, now: self.base))

        tracker.markWarmed(host: host, at: self.base)
        XCTAssertNil(tracker.hostNeedingWarmUp(for: .apple, now: self.base))
        XCTAssertFalse(tracker.isWarm(host: host, now: self.base))

        tracker.markWarmed(host: host, at: self.base)
        XCTAssertNil(tracker.hostNeedingWarmUp(for: nil, now: self.base))
        XCTAssertFalse(tracker.isWarm(host: host, now: self.base))
    }

    func testInvalidate_ForgetsTheWarmHost() {
        var tracker = LiveStreamWarmTracker()
        guard let host = tracker.hostNeedingWarmUp(for: .xai, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        tracker.markWarmed(host: host, at: self.base)
        tracker.invalidate()

        XCTAssertFalse(tracker.isWarm(host: host, now: self.base))
        XCTAssertEqual(tracker.hostNeedingWarmUp(for: .xai, now: self.base), host)
    }
}
