import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoiceDiscoveryTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset(); FakeSpeech.shared.reset(); StubURLProtocol.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-discovery-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects(),
                                                             shutdownGrace: .milliseconds(60))
        session = StubURLProtocol.makeSession()
        await controller.markReadyForSelfTest()
        FakeLog.shared.setKey("synthetic-key", name: XAITTSCatalog.credentialIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel(); StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testExplicitRefreshChooseAndGeneration_UseBoundAccountVoiceAndRealUsageWithoutHistoryOwner() async throws {
        await controller.openVoiceDiscovery("synthetic-dialog")
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        let inventory = try await listing()
        await refresh(inventory)
        await controller.chooseDiscoveredVoice("xai/Account-A", requestID: "obsolete")
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertNil(unchanged.voiceID)
        await controller.chooseDiscoveredVoice("xai/Account-A", requestID: "synthetic-dialog")
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.voiceID, "xai/Account-A")
        XCTAssertEqual(settings.pickerPresentation(inventory: inventory).labels.last,
                       inventory.desktopVoices.first?.label)
        XCTAssertEqual(settings.controlsPresentation(inventory: inventory).capabilities, 1)
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.25))
        XCTAssertTrue(saved)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap($0.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let session = try XCTUnwrap(session)
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic account voice journey.")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                xaiInventory: selection.xaiInventory, credential: credential)
        }
        let task = await controller.voiceGenerationTask
        await task?.value
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.audio.wav, wav)
        XCTAssertEqual(generated?.voice.id, "xai/Account-A")
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.first?.voiceID, "xai/Account-A")
        XCTAssertNotNil(usage?.first?.estimatedCostUSD)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let settingsBytes = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        XCTAssertFalse(try XCTUnwrap(String(data: settingsBytes, encoding: .utf8)).contains("synthetic-key"))
        FakeLog.shared.setKey("changed-key", name: XAITTSCatalog.credentialIdentifier)
        let count = StubURLProtocol.recordedRequests.count
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        let preserved = await controller.voiceOutputSettings()
        XCTAssertEqual(preserved.voiceID, "xai/Account-A")
        XCTAssertTrue(preserved.pickerPresentation.labels.last?.contains("Unavailable") == true)
    }

    func testRefreshFailureAndCredentialChange_PreserveSameKeyListingButNeverAcceptWrongKeyEvidence() async throws {
        await controller.openVoiceDiscovery("synthetic-dialog")
        let inventory = try await listing()
        await refresh(inventory)
        await controller.refreshVoiceDiscovery("synthetic-dialog") { _ in
            throw XAIAccountVoiceDiscoveryError.service(503)
        }
        await waitForDiscovery()
        let retained = await controller.currentVoiceInventory()
        XCTAssertEqual(retained, inventory)
        FakeLog.shared.setKey("changed-key", name: XAITTSCatalog.credentialIdentifier)
        await refresh(inventory)
        let refused = await controller.currentVoiceInventory()
        XCTAssertNil(refused)
        let offered = await controller.voiceDiscovery.offeredIDs
        XCTAssertEqual(offered, XAITTSCatalog.voices.map(\.providerVoiceID))
    }

    func testClosedAndReplacedDialog_RejectsLateUncooperativeListingAndEndsCountedOperation() async throws {
        await controller.openVoiceDiscovery("first")
        let inventory = try await listing()
        let gate = DiscoveryGate()
        await controller.refreshVoiceDiscovery("first") { _ in
            await gate.wait()
            return inventory
        }
        await controller.closeVoiceDiscovery("first")
        await controller.openVoiceDiscovery("replacement")
        await gate.release()
        await waitForDiscovery()
        let state = await controller.voiceDiscovery
        XCTAssertEqual(state.requestID, "replacement")
        XCTAssertNil(state.inventory)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
        await controller.chooseDiscoveredVoice("xai/Account-A", requestID: "first")
        let settings = await controller.voiceOutputSettings()
        XCTAssertNil(settings.voiceID)
    }

    func testShutdown_CountsAndBoundsUncooperativeDiscoveryWithoutLateInventoryAdmission() async throws {
        await controller.openVoiceDiscovery("closing")
        let inventory = try await listing()
        let gate = DiscoveryGate()
        await controller.refreshVoiceDiscovery("closing") { _ in
            await gate.wait()
            return inventory
        }
        let task = await controller.voiceDiscovery.task
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        await gate.release()
        await task?.value
        let state = await controller.voiceDiscovery
        XCTAssertNil(state.inventory)
        XCTAssertNil(state.requestID)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    private func listing() async throws -> XAIAccountVoiceInventory {
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap($0.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"{"voices":[{"voice_id":"Account-A","name":"Synthetic account voice"}]}"#.utf8))
        }
        return try await .fetch(session: session, credential: { "synthetic-key" })
    }

    private func refresh(_ inventory: XAIAccountVoiceInventory) async {
        await controller.refreshVoiceDiscovery("synthetic-dialog") { _ in inventory }
        await waitForDiscovery()
    }

    private func waitForDiscovery() async {
        let task = await controller.voiceDiscovery.task
        await task?.value
    }
}

private actor DiscoveryGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
