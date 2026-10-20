import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DictationGestureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ProcessInfo.processInfo.systemUptime
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class DictationGestureDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [HotKeySessionPolicy.Input] = []
    var inputs: [HotKeySessionPolicy.Input] { lock.withLock { delivered } }
    func append(_ input: HotKeySessionPolicy.Input) { lock.withLock { delivered.append(input) } }
}

/// This is the classifier/serializer aliased by WindowsHotKeyGestures, not a
/// fixture-owned approximation of its Task tail.
@MainActor
final class OwnedDictationGestureFixture {
    let clock = DictationGestureClock()
    let deliveries = DictationGestureDeliveries()
    let gestures: DesktopHostShortcutGestures<FakePlatform>
    let fixture: OwnedDictationHostFixture

    init(_ fixture: OwnedDictationHostFixture, style: HotKeyActivationStyle = .holdToRecord) {
        self.fixture = fixture
        let clock = clock
        let deliveries = deliveries
        let host = fixture.host!
        gestures = DesktopHostShortcutGestures(
            clock: { clock.now }, armDeadline: { _ in }, executablePath: { _ in nil },
            deliver: { request in
                await host.admitShortcut(request)
                deliveries.append(request.input)
            }
        )
        gestures.configure(style: style)
    }

    func press(index: Int? = nil, output: Task<FakeTextOutput, Never>? = nil) {
        gestures.keyDown(
            target: "event-field", textOutput: output ?? Task { FakeTextOutput(label: "event-output") },
            modelIndex: index ?? fixture.batchIndex, deviceID: "event-device"
        )
    }

    func hold(index: Int? = nil, output: Task<FakeTextOutput, Never>? = nil) {
        press(index: index, output: output)
        clock.advance(1)
        gestures.deadlineReached()
    }

    func release() {
        clock.advance(0.05)
        gestures.keyUp()
    }

    func tap() {
        press()
        release()
    }
}

@MainActor
func assertFailedGestureRecording(
    _ fixture: OwnedDictationHostFixture, owner: DesktopHostOwnedDictationSession<FakePlatform>, samples: [Int16]
) async throws {
    let records = try await fixture.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertNil(records[0].result)
    XCTAssertNil(records[0].recordedDuration)
    XCTAssertTrue(records[0].failure?.contains("before capture was ready") == true)
    let audio = try await fixture.audio(records[0])
    try assertDictationWAV(audio, samples: samples)
    let completedBytes = try Data(contentsOf: audio)
    await fixture.worker.staleCallbacks()
    XCTAssertEqual(try Data(contentsOf: audio), completedBytes)
    let counts = await (fixture.worker.opens, fixture.worker.retirements, owner.finishCount)
    XCTAssertEqual(counts.0, 1)
    XCTAssertEqual(counts.1, 1)
    XCTAssertEqual(counts.2, 1)
    XCTAssertEqual(fixture.effects.live.frameCount, 0)
    XCTAssertEqual(fixture.effects.live.finishCount, 0)
    XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
    XCTAssertEqual(fixture.effects.outputCount, 0)
}
