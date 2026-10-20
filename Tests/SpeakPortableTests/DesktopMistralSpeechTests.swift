import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopMistralSpeechTests: DeepgramSpeechStubTestCase {
    private let voiceID = "019b2bd7-96e7-7219-8c0b-45a73da50088"

    func testAccountEvidence_RequiredForExactVoiceAndPinnedModelBeforeKeysOrTransport() async throws {
        let inventory = try await listed()
        let voice = try XCTUnwrap(inventory.desktopVoices.first)
        XCTAssertEqual(inventory.mistral?.context.provider, .mistral)
        let selection = try DesktopSpeechSelection(
            voice: voice, options: VoiceSynthesisOptions(), accountInventory: inventory)
        XCTAssertEqual(selection.accountInventory?.mistral?.context, inventory.mistral?.context)
        XCTAssertFalse(String(reflecting: inventory).contains("synthetic-key"))
        XCTAssertFalse(DesktopSpeechVoice.voices.contains(voice))
        XCTAssertEqual(voice.apiKeyIdentifier, try VoiceOutputCredentialSlot(provider: .mistral).identifier)
        XCTAssertEqual(voice.capabilities.nativeFlags, 0)
        XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice, accountInventory: inventory).identifier,
                       MistralTTSCatalog.credentialIdentifier)
        XCTAssertEqual(try DesktopSpeechVoice.resolved(
            modelID: voice.modelID, voiceID: voice.id, accountInventory: inventory), voice)
        for model in [nil, VoiceAccountProvider.mistral.id, MistralTTSCatalog.defaultModel.rawValue] {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(
                modelID: model, voiceID: voice.id, accountInventory: inventory), voice)
        }
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
            modelID: MistralTTSModel.voxtralMiniTTSLatest.desktopModelIdentifier,
            voiceID: voice.id, accountInventory: inventory))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
            modelID: "azure/neural", voiceID: voice.id, accountInventory: inventory))
        let forged = DesktopSpeechVoice.mistral(.init(id: voiceID, name: "Not the listed metadata"))
        let before = StubURLProtocol.recordedRequests.count
        for choice in [voice, forged] {
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source(), voice: choice, options: VoiceSynthesisOptions(),
                    accountInventory: choice == forged ? inventory : nil, credential: {
                        XCTFail("Unavailable account evidence read a key")
                        return "synthetic-key"
                    })
                XCTFail("Unavailable account evidence admitted")
            } catch {
                XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice)
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
    }

    func testUnsupportedMistralControls_RefuseBeforeKeyAndTransport() async throws {
        let inventory = try await listed()
        let before = StubURLProtocol.recordedRequests.count
        let incompatible = try [VoiceSynthesisOptions(speed: 1.1), .init(pitch: 1), .init(useSSML: true)]
        for options in incompatible {
            do {
                _ = try await synthesize(source(), inventory: inventory, options: options, key: {
                    XCTFail("Unsupported controls read a key")
                    return "synthetic-key"
                })
                XCTFail("Unsupported controls admitted")
            } catch {
                XCTAssertTrue(error is VoiceSynthesisConfigurationError)
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
    }

    func testRealRequestBoundary_UsesSharedWAVContractAndMeasuredUsageWithHistoryOrNilOwnership() async throws {
        let inventory = try await listed()
        let audio = try responseAudio()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for sourceKind in [VoiceOutputSource.typedText, .clipboard, .history] {
            let owner = UUID()
            let snapshot = try VoiceOutputSourceSnapshot(
                source: sourceKind, text: "Synthetic cafe\u{301}.", recordID: sourceKind == .history ? owner : nil)
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: sourceKind, historyRecordID: owner)
            let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(snapshot, inventory: inventory)
            }
            let generated = try VoiceGeneratedAudio(validating: wav)
            XCTAssertEqual(generated.duration, Double(pcm.count) / 48_000)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            let body = try json(request)
            XCTAssertEqual(request.url, MistralTTSAPI.speechEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertEqual(body["input"] as? String, snapshot.text)
            XCTAssertEqual(body["model"] as? String, MistralTTSCatalog.defaultModel.rawValue)
            XCTAssertEqual(body["voice_id"] as? String, voiceID)
            XCTAssertEqual(body["response_format"] as? String, "wav")
            XCTAssertNil(body["sample_rate"])
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.outcome, .completed)
            XCTAssertEqual(record.historyRecordID, sourceKind == .history ? owner : nil)
            XCTAssertEqual(record.inputCharacters, snapshot.text.unicodeScalars.count)
            XCTAssertEqual(record.audioDuration, generated.duration)
            XCTAssertEqual(record.estimatedCostUSD,
                           Decimal(snapshot.text.count) * MistralTTSAPI.estimatedCostPerThousandCharacters / 1_000)
        }
    }

    func testSegmentedSynthesis_UsesMacGuidanceAndPricesOnlySubmittedGraphemes() async throws {
        let inventory = try await listed()
        let snapshot = try VoiceOutputSourceSnapshot(
            source: .typedText, text: "  " + String(repeating: "e\u{301}", count: 1_801) + "  ")
        let chunks = TTSTextChunker.chunks(snapshot.text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= MistralTTSAPI.maxInputCharacters })
        XCTAssertEqual(chunks.joined(), snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let payload = try responseAudio()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), payload) }
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: UUID())
        let probe = MistralKeyProbe()
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(snapshot, inventory: inventory, key: { probe.supply() })
        }
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(wav.count, 44 + pcm.count * chunks.count)
        let requests = StubURLProtocol.recordedRequests.filter { $0.url == MistralTTSAPI.speechEndpoint }
        XCTAssertEqual(try requests.map { try json($0)["input"] as? String }, chunks.map(Optional.some))
        XCTAssertEqual(capture.records.map(\.inputCharacters), chunks.map { $0.unicodeScalars.count })
        XCTAssertEqual(capture.records.compactMap(\.estimatedCostUSD).reduce(Decimal.zero, +),
                       try VoiceSynthesisPricing.estimate(
                        for: XCTUnwrap(inventory.desktopVoices.first),
                        text: snapshot.text, accountInventory: inventory))
    }

    func testChangedKey_RefusesBeforeHTTPAndDoesNotFabricateUsage() async throws {
        let inventory = try await listed()
        let before = StubURLProtocol.recordedRequests.count
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: UUID())
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(self.source(), inventory: inventory, key: { "changed-key" })
            }
            XCTFail("A changed key admitted stale listing")
        } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .credentialChanged(.mistral))
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
        XCTAssertTrue(capture.records.isEmpty)
    }

    func testBadAudioAndServiceCancellation_RejectWithoutPartialPublicationOrInventedMeasurements() async throws {
        let inventory = try await listed()
        let malformed = [
            Data(#"{"audio_data":"bad"}"#.utf8),
            try responseAudio(wav: DeepgramSpeechFixture.canonicalWAV(pcm: pcm, rate: 48_000)),
            try responseAudio(wav: DeepgramSpeechFixture.canonicalWAV(pcm: pcm, channels: 2)),
            try responseAudio(wav: DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 0, count: 32)))
        ]
        for data in malformed {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
            do { _ = try await synthesize(source(), inventory: inventory); XCTFail("Invalid audio admitted") } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
            }
        }

        for status in [401, 403, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private body".utf8))
            }
            do { _ = try await synthesize(source(), inventory: inventory); XCTFail("Service error admitted") } catch {
                XCTAssertEqual(error as? DesktopMistralSpeechError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(self.source(), inventory: inventory)
            }
            XCTFail("Cancelled request admitted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(capture.records.first?.outcome, .cancelled)
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    private func listed() async throws -> VoiceAccountInventory {
        let data = try JSONSerialization.data(withJSONObject: [
            "items": [["id": voiceID, "name": "Synthetic account voice"]]
        ])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        return try await .fetch(provider: .mistral, session: session) { "synthetic-key" }
    }

    private func source() throws -> VoiceOutputSourceSnapshot {
        try .init(source: .typedText, text: "Synthetic speech.")
    }

    private func responseAudio(wav: Data? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "audio_data": (wav ?? DeepgramSpeechFixture.canonicalWAV(pcm: pcm)).base64EncodedString()
        ])
    }

    private func synthesize(
        _ snapshot: VoiceOutputSourceSnapshot, inventory: VoiceAccountInventory,
        options: VoiceSynthesisOptions? = nil,
        key: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            snapshot, voice: XCTUnwrap(inventory.desktopVoices.first), options: options ?? VoiceSynthesisOptions(),
            accountInventory: inventory, credential: key)
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }
}

private final class MistralKeyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }

    func supply() -> String {
        lock.withLock {
            reads += 1
            return reads == 1 ? "synthetic-key" : "unexpected-second-key"
        }
    }
}
