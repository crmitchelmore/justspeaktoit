import Foundation
import XCTest
@testable import SpeakiOSLib

final class SharedTranscriptionStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SharedTranscriptionStateTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLaunchReset_clearsLegacyRecordingFlagWithoutTimestamp() {
        defaults.set(true, forKey: "isRecording")
        let state = SharedTranscriptionState(defaults: defaults)
        XCTAssertTrue(state.isRecording)

        state.clearRecordingState()

        let relaunchedReader = SharedTranscriptionState(defaults: defaults)
        XCTAssertFalse(relaunchedReader.isRecording)
        XCTAssertNil(relaunchedReader.recordingStartTime)
    }

    func testLaunchReset_preservesTranscriptsHistoryMarkersAndPreferences() {
        let previousProcess = SharedTranscriptionState(defaults: defaults)
        previousProcess.isRecording = true
        previousProcess.recordingStartTime = Date(timeIntervalSince1970: 100)
        previousProcess.updateTranscript("An interrupted partial transcript.")
        previousProcess.lastCompletedTranscript = "A completed background transcript."
        defaults.set("historyOnly", forKey: "actionButtonResultDestination")
        defaults.set(Data([1, 2, 3]), forKey: "history")
        let completedAt = previousProcess.lastCompletedAt
        var expected = defaults.dictionaryRepresentation()
        expected["isRecording"] = false
        expected.removeValue(forKey: "recordingStartTime")

        let newProcess = SharedTranscriptionState(defaults: defaults)
        newProcess.clearRecordingState()

        XCTAssertFalse(newProcess.isRecording)
        XCTAssertNil(newProcess.recordingStartTime)
        XCTAssertEqual(newProcess.currentTranscriptText, "An interrupted partial transcript.")
        XCTAssertEqual(newProcess.lastTranscribedSentence, "An interrupted partial transcript")
        XCTAssertEqual(newProcess.lastCompletedTranscript, "A completed background transcript.")
        XCTAssertEqual(newProcess.lastCompletedAt, completedAt)
        XCTAssertTrue(newProcess.hasUnseenBackgroundTranscript)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, expected as NSDictionary)
    }

    func testLaunchReset_isIdempotent() {
        let state = SharedTranscriptionState(defaults: defaults)
        state.isRecording = true
        state.recordingStartTime = Date()
        state.clearRecordingState()
        let firstReset = defaults.dictionaryRepresentation() as NSDictionary

        state.clearRecordingState()

        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, firstReset)
    }

    func testNewReader_afterForegroundRecordingStartsDoesNotClearLiveState() {
        let foregroundOwner = SharedTranscriptionState(defaults: defaults)
        foregroundOwner.clearRecordingState()
        let start = Date(timeIntervalSince1970: 200)
        foregroundOwner.isRecording = true
        foregroundOwner.recordingStartTime = start
        foregroundOwner.updateTranscript("Live foreground words")

        // Later access by an intent or service is not a new app-process launch.
        let laterReader = SharedTranscriptionState(defaults: defaults)

        XCTAssertTrue(laterReader.isRecording)
        XCTAssertEqual(laterReader.recordingStartTime, start)
        XCTAssertEqual(laterReader.currentTranscriptText, "Live foreground words")
        XCTAssertTrue(foregroundOwner.isRecording)
    }

    func testRecordingTransitions_publishBeforeTargetedReloadForEitherOwner() throws {
        let readerDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reader = SharedTranscriptionState(defaults: readerDefaults)
        var observedFlags: [Bool] = []
        let reload: (String) -> Void = { kind in
            XCTAssertEqual(kind, "com.justspeaktoit.ios.JustSpeakToItWidgetExtension")
            observedFlags.append(reader.isRecording)
            if !reader.isRecording { XCTAssertNil(reader.recordingStartTime) }
        }
        let foregroundOwner = SharedTranscriptionState(defaults: defaults, reloadRecordingControl: reload)
        let headlessOwner = SharedTranscriptionState(defaults: readerDefaults, reloadRecordingControl: reload)

        foregroundOwner.isRecording = true
        foregroundOwner.recordingStartTime = Date()
        foregroundOwner.clearRecordingState()
        headlessOwner.isRecording = true
        headlessOwner.recordingStartTime = Date()
        headlessOwner.clearRecordingState()

        XCTAssertEqual(observedFlags, [true, false, true, false])
    }

    func testUnchangedFlagsAndTranscriptUpdates_doNotReload() {
        var reloads = 0
        let state = SharedTranscriptionState(defaults: defaults, reloadRecordingControl: { _ in reloads += 1 })
        state.isRecording = false
        state.clearRecordingState()
        XCTAssertEqual(reloads, 0)

        state.isRecording = true
        state.isRecording = true
        state.updateTranscript("Partial words.")
        state.updateTranscript("Final words.")
        state.lastCompletedTranscript = "Saved words."
        state.clear()
        XCTAssertEqual(reloads, 1)

        state.clearRecordingState()
        state.clearRecordingState()
        XCTAssertEqual(reloads, 2)
    }

    func testUnavailableStore_doesNotRequestReloadForUnpublishedState() {
        let state = SharedTranscriptionState(defaults: nil, reloadRecordingControl: { _ in
            XCTFail("No state was published")
        })
        state.isRecording = true
        state.clearRecordingState()
        XCTAssertFalse(state.isRecording)
    }
}
