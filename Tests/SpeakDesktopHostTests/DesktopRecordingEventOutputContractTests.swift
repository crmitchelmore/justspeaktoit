import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopRecordingEventOutputContractTests: XCTestCase {
    func testHeldLegacyDelivery_UsesCapturedSavedOutputInsteadOfLaterSettingsOrPlatformDefault() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let index = fixture.batchIndex
        let defaultEvent = await captureEventRequiringOnlyDefaultTextOutput(host, modelIndex: index)
        XCTAssertEqual(defaultEvent.textOutput, FakePlatform.defaultTextOutput)
        let queue = DesktopSettingsQueue()
        await queue.submit { await host.recordingEventFixtureOutput(FakeTextOutput(label: "event-output")) }.value
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: nil) }
        let captured = await event.value
        XCTAssertEqual(captured.textOutput.label, "event-output")
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        await queue.submit { await host.recordingEventFixtureOutput(FakeTextOutput(label: "later-output")) }.value
        let later = await host.captureRecordingEvent(modelIndex: index, executablePath: nil)
        XCTAssertEqual(later.textOutput.label, "later-output")
        await native.adopt()
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        XCTAssertEqual(active.textOutput, captured.textOutput)
        XCTAssertEqual(active.target, "event-field")
        XCTAssertTrue(fixture.effects.outputJobs.isEmpty)
        await native.finish()
        let delivery = await host.outputSlot.task
        await delivery?.value
        XCTAssertEqual(fixture.effects.outputJobs.count, 1)
        XCTAssertEqual(fixture.effects.outputJobs.first?.label, "event-output")
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "event-field")
        XCTAssertEqual(fixture.effects.capture?.stopCount, 1)
        XCTAssertEqual(fixture.effects.capture?.destroyCount, 1)
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.result?.text, "Batch tail transcript")
        XCTAssertNil(records.first?.failure)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
        await host.recordingEventFixtureOutput(nil)
        let cleared = await host.captureRecordingEvent(modelIndex: index, executablePath: nil)
        XCTAssertEqual(cleared.textOutput, FakePlatform.defaultTextOutput)
        XCTAssertEqual(captured.textOutput.label, "event-output")
        XCTAssertEqual(defaultEvent.textOutput, FakePlatform.defaultTextOutput)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func recordingEventFixtureOutput(_ options: FakeTextOutput?) { settings.textOutput = options }
}

/// Proves captureRecordingEvent only needs default-text-output, not automation
/// consent, by calling it through a generic helper constrained to that protocol alone.
@MainActor
private func captureEventRequiringOnlyDefaultTextOutput<Platform: DesktopHostDefaultTextOutputPlatform>(
    _ host: DesktopHostController<Platform>, modelIndex: Int?
) async -> DesktopHostRecordingEvent<Platform> {
    await host.captureRecordingEvent(modelIndex: modelIndex, executablePath: nil)
}
