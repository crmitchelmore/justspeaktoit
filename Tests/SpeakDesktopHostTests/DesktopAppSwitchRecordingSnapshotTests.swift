import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

@MainActor
final class DesktopAppSwitchRecordingSnapshotTests: XCTestCase {
    func testHeldRealRecordingAndOutputJobRetainAdmittedPolicyAfterSettingsChange() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let index = fixture.batchIndex
        await host.recordingEventFixtureOutput(FakeTextOutput(appSwitchDelivery: .originalApp))
        let event = Task { await host.captureRecordingEvent(modelIndex: index, executablePath: nil) }
        let captured = await event.value
        XCTAssertEqual(captured.textOutput.appSwitchDelivery, .originalApp)
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        await host.recordingEventFixtureOutput(FakeTextOutput(appSwitchDelivery: .currentApp))
        await native.adopt()
        let recording = await host.recording
        XCTAssertEqual(try XCTUnwrap(recording).textOutput.appSwitchDelivery, .originalApp)
        await native.finish()
        let delivery = await host.outputSlot.task
        await delivery?.value
        XCTAssertEqual(fixture.effects.outputJobs.count, 1)
        XCTAssertEqual(fixture.effects.outputJobs.first?.appSwitchDelivery, .originalApp)
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "event-field")
        let later = await host.captureRecordingEvent(modelIndex: index, executablePath: nil)
        XCTAssertEqual(later.textOutput.appSwitchDelivery, .currentApp)
    }
}
