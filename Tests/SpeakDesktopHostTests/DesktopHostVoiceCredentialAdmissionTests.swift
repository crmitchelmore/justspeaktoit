import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoiceKeyAdmissionTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var gate: VoiceKeyAdmissionGate!
    private var accesses: VoiceKeyAccesses!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        gate = VoiceKeyAdmissionGate()
        accesses = VoiceKeyAccesses()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-key-admission-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        await controller.selectVoiceOutput(.cartesia(CartesiaTTSCatalog.voices[0]))
        let accesses = try XCTUnwrap(accesses)
        FakeLog.shared.installKeyWriteHook { _, name in accesses.wrote(name) }
    }

    override func tearDown() async throws {
        await gate.release()
        let imported = await controller.voiceTextImportTask
        let discovery = await controller.voiceDiscovery.task
        await imported?.value
        await discovery?.value
        await controller.close()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testPausedTextImport_RefusesWritesUntilItsCancelledWorkerActuallySettles() async throws {
        let entered = expectation(description: "text import owns its worker")
        let gate = try XCTUnwrap(gate)
        await controller.importVoiceText(path: "/synthetic.txt", requestID: "held-import") { _ in
            entered.fulfill()
            await gate.wait()
            return "Synthetic file text"
        } completion: { _ in }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceTextImportTask
        await assertBusyWithoutWrites()
        await controller.cancelVoiceTextImport(requestID: "held-import")
        await assertBusyWithoutWrites()
        await gate.release()
        await task?.value
        try await assertWritableAfterSettling()
    }

    func testPausedDiscovery_RefusesWritesUntilItsClosedWorkerActuallySettles() async throws {
        let entered = expectation(description: "account discovery owns its worker")
        let gate = try XCTUnwrap(gate)
        FakeLog.shared.setKey("synthetic-list-key", name: XAITTSCatalog.credentialIdentifier)
        await controller.openVoiceDiscovery("held-discovery")
        await controller.refreshVoiceDiscovery("held-discovery") { _ in
            entered.fulfill()
            await gate.wait()
            throw CancellationError()
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceDiscovery.task
        await assertBusyWithoutWrites()
        await controller.closeVoiceDiscovery("held-discovery")
        await assertBusyWithoutWrites()
        await gate.release()
        await task?.value
        try await assertWritableAfterSettling()
    }

    func testCachedXAIInventory_UnrelatedProviderEntryReadsOnlyItsOwnCredential() async throws {
        StubURLProtocol.reset()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"{"voices":[{"voice_id":"Account-A","name":"Synthetic account voice"}]}"#.utf8))
        }
        let inventory = try await XAIAccountVoiceInventory.fetch(session: session) { "synthetic-list-key" }
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: VoiceKeyLookupEffects(accesses: accesses))
        await controller.markReadyForSelfTest()
        for voice in [
            DesktopSpeechVoice.cartesia(CartesiaTTSCatalog.voices[0]),
            .azureNeural(AzureNeuralVoiceCatalog.voices[0])
        ] {
            await controller.selectVoiceOutput(voice)
            await controller.cacheVoiceInventoryForKeyTest(inventory)
            accesses.resetReads()
            let presentation = try await controller.voiceCredentialPresentation().get()
            XCTAssertEqual(presentation.slot.identifier, voice.apiKeyIdentifier)
            XCTAssertEqual(accesses.reads, [voice.apiKeyIdentifier])
            XCTAssertTrue(presentation.canSave)
        }
    }

    private func assertBusyWithoutWrites() async {
        let presentation = await controller.voiceCredentialPresentation()
        if case .success(let view) = presentation { XCTAssertFalse(view.canSave) } else {
            XCTFail("A busy key form must still identify its selected credential")
        }
        for operation in [VoiceCredentialOperation.replace, .remove] {
            let result = await controller.saveVoiceCredential(
                operation == .remove ? "" : "synthetic-replacement", purpose: "voice-output",
                identifier: OpenAITTSCatalog.credentialIdentifier, operation: operation)
            if case .failure(let error) = result { XCTAssertEqual(error, .busy) } else {
                XCTFail("A vault write was admitted during another owned Voice operation")
            }
        }
        XCTAssertTrue(accesses.writes.isEmpty)
    }

    private func assertWritableAfterSettling() async throws {
        let presentation = try await controller.voiceCredentialPresentation().get()
        XCTAssertTrue(presentation.canSave)
        try await controller.saveVoiceCredential(
            "synthetic-after-settling", purpose: "voice-output",
            identifier: CartesiaTTSCatalog.credentialIdentifier).get()
        XCTAssertEqual(accesses.writes, [CartesiaTTSCatalog.credentialIdentifier])
    }
}

private extension DesktopHostController {
    func cacheVoiceInventoryForKeyTest(_ inventory: XAIAccountVoiceInventory) { voiceDiscovery.inventory = inventory }
}

private actor VoiceKeyAdmissionGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

private final class VoiceKeyAccesses: @unchecked Sendable {
    private let lock = NSLock()
    private var readNames: [String] = []
    private var writeNames: [String] = []
    var reads: [String] { lock.withLock { readNames } }
    var writes: [String] { lock.withLock { writeNames } }
    func read(_ name: String) { lock.withLock { readNames.append(name) } }
    func wrote(_ name: String) { lock.withLock { writeNames.append(name) } }
    func resetReads() { lock.withLock { readNames = [] } }
}

private struct VoiceKeyLookupEffects: DesktopHostEffects {
    typealias Platform = FakePlatform
    let accesses: VoiceKeyAccesses
    private let base = SyntheticEffects()
    func apiKey(name: String) throws -> String {
        accesses.read(name)
        if name == XAITTSCatalog.credentialIdentifier {
            throw DesktopHostError(message: "Synthetic xAI-only vault lookup failure")
        }
        return "synthetic-relevant-key"
    }
    func makeCapture(context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int)
        throws -> any DesktopRecordingCapture {
        try base.makeCapture(context: context, deviceID: deviceID,
                             sampleRate: sampleRate, frameMilliseconds: frameMilliseconds)
    }
    func makeLiveClient(model: String, key: String, language: String?, azureEndpoint: String)
        -> (any FinalizingStreamingTranscriptionClient)? {
        base.makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribe(_ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>)
        async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}
