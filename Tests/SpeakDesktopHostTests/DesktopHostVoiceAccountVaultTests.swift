import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceAccountVaultTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-account-vault-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        FakeLog.shared.setKey("synthetic-mistral-key", name: MistralTTSCatalog.credentialIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testProviderRead_CoalescesOneWorkerAndCannotIssueOldSlotAcrossProviderEpochs() async throws {
        let first = await open()
        let gate = AccountVaultGate()
        let entered = expectation(description: "provider key lookup blocked")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.handleVoiceProviderCredential(.open(first, requestID: UUID()))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        let nextID = UUID()
        await controller.handleVoiceProviderCredential(.open(next, requestID: nextID))
        let wanted = await controller.voiceCredentialReadID
        XCTAssertEqual(wanted, nextID)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 1)
        let before = await controller.voiceProviderIssuedSlot
        XCTAssertNil(before)
        XCTAssertTrue(gate.isBlocked)
        gate.release()
        await pending?.value
        let replacement = await controller.voiceCredentialReadTask
        await replacement?.value
        let issued = await controller.voiceProviderIssuedSlot
        XCTAssertEqual(issued?.identifier, XAITTSCatalog.credentialIdentifier)
        let context = await controller.voiceDiscovery.context
        XCTAssertEqual(context, next)
        let settled = await controller.activeOperations
        XCTAssertEqual(settled, 0)
        let task = await controller.voiceCredentialReadTask
        XCTAssertNil(task)
    }

    func testProviderRead_CloseGraceRemainsBoundedWithoutLateSlotOrViewPublication() async throws {
        let context = await open()
        let gate = AccountVaultGate()
        let entered = expectation(description: "provider read owns blocked I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.handleVoiceProviderCredential(.open(context, requestID: UUID()))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked)
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await pending?.value
        let issued = await controller.voiceProviderIssuedSlot
        XCTAssertNil(issued)
        let after = await controller.activeOperations
        XCTAssertEqual(after, 0)
        let pendingID = await controller.voiceCredentialReadID
        XCTAssertNil(pendingID)
    }

    func testRefresh_BlockedVaultReadDoesNotBlockEpochAdmissionOrPermitOldTransportAfterClose() async throws {
        let context = await open()
        let gate = AccountVaultGate()
        let entered = expectation(description: "listing credential lookup blocked")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in
            XCTFail("Cancelled listing reached HTTP after blocked vault settled")
            throw CancellationError()
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceDiscovery.task
        await controller.closeVoiceDiscovery(context.sessionID.uuidString)
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked)
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await task?.value
        let listing = await controller.voiceDiscovery.listing
        XCTAssertNil(listing)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testParsedProviderActions_FenceForeignSessionAndLegacyEpochBeforeVaultOrTransport() async throws {
        let first = await open()
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Stale parsed account action reached the vault") }
        let foreign = VoiceAccountCredentialContext(provider: .xai, sessionID: UUID(), epoch: UUID())
        let transition = try DesktopVoiceSourceMessage(action: 118, source: -1,
            text: foreign.provider.id + "\n" + foreign.epoch.uuidString,
            record: foreign.sessionID.uuidString, path: "account-provider")
        await controller.handleVoiceDiscovery(transition)
        let legacyRefresh = try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: first.sessionID.uuidString, path: "account-refresh")
        await controller.handleVoiceDiscovery(legacyRefresh)
        let legacyChoice = try DesktopVoiceSourceMessage(action: 118, source: -1,
            text: "mistral/12345678-1234-1234-1234-123456789012",
            record: first.sessionID.uuidString, path: "account-choose")
        await controller.handleVoiceDiscovery(legacyChoice)
        let state = await controller.voiceDiscovery
        XCTAssertEqual(state.context, first)
        XCTAssertNil(state.task)
        let settings = await controller.voiceOutputSettings()
        XCTAssertNil(settings.voiceID)
        let count = await controller.activeOperations
        XCTAssertEqual(count, 0)
    }

    private func open() async -> VoiceAccountCredentialContext {
        let context = VoiceAccountCredentialContext(provider: .mistral, sessionID: UUID(), epoch: UUID())
        await controller.openVoiceDiscovery(context.sessionID.uuidString)
        await controller.selectVoiceAccountProvider(context)
        return context
    }
}

private final class AccountVaultGate: @unchecked Sendable {
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
