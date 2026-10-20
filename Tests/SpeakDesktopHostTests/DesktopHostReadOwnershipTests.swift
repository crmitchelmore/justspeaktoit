import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostReadOwnershipTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!
    private var context: VoiceAccountCredentialContext!
    private var voice: DesktopSpeechVoice!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("read-ownership-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        session = StubURLProtocol.makeSession()
        context = .init(provider: .mistral, sessionID: UUID(), epoch: UUID())
        FakeLog.shared.setKey("synthetic-key", name: MistralTTSCatalog.credentialIdentifier)
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"[{"id":"12345678-1234-1234-1234-123456789012","name":"Synthetic read voice"}]"#.utf8))
        }
        let inventory = try await VoiceAccountInventory.mistral(
            .fetch(session: session, context: context, credential: { "synthetic-key" }))
        voice = try XCTUnwrap(inventory.desktopVoices.first)
        await controller.openModernVoiceDiscovery(context.sessionID)
        await controller.selectVoiceAccountProvider(context)
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let listing = await controller.voiceDiscovery.task
        await listing?.value
        await controller.chooseVoiceAccountVoice(voice.id, epoch: context.epoch.uuidString)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeSpeech.shared.reset()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountRead_ProviderChangeCancelsOwnedSpeechAndSettlesOnce() async throws {
        try await assertAccountCancellation(.provider)
    }

    func testAccountRead_CredentialContextChangeCancelsOwnedSpeechAndSettlesOnce() async throws {
        try await assertAccountCancellation(.credentialContext)
    }

    func testAccountRead_DialogCloseCancelsOwnedSpeechAndSettlesOnce() async throws {
        try await assertAccountCancellation(.dialogClose)
    }

    func testAccountRead_ControllerCloseKeepsHeldWorkCountedUntilSettlement() async throws {
        try await assertAccountCancellation(.controllerClose)
    }

    func testDeepgramRead_HeldCredentialLookupLeavesHostResponsiveAndCannotPlayAfterCancel() async throws {
        let selected = try XCTUnwrap(DeepgramSpeechCatalog.fluxVoices.first)
        await controller.selectVoiceOutput(.deepgram(selected))
        FakeLog.shared.setKey("synthetic-key", name: DesktopSpeechVoice.deepgram(selected).apiKeyIdentifier)
        try await assertResponsiveCredentialRead(account: false)
    }

    func testAccountRead_HeldCredentialLookupLeavesHostResponsiveAndCannotPlayAfterCancel() async throws {
        try await assertResponsiveCredentialRead(account: true)
    }

    func testTypedRead_ReplacingClipboardCancelsOldSpeechWithoutStaleFinish() async throws {
        try await assertReplacement(first: .clipboard, second: .typedText)
    }

    func testClipboardRead_ReplacingTypedCancelsOldSpeechWithoutStaleFinish() async throws {
        try await assertReplacement(first: .typedText, second: .clipboard)
    }

    private enum Change: Equatable { case provider, credentialContext, dialogClose, controllerClose }

    private func assertAccountCancellation(_ change: Change) async throws {
        let entered = expectation(description: "account read reached synthetic playback")
        let gate = RecordingWriteGate()
        defer { gate.release() }
        let probe = ReadOwnershipPlaybackProbe(voice: voice, arrivals: [entered], gates: [gate])
        FakeSpeech.shared.setPlaybackHook { try await probe.play() }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic account read.")
        await controller.readVoiceSource(source)
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.readAloudState.task
        let task = try XCTUnwrap(pending)
        await assertWorkers(account: 1, synthesis: 1, operations: 1)
        let ticket = await controller.voiceAccountOutputTicket
        XCTAssertNotNil(ticket)
        switch change {
        case .provider, .credentialContext:
            await controller.selectVoiceAccountProvider(.init(
                provider: change == .provider ? .xai : .mistral,
                sessionID: context.sessionID, epoch: UUID()))
        case .dialogClose:
            await controller.closeVoiceDiscovery(context.sessionID.uuidString)
        case .controllerClose:
            let report = await controller.close()
            XCTAssertEqual(report.unfinishedOperations, 1)
        }
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        await assertWorkers(account: 1, synthesis: 1, operations: 1)
        let before = await controller.voiceUsage.records
        XCTAssertTrue(before?.isEmpty != false)
        let statuses = FakeLog.shared.allStatuses
        gate.release()
        await task.value
        await assertWorkers(account: 0, synthesis: 0, operations: 0)
        let owner = await controller.voiceAccountOutputTicket
        XCTAssertNil(owner)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.count, 1)
        XCTAssertEqual(usage?.first?.outcome, .cancelled)
        XCTAssertEqual(usage?.first?.operation, .read)
        XCTAssertEqual(usage?.first?.source, source.source)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    private func assertResponsiveCredentialRead(account: Bool) async throws {
        let entered = expectation(description: "synthetic credential I/O is held")
        let answered = expectation(description: "host responds while credential I/O is held")
        let gate = RecordingWriteGate()
        defer { gate.release() }
        FakeLog.shared.installKeyReadHook { _ in
            entered.fulfill()
            do { try gate.pass(timeout: 4) } catch { XCTFail("Credential gate failed: \(error)") }
        }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic held key read.")
        await controller.readVoiceSource(source)
        await fulfillment(of: [entered], timeout: 3)
        let controller = try XCTUnwrap(controller)
        let response = Task {
            let pending = await controller.readAloudState.task
            answered.fulfill()
            return pending
        }
        await fulfillment(of: [answered], timeout: 1)
        let pending = await response.value
        let task = try XCTUnwrap(pending)
        await assertWorkers(account: account ? 1 : 0, synthesis: 1, operations: 1)
        if account {
            await controller.selectVoiceAccountProvider(.init(
                provider: .mistral, sessionID: context.sessionID, epoch: UUID()))
        } else {
            await controller.playbackStop()
        }
        XCTAssertTrue(task.isCancelled)
        gate.release()
        await task.value
        await assertWorkers(account: 0, synthesis: 0, operations: 0)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "end"])
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertFalse(FakeLog.shared.allStatuses.contains("Finished reading aloud."))
    }

    private func assertReplacement(first: VoiceOutputSource, second: VoiceOutputSource) async throws {
        let selected = try XCTUnwrap(DeepgramSpeechCatalog.fluxVoices.first)
        voice = .deepgram(selected)
        await controller.selectVoiceOutput(voice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        let oldEntered = expectation(description: "old source is playing")
        let newEntered = expectation(description: "replacement source is playing")
        let oldGate = RecordingWriteGate(), newGate = RecordingWriteGate()
        defer { oldGate.release(); newGate.release() }
        let probe = ReadOwnershipPlaybackProbe(
            voice: voice, arrivals: [oldEntered, newEntered], gates: [oldGate, newGate])
        FakeSpeech.shared.setPlaybackHook { try await probe.play() }
        await controller.readVoiceSource(try .init(source: first, text: "Synthetic old source."))
        await fulfillment(of: [oldEntered], timeout: 3)
        let oldPending = await controller.readAloudState.task
        let old = try XCTUnwrap(oldPending)
        await controller.readVoiceSource(try .init(source: second, text: "Synthetic replacement source."))
        await fulfillment(of: [newEntered], timeout: 3)
        let newPending = await controller.readAloudState.task
        let newer = try XCTUnwrap(newPending)
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(newer.isCancelled)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end", "begin", "play"])
        await assertWorkers(account: 0, synthesis: 2, operations: 2)
        let speech = await controller.readAloudState.speech
        let statuses = FakeLog.shared.allStatuses
        oldGate.release()
        await old.value
        XCTAssertFalse(newer.isCancelled)
        let retained = await controller.readAloudState.speech
        XCTAssertEqual(retained, speech)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end", "begin", "play"])
        await assertWorkers(account: 0, synthesis: 1, operations: 1)
        newGate.release()
        await newer.value
        await assertWorkers(account: 0, synthesis: 0, operations: 0)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.map(\.source), [first, second])
        XCTAssertEqual(usage?.map(\.outcome), [.cancelled, .completed])
        XCTAssertEqual(Set(usage?.map(\.id) ?? []).count, 2)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end", "begin", "play", "end"])
        XCTAssertEqual(FakeLog.shared.allStatuses.filter { $0 == "Finished reading aloud." }.count, 1)
    }

    private func assertWorkers(account: Int, synthesis: Int, operations: Int) async {
        let accountWorkers = await controller.voiceAccountWorkers
        let synthesisWorkers = await controller.voiceSynthesisWorkers
        let active = await controller.activeOperations
        XCTAssertEqual(accountWorkers, account)
        XCTAssertEqual(synthesisWorkers, synthesis)
        XCTAssertEqual(active, operations)
    }
}

private actor ReadOwnershipPlaybackProbe {
    private let voice: DesktopSpeechVoice
    private let arrivals: [XCTestExpectation]
    private let gates: [RecordingWriteGate]
    private var calls = 0

    init(voice: DesktopSpeechVoice, arrivals: [XCTestExpectation], gates: [RecordingWriteGate]) {
        self.voice = voice
        self.arrivals = arrivals
        self.gates = gates
    }

    func play() async throws {
        let index = calls
        calls += 1
        guard gates.indices.contains(index), arrivals.indices.contains(index) else {
            XCTFail("An extra synthetic playback was admitted.")
            throw DesktopHostError(message: "Unexpected synthetic playback.")
        }
        // Synthetic observations exercise ledger ownership, not the provider's HTTP boundary.
        let capture = VoiceSynthesisUsage.capture
        let usage = capture?.begin(voice: voice, inputCharacters: 1, usesSSML: false)
        var outcome = VoiceSynthesisUsage.Outcome.failed
        defer { if let usage { capture?.finish(usage, outcome: outcome) } }
        arrivals[index].fulfill()
        let gate = gates[index]
        // Deliberately uncooperative playback settles only after its predicate gate opens.
        try await Task.detached { try gate.pass(timeout: 4) }.value
        outcome = Task.isCancelled ? .cancelled : .completed
    }
}
