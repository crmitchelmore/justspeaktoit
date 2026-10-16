import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostHandsFreeDeliveryTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: TailEffects!
    private var index = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)")
        effects = TailEffects()
        controller = try DesktopHostController(directory: directory, effects: effects, shutdownGrace: .milliseconds(50))
        await controller.markReadyForSelfTest()
        index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil })
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[index].id))
        FakeLog.shared.setKey("synthetic", name: provider.apiKeyIdentifier)
        let configuration = try DesktopConfiguration(values: [
            "handsFreeDictationEnabled": AnyCodable(.bool(true)),
            "silenceDuration": AnyCodable(.double(0.5)),
            "postRecordingTailDuration": AnyCodable(.double(0))
        ])
        try await controller.saveConfiguration(configuration.entries)
    }

    override func tearDown() async throws {
        effects.targetGate.release()
        effects.transcriptionGate.release()
        effects.outputGate.release()
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func shortcut(copy: Bool = false) async {
        await controller.shortcut(.init(
            input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
            target: "arming-field", targetExecutablePath: nil,
            textOutput: Task { FakeTextOutput(label: copy ? "copy" : "default") }, modelIndex: index, deviceID: ""
        ))
    }

    private func emit(_ sample: Int16, frames: Int = 1) throws {
        let capture = try XCTUnwrap(effects.capture)
        for _ in 0..<frames {
            [Int16](repeating: sample, count: 1_600).withUnsafeBufferPointer {
                capture.context.receive($0.baseAddress!, count: $0.count)
            }
        }
    }

    private func wait(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Delivery lifecycle condition timed out.")
        throw DesktopHostError(message: "Delivery lifecycle condition timed out.")
    }

    private func utterance() async throws {
        try emit(2_000)
        // Wait for the utterance sink, not just the machine's speech-start transition.
        try await wait { await self.controller.recording != nil }
        try emit(0, frames: 8)
    }

    func testEachUtteranceCapturesFreshTarget_AndRetainsItAcrossTranscription() async throws {
        await shortcut()
        effects.target = "first-field"
        effects.transcriptionGate.hold()
        try await utterance()
        try await wait { !self.effects.transcriptions.isEmpty }
        effects.target = "second-field"
        effects.transcriptionGate.release()
        try await wait { await self.controller.handsFreeState() == .armed && self.effects.outputCount == 1 }
        XCTAssertEqual(effects.outputJobs.map(\.target), ["first-field"])
        try await utterance()
        try await wait { await self.controller.handsFreeState() == .armed && self.effects.outputCount == 2 }
        XCTAssertEqual(effects.outputJobs.map(\.target), ["first-field", "second-field"])
        XCTAssertEqual(effects.targetRequestCount, 2)
    }

    func testUnconfirmedInsertion_DisarmsWithoutRetryAndRetainsTranscript() async throws {
        effects.delivery = DesktopTextOutputResult(.unconfirmedInsertion, status: "Keys sent, not confirmed.")
        await shortcut()
        try await utterance()
        try await wait { await self.controller.handsFreeState() == .off }
        let records = try await controller.store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayText, "Batch tail transcript")
        XCTAssertEqual(effects.outputCount, 1)
        XCTAssertEqual(effects.capture?.stopCount, 1)
        try emit(2_000)
        XCTAssertEqual(effects.outputCount, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Check the original field") == true)
    }

    func testFailedAndRecoveryCopyDelivery_DoNotPermitAutomaticResume() {
        for disposition in [
            DesktopTextOutputResult.Disposition.failed, .cancelled, .recoveryCopy, .unconfirmedInsertion
        ] {
            XCTAssertFalse(DesktopTextOutputResult(disposition, status: "Delivered.").permitsAutomaticResume)
        }
    }

    func testFailedOutput_DisarmsAndRetainsTheCompletedTranscript() async throws {
        try await refusesResume(.failed)
    }

    func testFallbackCopy_DisarmsInsteadOfAcknowledgingRequestedInsertion() async throws {
        try await refusesResume(.recoveryCopy)
    }

    private func refusesResume(_ disposition: DesktopTextOutputResult.Disposition) async throws {
        effects.delivery = DesktopTextOutputResult(disposition, status: "Synthetic output refusal.")
        await shortcut()
        try await utterance()
        try await wait { await self.controller.handsFreeState() == .off }
        let records = try await controller.store.records()
        XCTAssertEqual(records.first?.displayText, "Batch tail transcript")
        XCTAssertEqual(effects.outputCount, 1)
    }

    func testDisarmWhileOutputPending_RejectsLateSuccessAndDoesNotRearm() async throws {
        effects.outputGate.hold()
        await shortcut()
        try await utterance()
        try await wait { self.effects.outputCount == 1 }
        await shortcut()
        effects.outputGate.release()
        try await Task.sleep(for: .milliseconds(20))
        let state = await controller.handsFreeState()
        XCTAssertEqual(state, .off)
        XCTAssertEqual(effects.outputCount, 1)
        XCTAssertEqual(effects.capture?.stopCount, 1)
        let records = try await controller.store.records()
        XCTAssertEqual(records.first?.displayText, "Batch tail transcript")
    }

    func testExplicitClipboardCopy_RearmsWithoutCapturingAField() async throws {
        effects.target = nil
        effects.delivery = DesktopTextOutputResult(.copied, status: "Copied.")
        await shortcut(copy: true)
        try await utterance()
        try await wait { await self.controller.handsFreeState() == .armed && self.effects.outputCount == 1 }
        XCTAssertEqual(effects.targetRequestCount, 0)
        XCTAssertNil(effects.outputJobs.first?.target)
    }

    func testMissingTarget_DisarmsWithoutStartingProviderOrCreatingHistory() async throws {
        effects.target = nil
        await shortcut()
        try emit(2_000)
        try await wait { await self.controller.handsFreeState() == .off }
        let records = try await controller.store.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        XCTAssertEqual(effects.outputCount, 0)
    }

    func testCloseDuringTargetCapture_RejectsLateCaptureAndOutput() async throws {
        effects.targetGate.hold()
        await shortcut()
        try emit(2_000)
        try await wait { self.effects.targetRequestCount == 1 }
        await controller.close()
        effects.targetGate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(effects.outputCount, 0)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        XCTAssertEqual(effects.capture?.stopCount, 1)
    }
}
