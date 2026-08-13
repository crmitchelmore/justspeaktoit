import Foundation
import XCTest
@testable import SpeakCore

final class LiveStreamWarmUpPolicyTests: XCTestCase {
    func testOnDeviceProvider_HasNothingToWarm() {
        XCTAssertNil(LiveTranscriptionProviderID.apple.streamingHost)
        XCTAssertEqual(LiveTranscriptionProviderID.apple.streamWarmUp, .unsupported)
    }

    func testEveryCloudProvider_DeclaresAStreamingHost() {
        for provider in LiveTranscriptionProviderID.allCases where provider != .apple {
            guard let host = provider.streamingHost else {
                XCTFail("\(provider.rawValue) has no streaming host declared")
                continue
            }
            XCTAssertFalse(host.isEmpty, "\(provider.rawValue) declares an empty host")
        }
    }

    func testSharedSessionProviders_UseCredentialFreeEndpointProbe() {
        let providers: [LiveTranscriptionProviderID] = [
            .deepgram, .cartesia, .gladia, .modulate, .soniox, .elevenlabs,
            .speechmatics, .xai
        ]
        for provider in providers {
            guard let host = provider.streamingHost else {
                XCTFail("\(provider.rawValue) has no streaming host declared")
                continue
            }
            XCTAssertEqual(provider.streamWarmUp, .endpointProbe(host: host))
        }
    }

    func testDedicatedSessionProviders_AreNotClaimedAsTransportWarm() {
        XCTAssertEqual(LiveTranscriptionProviderID.assemblyai.streamWarmUp, .unsupported)
        XCTAssertEqual(LiveTranscriptionProviderID.openai.streamWarmUp, .unsupported)
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

    func testCompletedProbe_ExposesRefreshDeadlineForIdleScheduling() {
        var tracker = LiveStreamWarmTracker(freshness: 90)
        guard let host = tracker.hostNeedingWarmUp(for: .deepgram, now: self.base) else {
            return XCTFail("expected a host to warm")
        }
        XCTAssertTrue(tracker.markWarmed(host: host, at: self.base))

        XCTAssertEqual(
            tracker.refreshDeadline(for: .deepgram),
            self.base.addingTimeInterval(90)
        )
        XCTAssertNil(tracker.refreshDeadline(for: .deepgram, enabled: false))
    }

    func testStaleProbeCompletion_DoesNotOverwriteCurrentProviderState() {
        var tracker = LiveStreamWarmTracker()
        guard let oldHost = tracker.hostNeedingWarmUp(for: .soniox, now: self.base) else {
            return XCTFail("expected the original host")
        }
        guard let currentHost = tracker.hostNeedingWarmUp(for: .deepgram, now: self.base) else {
            return XCTFail("expected the replacement host")
        }

        XCTAssertFalse(tracker.markWarmed(host: oldHost, at: self.base))
        XCTAssertTrue(tracker.markWarmed(host: currentHost, at: self.base))
        XCTAssertTrue(tracker.isWarm(host: currentHost, now: self.base))
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

    func testFailedProbe_IsRetriedOnTheNextTrigger() {
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
