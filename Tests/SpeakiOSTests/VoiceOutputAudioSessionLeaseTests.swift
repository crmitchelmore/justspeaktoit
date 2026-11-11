#if os(iOS)
import AVFoundation
import XCTest

@testable import SpeakiOSLib

@MainActor
final class VoiceOutputAudioSessionLeaseTests: XCTestCase {
    func testRecordingRefusesAndDuplexSessionsBorrowWithoutConfigurationWrites() throws {
        for category in [AVAudioSession.Category.playAndRecord, .multiRoute, .record] {
            let state = LeaseConfigurationFixture(category: category)
            if category == .record {
                XCTAssertThrowsError(try VoiceOutputAudioSessionLease.acquire(using: state.access)) {
                    guard case VoiceOutputPlaybackError.recordingInProgress = $0 else {
                        return XCTFail("Recording must refuse playback")
                    }
                }
            } else {
                XCTAssertNil(try VoiceOutputAudioSessionLease.acquire(using: state.access))
            }
            XCTAssertTrue(state.writes.isEmpty)
        }
    }

    func testLeaseRestoresExactPreviousConfigurationOnlyWhileItsInstalledConfigurationRemains() throws {
        let state = LeaseConfigurationFixture(category: .ambient)
        let original = state.current
        let lease = try XCTUnwrap(VoiceOutputAudioSessionLease.acquire(using: state.access))
        XCTAssertEqual(state.current.category, .playback)
        XCTAssertEqual(state.current.mode, .spokenAudio)
        XCTAssertEqual(state.current.options, [.mixWithOthers])
        lease.restoreIfUnchanged()
        XCTAssertEqual(state.current, original)
        XCTAssertEqual(state.writes.count, 2)

        let second = try XCTUnwrap(VoiceOutputAudioSessionLease.acquire(using: state.access))
        let recorder = VoiceOutputAudioSessionLease.Configuration(
            category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker]
        )
        state.current = recorder
        second.restoreIfUnchanged()
        XCTAssertEqual(state.current, recorder)
        XCTAssertEqual(state.writes.count, 3, "A later recorder owns the configuration")
    }

    func testSharedInterruptionPredicateRetainsFilePlaybackPolicy() {
        let notices = [
            (Notification(name: AVAudioSession.interruptionNotification, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]), true),
            (Notification(name: AVAudioSession.interruptionNotification, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ]), false),
            (Notification(name: AVAudioSession.routeChangeNotification, userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]), true),
            (Notification(name: AVAudioSession.routeChangeNotification, userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ]), false),
            (Notification(name: AVAudioSession.mediaServicesWereLostNotification), true),
            (Notification(name: AVAudioSession.mediaServicesWereResetNotification), true)
        ]
        for (notice, expected) in notices {
            XCTAssertEqual(VoiceOutputAudioSessionLease.interruptsPlayback(notice), expected)
            XCTAssertEqual(VoiceOutputAudioPlayback.interruptsPlayback(notice), expected)
        }
    }
}

@MainActor
final class LeaseConfigurationFixture {
    var current: VoiceOutputAudioSessionLease.Configuration
    var writes: [VoiceOutputAudioSessionLease.Configuration] = []

    init(category: AVAudioSession.Category) {
        current = .init(category: category, mode: .default, options: [.mixWithOthers])
    }

    var access: VoiceOutputAudioSessionLease.Access {
        .init(configuration: { self.current }, install: {
            self.current = $0
            self.writes.append($0)
        })
    }
}
#endif
