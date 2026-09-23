import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopPreparedProvidersTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testMetaUploadsNativeWAVAndPreservesItsModelLanguageAndTurns() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, MetaMuseVoiceTranscribe.transcribeURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
            let body = StubURLProtocol.body(of: request)
            XCTAssertNotNil(body.range(of: bytes))
            for field in ["audio/wav", "\"audioEncoding\":\"WAV\"", "\"languageBias\":[\"English\"]"] {
                XCTAssertNotNil(body.range(of: Data(field.utf8)))
            }
            XCTAssertNotNil(body.range(of: Data(MetaMuseVoiceTranscribe.modelID.utf8)))
            let response = #"""
            {"sessionId":"desktop","transcript":"Hello Meta","audioDurationMs":800,
             "turns":[{"turnId":1,"startMs":100,"endMs":800,"transcript":"Hello Meta","speaker":"1"}]}
            """#
            return .ok(Data(response.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: MetaMuseVoiceTranscribe.batchCatalogID)
        XCTAssertEqual(result.text, "Hello Meta")
        XCTAssertEqual(result.duration, 0.8)
        XCTAssertEqual(result.segments.first?.text, "Speaker 1: Hello Meta")
        XCTAssertEqual(result.segments.first?.startTime, 0.1)
        XCTAssertEqual(result.modelIdentifier, MetaMuseVoiceTranscribe.batchCatalogID)
    }

    func testAllAzureModelsPreserveRegionalCredentialsRequestAndTiming() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        for model in AzureTranscriptionModels.batchIDs.sorted() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "uksouth.api.cognitive.microsoft.com")
                XCTAssertEqual(request.url?.path, "/speechtotext/transcriptions:transcribe")
                XCTAssertEqual(request.url?.query, "api-version=2025-10-15")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "desktop-test")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = StubURLProtocol.body(of: request)
                XCTAssertNotNil(body.range(of: bytes))
                XCTAssertNotNil(body.range(of: Data("en-GB".utf8)))
                if model != AzureTranscriptionModels.fast {
                    let apiModel = model == AzureTranscriptionModels.mai2 ? "MAI-Transcribe-2" : "MAI-Transcribe-1.5"
                    XCTAssertNotNil(body.range(of: Data(apiModel.utf8)))
                } else { XCTAssertNil(body.range(of: Data("enhancedMode".utf8))) }
                return .ok(Data(Self.azureResult.utf8), url: request.url!)
            }
            let result = try await transcribe(audio, model: model, key: "desktop-test:UKSouth")
            XCTAssertEqual(result.text, "Hello Azure")
            XCTAssertEqual(result.duration, 1.5)
            XCTAssertEqual(result.segments.first?.startTime, 0.1)
            XCTAssertEqual(result.segments.first?.endTime, 0.6)
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertEqual(
                DesktopTranscription.provider(for: model)?.apiKeyIdentifier,
                AzureSpeechConfiguration.credentialIdentifier
            )
        }
    }

    func testAzureResourceEndpointIsPreservedAndUntrustedOriginsNeverReceiveAudio() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "my-resource.services.ai.azure.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "desktop-test")
            return .ok(Data(Self.azureResult.utf8), url: request.url!)
        }
        _ = try await transcribe(
            audio, model: AzureTranscriptionModels.mai2, endpoint: "https://my-resource.services.ai.azure.com"
        )
        StubURLProtocol.reset()
        let rejectedEndpoints = [
            "https://example.org", "http://my-resource.services.ai.azure.com", "https://user@x.services.ai.azure.com"
        ]
        for endpoint in rejectedEndpoints {
            do {
                _ = try await transcribe(audio, model: AzureTranscriptionModels.mai2, endpoint: endpoint)
                XCTFail("Expected endpoint validation failure")
            } catch {
                guard case AzureSpeechError.configuration = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testAcceptedUploadsCancelWithoutDeletingSourceAudio() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in [MetaMuseVoiceTranscribe.batchCatalogID, AzureTranscriptionModels.fast] {
            StubURLProtocol.reset()
            let uploaded = expectation(description: "Uploading \(model)")
            StubURLProtocol.handler = { _ in uploaded.fulfill(); return .hang }
            let task = Task { try await self.transcribe(audio, model: model) }
            await fulfillment(of: [uploaded], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }
}

private extension DesktopPreparedProvidersTests {
    static let azureResult = #"""
    {"durationMilliseconds":1500,"combinedPhrases":[{"text":"Hello Azure"}],
     "phrases":[{"text":"Hello Azure","offsetMilliseconds":100,"durationMilliseconds":500}]}
    """#

    func fixture(bytes: Data? = nil) throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let data = try bytes ?? XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        try data.write(to: audio)
        return audio
    }

    func transcribe(
        _ audio: URL, model: String, key: String = "desktop-test", endpoint: String = ""
    ) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: key, duration: 999,
            language: "en_GB", azureEndpoint: endpoint, session: StubURLProtocol.makeSession()
        )
    }
}
