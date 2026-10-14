import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoiceCredentialOwnerTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        CredentialOwnerReplies.shared.reset(recording: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-owner-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        await controller.selectVoiceOutput(.openai(.standard, OpenAITTSCatalog.voices[0]))
        FakeLog.shared.setKey("synthetic-openai-key", name: "openai.tts.apiKey")
        FakeLog.shared.setKey("synthetic-mistral-key", name: MistralTTSCatalog.credentialIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        CredentialOwnerReplies.shared.reset(recording: false)
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testSelectedRead_ProviderBrowseCloseReopenPreservesWorkerDestinationAndCallback() async throws {
        let context = await open()
        let epoch = await controller.voiceCredentialEpoch
        let before = await controller.voiceOutputSettings()
        let gate = CredentialOwnerGate()
        let entered = expectation(description: "selected-voice read owns blocked I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        let id = UUID()
        await controller.handleVoiceCredential(.open(id))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let task = try XCTUnwrap(pending)
        await browseCloseReopen(context)
        XCTAssertFalse(task.isCancelled)
        let owned = await controller.voiceCredentialReadWorkerDestination
        let desired = await controller.voiceCredentialReadDestination
        let pendingID = await controller.voiceCredentialReadID
        let operations = await controller.activeOperations
        XCTAssertEqual(owned, .selectedVoice(selectionEpoch: epoch))
        XCTAssertEqual(desired, owned)
        XCTAssertEqual(pendingID, id)
        XCTAssertEqual(operations, 1)
        gate.release()
        await task.value
        let reply = try XCTUnwrap(CredentialOwnerReplies.shared.result(id)).get()
        XCTAssertEqual(reply.slot.identifier, "openai.tts.apiKey")
        XCTAssertEqual(reply.selectionEpoch, epoch)
        XCTAssertTrue(reply.hasSavedKey)
        let after = await controller.voiceOutputSettings()
        let currentEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(after, before)
        XCTAssertEqual(currentEpoch, epoch)
        await assertSettled()
    }

    func testSelectedWrite_ProviderBrowseCloseReopenPreservesUncooperativeWriteAndSuccess() async throws {
        let context = await open()
        let epoch = await controller.voiceCredentialEpoch
        let before = await controller.voiceOutputSettings()
        let gate = CredentialOwnerGate()
        let entered = expectation(description: "selected-voice write owns blocked I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let controller = try XCTUnwrap(controller)
        let write = Task {
            await controller.saveVoiceCredential(
                "synthetic-confirmed", purpose: "voice-output", identifier: "openai.tts.apiKey")
        }
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialTask
        let task = try XCTUnwrap(pending)
        await browseCloseReopen(context)
        XCTAssertFalse(task.isCancelled)
        let owned = await controller.voiceCredentialWriteDestination
        let operations = await controller.activeOperations
        XCTAssertEqual(owned, .selectedVoice(selectionEpoch: epoch))
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-openai-key")
        gate.release()
        try await write.value.get()
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-confirmed")
        let after = await controller.voiceOutputSettings()
        let currentEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(after, before)
        XCTAssertEqual(currentEpoch, epoch)
        await assertSettled()
    }

    func testProviderWrite_CloseBeforeCommitCancelsOwnedWorkerAndFencesLateConfirmedWrite() async throws {
        try await providerWriteClose(committedBeforeClose: false)
    }

    func testProviderWrite_CloseAfterCommitCancelsOwnedWorkerWithoutRollbackOrRetagging() async throws {
        try await providerWriteClose(committedBeforeClose: true)
    }

    func testProviderRead_CloseClearsOldRequestWithoutRetryAfterReopen() async throws {
        let context = await open()
        let gate = CredentialOwnerGate()
        let entered = expectation(description: "provider read owns blocked I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.handleVoiceProviderCredential(.open(context, requestID: UUID()))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let task = try XCTUnwrap(pending)
        await controller.closeVoiceDiscovery(context.sessionID.uuidString)
        _ = await open()
        XCTAssertTrue(task.isCancelled)
        let desired = await controller.voiceCredentialReadDestination
        let pendingID = await controller.voiceCredentialReadID
        let owned = await controller.voiceCredentialReadWorkerDestination
        let operations = await controller.activeOperations
        XCTAssertNil(desired)
        XCTAssertNil(pendingID)
        XCTAssertEqual(owned, .explicitProvider(context))
        XCTAssertEqual(operations, 1)
        gate.release()
        await task.value
        XCTAssertEqual(gate.calls, 1)
        let slot = await controller.voiceProviderIssuedSlot
        XCTAssertNil(slot)
        await assertSettled()
    }

    func testProviderRead_ClosePreservesCoalescedSelectedRequestWithoutRetaggingOldWorker() async throws {
        let context = await open()
        let epoch = await controller.voiceCredentialEpoch
        let gate = CredentialOwnerGate()
        let entered = expectation(description: "provider read owns blocked I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyReadHook { _ in gate.wait { entered.fulfill() } }
        await controller.handleVoiceProviderCredential(.open(context, requestID: UUID()))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialReadTask
        let old = try XCTUnwrap(pending)
        let selectedID = UUID()
        await controller.handleVoiceCredential(.open(selectedID))
        await controller.closeVoiceDiscovery(context.sessionID.uuidString)
        _ = await open()
        let desired = await controller.voiceCredentialReadDestination
        let owned = await controller.voiceCredentialReadWorkerDestination
        XCTAssertEqual(desired, .selectedVoice(selectionEpoch: epoch))
        XCTAssertEqual(owned, .explicitProvider(context))
        gate.release()
        await old.value
        let replacement = await controller.voiceCredentialReadTask
        await replacement?.value
        let reply = try XCTUnwrap(CredentialOwnerReplies.shared.result(selectedID)).get()
        XCTAssertEqual(reply.slot.identifier, "openai.tts.apiKey")
        XCTAssertEqual(reply.selectionEpoch, epoch)
        XCTAssertEqual(gate.calls, 2)
        let slot = await controller.voiceProviderIssuedSlot
        XCTAssertNil(slot)
        await assertSettled()
    }

    private func providerWriteClose(committedBeforeClose: Bool) async throws {
        let context = await open()
        try await installInventory(context)
        _ = try await controller.voiceProviderCredentialPresentation(context).get()
        let gate = CredentialOwnerGate()
        let entered = expectation(description: "provider write owns uncooperative I/O")
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { key, name in
            if committedBeforeClose { FakeLog.shared.setKey(key, name: name) }
            gate.wait { entered.fulfill() }
        }
        let request = try VoiceProviderCredentialRequest(context: context, id: UUID(), purpose: "voice-output",
            identifier: MistralTTSCatalog.credentialIdentifier, operation: .replace)
        let controller = try XCTUnwrap(controller)
        let save = Task { await controller.submitOwnerKey("synthetic-late-key", request: request) }
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceCredentialTask
        let task = try XCTUnwrap(pending)
        XCTAssertEqual(FakeLog.shared.key(MistralTTSCatalog.credentialIdentifier),
            committedBeforeClose ? "synthetic-late-key" : "synthetic-mistral-key")
        await controller.closeVoiceDiscovery(context.sessionID.uuidString)
        let next = await open()
        XCTAssertTrue(task.isCancelled)
        let owned = await controller.voiceCredentialWriteDestination
        let operations = await controller.activeOperations
        XCTAssertEqual(owned, .explicitProvider(context))
        XCTAssertEqual(operations, 1)
        _ = try await controller.voiceProviderCredentialPresentation(next).get()
        let retry = try VoiceProviderCredentialRequest(context: next, id: UUID(), purpose: "voice-output",
            identifier: MistralTTSCatalog.credentialIdentifier, operation: .remove)
        if case .failure(let failure) = await controller.submitOwnerKey("", request: retry) {
            XCTAssertEqual(failure, .busy)
        } else { XCTFail("Closing provider write admitted a concurrent removal") }
        gate.release()
        if case .failure(let failure) = await save.value { XCTAssertEqual(failure, .completedWhileClosing) } else {
            XCTFail("Old provider write reported success into the reopened dialog")
        }
        XCTAssertEqual(FakeLog.shared.key(MistralTTSCatalog.credentialIdentifier), "synthetic-late-key")
        XCTAssertFalse(FakeLog.shared.allStatuses.contains { $0.contains("key saved") })
        let inventory = await controller.voiceDiscovery.inventories[.mistral]
        XCTAssertNil(inventory)
        await assertSettled()
    }

    private func open() async -> VoiceAccountCredentialContext {
        let context = VoiceAccountCredentialContext(provider: .mistral, sessionID: UUID(), epoch: UUID())
        await controller.openVoiceDiscovery(context.sessionID.uuidString)
        await controller.selectVoiceAccountProvider(context)
        return context
    }

    private func browseCloseReopen(_ context: VoiceAccountCredentialContext) async {
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: context.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        await controller.closeVoiceDiscovery(next.sessionID.uuidString)
        _ = await open()
    }

    private func installInventory(_ context: VoiceAccountCredentialContext) async throws {
        StubURLProtocol.reset()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"[{"id":"12345678-1234-1234-1234-123456789012","name":"Synthetic owned voice"}]"#.utf8))
        }
        let inventory = try await VoiceAccountInventory.mistral(
            .fetch(session: session, context: context, credential: { "synthetic-mistral-key" }))
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let task = await controller.voiceDiscovery.task
        await task?.value
        let accepted = await controller.voiceDiscovery.inventories[.mistral]
        XCTAssertEqual(accepted, inventory)
    }

    private func assertSettled() async {
        let operations = await controller.activeOperations
        let read = await controller.voiceCredentialReadTask
        let write = await controller.voiceCredentialTask
        let readOwner = await controller.voiceCredentialReadWorkerDestination
        let writeOwner = await controller.voiceCredentialWriteDestination
        XCTAssertEqual(operations, 0)
        XCTAssertNil(read)
        XCTAssertNil(write)
        XCTAssertNil(readOwner)
        XCTAssertNil(writeOwner)
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func submitOwnerKey(
        _ key: String, request: VoiceProviderCredentialRequest
    ) async -> Result<Void, VoiceOutputCredentialError> {
        await withCheckedContinuation { continuation in
            beginVoiceProviderCredentialSave(key, request: request) { continuation.resume(returning: $0) }
        }
    }
}

extension FakePlatform {
    static func voiceCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, requestID: UUID
    ) {
        CredentialOwnerReplies.shared.record(result, id: requestID)
    }
}

private final class CredentialOwnerReplies: @unchecked Sendable {
    static let shared = CredentialOwnerReplies()
    private let lock = NSLock()
    private var recording = false
    private var replies: [UUID: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>] = [:]
    func reset(recording: Bool) { lock.withLock { self.recording = recording; replies = [:] } }
    func record(_ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, id: UUID) {
        lock.withLock { if recording { replies[id] = result } }
    }
    func result(_ id: UUID) -> Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>? {
        lock.withLock { replies[id] }
    }
}

private final class CredentialOwnerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var entries = 0
    var calls: Int { condition.withLock { entries } }
    func wait(onEntry: @Sendable () -> Void) {
        condition.lock()
        entries += 1
        if entries == 1 { onEntry() }
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
