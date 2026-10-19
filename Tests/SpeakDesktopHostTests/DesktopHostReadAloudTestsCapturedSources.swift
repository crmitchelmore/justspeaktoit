import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

extension DesktopHostReadAloudTests {
    func testCapturedSources_SpeakTheirSnapshotWithoutBorrowingHistoryOwnership() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        for source in [VoiceOutputSource.externalSelection, .clipboard] {
            FakeSpeech.shared.reset(holdingSegments: true)
            await controller.readVoiceSource(source) { "Only the requested source." }
            try await waitFor("captured source playback") { FakeSpeech.shared.events.contains("play") }
            XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), ["Only the requested source."])
            let owner = await controller.voiceOutputRecordID
            let selected = await controller.selectedHistoryID
            XCTAssertNil(owner)
            XCTAssertEqual(selected, record)
            let task = await controller.readAloudState.task
            await controller.playbackStop()
            FakeSpeech.shared.releaseSegments()
            await task?.value
        }
    }

    func testClipboardShortcut_ReadsNativeEffectsRatherThanSelectedHistory() async throws {
        await controller.close()
        let effects = VoiceCommandEffects()
        effects.clipboard = "Explicit clipboard speech."
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        await controller.readClipboardAloud()
        let task = await controller.readAloudState.task
        await task?.value
        XCTAssertEqual(effects.reads, 1)
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), ["Explicit clipboard speech."])
        XCTAssertEqual(statuses.last, "Finished reading aloud.")
    }

    func testCapturedSourceStop_FinishesBeforeUncooperativeCaptureAndRejectsItsLateText() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        await controller.searchHistory("No History row is selected for this speech.")
        let entered = Gate(open: false), release = Gate(open: false), returned = Gate(open: false)
        defer { release.release() }
        await controller.readVoiceSource(.externalSelection) {
            entered.release()
            await Self.holdCapturedSource(release)
            returned.release()
            return "This late selection must not be spoken."
        }
        await entered.pass()
        let task = await controller.readAloudState.task
        await controller.playbackStop()
        await task?.value
        await controller.close()
        let status = statuses.last
        release.release()
        await returned.pass()
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertEqual(statuses.last, status)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "end"])
    }

    func testClipboardShortcut_EmptyAndNontextSourcesNeverSpeakHistory() async throws {
        await controller.close()
        let effects = VoiceCommandEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let empty: [String?] = [nil, "", " \n\t "]
        for text in empty {
            effects.clipboard = text
            await controller.readClipboardAloud()
            let task = await controller.readAloudState.task
            await task?.value
            XCTAssertTrue(statuses.last?.hasPrefix("Read aloud failed:") == true)
            XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        }
        XCTAssertEqual(effects.reads, empty.count)
    }

    func testNativeVoiceMessage_UncapturedSelectionRemainsUnavailable() {
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(
            action: 110, source: VoiceOutputSource.externalSelection.rawValue,
            text: "Clipboard text is not a captured selection.", record: "", path: ""
        ))
    }

    func testCapturedSourceReplacement_SpeaksOnlyTheNewRequest() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        let entered = Gate(open: false), release = Gate(open: false), returned = Gate(open: false)
        defer { release.release() }
        await controller.readVoiceSource(.externalSelection) {
            entered.release()
            await Self.holdCapturedSource(release)
            returned.release()
            return "Superseded selection."
        }
        await entered.pass()
        let previous = await controller.readAloudState.task
        await controller.readVoiceSource(.clipboard) { "Current clipboard." }
        let current = await controller.readAloudState.task
        await current?.value
        await previous?.value
        release.release()
        await returned.pass()
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), ["Current clipboard."])
        XCTAssertEqual(statuses.last, "Finished reading aloud.")
    }

    func testCapturedSources_RejectEmptyInvalidAndOversizedTextBeforeSynthesis() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        let invalid = ["", " \n\t ", "before\0after",
                       String(repeating: "x", count: VoiceOutputSourceSnapshot.maximumCharacters + 1)]
        for text in invalid {
            await controller.readVoiceSource(.externalSelection) { text }
            let task = await controller.readAloudState.task
            await task?.value
            XCTAssertTrue(statuses.last?.hasPrefix("Read aloud failed:") == true)
            XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        }
    }

    private static func holdCapturedSource(_ release: Gate) async {
        await withCheckedContinuation { continuation in
            Task.detached {
                await release.pass()
                continuation.resume()
            }
        }
    }
}
