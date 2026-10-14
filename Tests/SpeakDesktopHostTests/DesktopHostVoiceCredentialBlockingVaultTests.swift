import Foundation
import SpeakCore
import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceCredentialVaultTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-vault-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        await controller.selectVoiceOutput(.openai(.standard, OpenAITTSCatalog.voices[0]))
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultSynchronousWrite_StaysOwnedAndExcludesRetryRemoveThroughCancellationAndCloseGrace() async throws {
        let entered = expectation(description: "default synchronous vault write entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.setKey("synthetic-old", name: "openai.tts.apiKey")
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let write = Task { await controller.saveVoiceCredential(
            "synthetic-confirmed", purpose: "voice-output", identifier: "openai.tts.apiKey") }
        await fulfillment(of: [entered], timeout: 3)
        let presentation = try await controller.voiceCredentialPresentation().get()
        XCTAssertFalse(presentation.canSave)
        let pendingID = await controller.voiceCredentialRequestID
        let requestID = try XCTUnwrap(pendingID)
        let cancel = await controller.cancelVoiceCredentialSave(requestID)
        XCTAssertTrue(cancel)
        let retry = await controller.saveVoiceCredential(
            "synthetic-retry", purpose: "voice-output", identifier: "openai.tts.apiKey")
        let remove = await controller.saveVoiceCredential(
            "", purpose: "voice-output", identifier: "openai.tts.apiKey", operation: .remove)
        XCTAssertEqual(failure(retry), .busy)
        XCTAssertEqual(failure(remove), .busy)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-old")
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked, "close waited for the blocked native write instead of its grace period")
        XCTAssertEqual(report.unfinishedOperations, 1)
        let beforeCompletion = FakeLog.shared.allStatuses
        gate.release()
        let result = await write.value
        XCTAssertEqual(failure(result), .completedWhileClosing)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-confirmed")
        let finished = await controller.activeOperations
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(FakeLog.shared.allStatuses, beforeCompletion)
    }

    func testDefaultSynchronousWrite_ReportsAnUnconfirmedPartialWriteWithoutDisclosingSecret() async throws {
        FakeLog.shared.installKeyWriteHook { value, name in
            FakeLog.shared.setKey(value, name: name)
            throw DesktopHostError(message: "Sensitive native vault failure \(value)")
        }
        let result = await controller.saveVoiceCredential(
            "synthetic-partial", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(result), .saveFailed)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-partial")
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("could not be confirmed") == true)
        XCTAssertFalse(FakeLog.shared.allStatuses.joined().contains("synthetic-partial"))
    }

    func testDefaultSynchronousRead_CoalescesNewViewsAndLeavesActorAndCloseGraceResponsive() async throws {
        let entered = expectation(description: "default synchronous key lookup entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.handleVoiceCredential(.open(UUID()))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let next = UUID()
        await controller.handleVoiceCredential(.open(next))
        let wanted = await controller.voiceCredentialReadID
        XCTAssertEqual(wanted, next)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked, "close waited for the blocked native read instead of its grace period")
        XCTAssertEqual(report.unfinishedOperations, 1)
        let beforeCompletion = FakeLog.shared.allStatuses
        gate.release()
        await pending?.value
        let finished = await controller.activeOperations
        XCTAssertEqual(finished, 0)
        let stopped = await controller.voiceCredentialReadTask
        XCTAssertNil(stopped)
        XCTAssertEqual(FakeLog.shared.allStatuses, beforeCompletion)
    }

    func testDefaultSynchronousRead_RejectsAnOutdatedSelectionAfterTheActualReadCompletes() async throws {
        let entered = expectation(description: "selection-fenced key lookup entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        let lookup = Task { await controller.voiceCredentialPresentation() }
        await fulfillment(of: [entered], timeout: 3)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        XCTAssertTrue(gate.isBlocked, "the selection change was blocked by native credential I/O")
        gate.release()
        switch await lookup.value {
        case .failure(let error): XCTAssertEqual(error, .destinationChanged)
        case .success: XCTFail("An old selection's vault lookup was published for the new voice")
        }
    }

    private func failure(_ result: Result<Void, VoiceOutputCredentialError>) -> VoiceOutputCredentialError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

private final class BlockingVoiceVaultGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var entered = false

    var isBlocked: Bool { condition.withLock { !open } }

    func wait(onEntry: @Sendable () -> Void) {
        condition.lock()
        if !entered { entered = true; onEntry() }
        while !open { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }

    func watchdog() -> Task<Void, Never> {
        Task.detached {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self.release()
        }
    }
}
