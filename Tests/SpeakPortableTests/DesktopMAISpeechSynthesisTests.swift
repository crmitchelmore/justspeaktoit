import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopMAISpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalMAIVoices_ResolveModelsWithoutDuplicatedEntriesOrProviderFallback() throws {
        let projected = DesktopSpeechVoice.voices.compactMap { voice -> AzureMAIVoice? in
            if case .azureMAI(let mai) = voice { return mai }
            return nil
        }
        XCTAssertEqual(projected, AzureMAIVoiceCatalog.voices)
        for voice in projected {
            let desktop = DesktopSpeechVoice.azureMAI(voice)
            XCTAssertEqual(desktop.modelID, voice.model.rawValue)
            XCTAssertEqual(desktop.apiKeyIdentifier, AzureSpeechConfiguration.credentialIdentifier)
            XCTAssertEqual(desktop.capabilities.nativeFlags, 4)
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: voice.id), desktop)
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: "azure/neural", voiceID: voice.id), desktop)
            XCTAssertEqual(try DesktopSpeechVoice.resolved(
                modelID: " \(voice.model.rawValue.uppercased()) ", voiceID: " \(voice.id.uppercased()) "
            ), desktop)
            let other = AzureMAIVoiceModel.allCases.first { $0 != voice.model }
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: other?.rawValue, voiceID: voice.id))
        }
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
            modelID: nil, voiceID: "azure/en-US-Unknown:MAI-Voice-2.1"
        ))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
            modelID: AzureMAIVoiceModel.voice21.rawValue, voiceID: nil
        ))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: "MAI-Voice-Unknown", voiceID: nil))
    }

    func testBothMAIModels_ExecuteCanonicalRegionalRequestsWithoutNeuralProsody() async throws {
        let audio = wav
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic MAI A & B.")
        for voice in AzureMAIVoiceCatalog.voices {
            let result = try await synthesize(source, voice: voice)
            XCTAssertEqual(result, audio)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
            XCTAssertTrue(body.contains("name='\(voice.shortName)'"), body)
            XCTAssertTrue(body.contains("Synthetic MAI A &amp; B."), body)
            XCTAssertFalse(body.contains("<prosody"), body)
            XCTAssertEqual(request.url?.host, "eastus.tts.speech.microsoft.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "synthetic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"), "riff-24khz-16bit-mono-pcm")
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, AzureMAIVoiceCatalog.voices.count)
    }

    func testMAIUnsupportedProsody_RefusesBeforeCredentialAndTransport() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic imported MAI text.")
        let probe = CredentialProbe()
        for options in [
            try VoiceSynthesisOptions(speed: 1.25), try VoiceSynthesisOptions(pitch: -2),
            try VoiceSynthesisOptions(speed: 1.25, useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options) { try await probe.supply() }
                XCTFail("Unsupported MAI prosody was silently discarded")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testMAISSML_IsUnsplitAndNeverGetsAnAutomaticProsodyWrapper() async throws {
        let audio = wav
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let fragment = "<break time='100ms'/>" + String(repeating: "Synthetic MAI sentence. ", count: 150)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: fragment)
        _ = try await synthesize(source, options: VoiceSynthesisOptions(useSSML: true))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains(fragment), body)
        XCTAssertFalse(body.contains("<prosody"), body)
    }

    func testMAILongPlainText_UsesOneCredentialAndJoinsExactAudio() async throws {
        let audio = wav
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard,
            text: String(repeating: "Synthetic MAI sentence. ", count: 180))
        let probe = CredentialProbe()
        let result = try await synthesize(source) {
            _ = try await probe.supply()
            return "synthetic-key:eastus"
        }
        let count = SpeechTextSegmenter.segments(source.text).count
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        XCTAssertEqual(result, DeepgramSpeechFixture.canonicalWAV(pcm: Data((0..<count).flatMap { _ in Array(pcm) })))
    }

    func testMAIProviderFailuresAndCancellation_NeverReturnAudioOrPrivateDiagnostics() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic MAI failure.")
        for status in [400, 401, 403, 404, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("synthetic-private-body".utf8))
            }
            do {
                _ = try await synthesize(source)
                XCTFail("Rejected MAI request produced audio")
            } catch {
                XCTAssertTrue(error is AzureSpeechError)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-body"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
            }
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await synthesize(source)
            XCTFail("Cancelled MAI request produced audio")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private var wav: Data { DeepgramSpeechFixture.canonicalWAV(pcm: pcm) }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: AzureMAIVoice = AzureMAIVoiceCatalog.voices[0],
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key:eastus" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureMAI(voice), options: options ?? VoiceSynthesisOptions(), credential: credential
        )
    }
}
