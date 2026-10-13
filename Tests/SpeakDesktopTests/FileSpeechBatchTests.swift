import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class FileSpeechBatchTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testCatalogueRoutesCredentialsNamesAndBillingStayInParity() throws {
        for provider in FileSpeechProvider.allCases {
            let model = provider.modelID
            XCTAssertEqual(ModelCatalog.batchTranscription.filter { $0.id == model }.count, 1)
            XCTAssertTrue(DesktopTranscription.batchModels.contains { $0.id == model })
            XCTAssertEqual(DesktopTranscription.provider(for: model)?.website, provider.metadata.website)
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: model, purpose: .batchTranscription),
                .apiKey(identifier: provider.metadata.apiKeyIdentifier, providerName: provider.metadata.displayName)
            )
            XCTAssertEqual(
                ProviderBalanceDirectory.account(forCredentialIdentifier: provider.metadata.apiKeyIdentifier)?.id,
                provider.rawValue
            )
            XCTAssertNotEqual(ModelCatalog.transcriptionDisplayName(for: model, isBatch: true), model)
        }
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id.hasPrefix("stepfun/") })
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id.hasPrefix("smallest/") })
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: FileSpeechProvider.smallest.modelID),
                       Decimal(string: "0.004"))
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: FileSpeechProvider.stepfun.modelID))
        XCTAssertNil(LiveTranscriptionRouting.route(for: FileSpeechProvider.reson8.modelID))
    }

    func testPulseProRawBytesLanguageWordsAndPrice() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.smallest.ai")
            XCTAssertEqual(request.url?.path, "/waves/v1/stt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(StubURLProtocol.body(of: request), Data([0, 1, 2, 3]))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertTrue(items?.contains(URLQueryItem(name: "model", value: "pulse-pro")) == true)
            XCTAssertTrue(items?.contains(URLQueryItem(name: "language", value: "en")) == true)
            return .ok(Data("""
                {"status":"success","transcription":"Hello","metadata":{"duration":60},
                "words":[{"word":"Hello","start":0.5,"end":1.5,"confidence":0.9}]}
                """.utf8), url: request.url!)
        }
        let result = try await transcribe(.smallest, audio: audio, language: "en_GB")
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.segments.first?.startTime, 0.5)
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertEqual(result.duration, 60)
        XCTAssertEqual(result.cost?.totalCost, Decimal(string: "0.004"))
        XCTAssertEqual(result.cost?.currency, "USD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testReson8UsesApiKeyAndNoInventedModelSelector() async throws {
        let audio = try fixture(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.reson8.dev")
            XCTAssertEqual(request.url?.path, "/v1/speech-to-text/prerecorded")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ApiKey synthetic")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(items.contains { $0.name == "model" })
            XCTAssertTrue(items.contains(URLQueryItem(name: "language", value: "nl")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "encoding", value: "m4a")))
            return .ok(Data("""
                {"text":"hallo","duration_ms":2500,
                "words":[{"text":"hallo","start_ms":500,"duration_ms":1000,"confidence":0.9}]}
                """.utf8), url: request.url!)
        }
        let result = try await transcribe(.reson8, audio: audio, language: "nl-NL")
        XCTAssertEqual(result.segments.first?.startTime, 0.5)
        XCTAssertEqual(result.segments.first?.endTime, 1.5)
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertNil(result.cost)
    }

    func testStepAudio3JSONBase64AndAuthoritativeSSE() async throws {
        let audio = try fixture(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.stepfun.com/v1/audio/asr/sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
                as? [String: Any])
            let audio = try XCTUnwrap(body["audio"] as? [String: Any])
            XCTAssertEqual(audio["data"] as? String, Data([0, 1, 2, 3]).base64EncodedString())
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            let config = try XCTUnwrap(input["transcription"] as? [String: Any])
            XCTAssertEqual(config["model"] as? String, "stepaudio-3-asr-max")
            XCTAssertEqual(config["language"] as? String, "zh")
            return .respond(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!, Data(Self.correctedSSE.utf8))
        }
        let result = try await transcribe(.stepfun, audio: audio, language: "zh-CN")
        XCTAssertEqual(result.text, "Corrected final.")
        XCTAssertEqual(result.segments, [])
        XCTAssertEqual(result.duration, 60)
        XCTAssertEqual(result.cost?.currency, "CNY")
        XCTAssertEqual(result.cost?.totalCost, Decimal(string: "2.8")! / 60)
    }

    func testUnsupportedLanguageAndWrongModelFailBeforeNetwork() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for (provider, language) in [(FileSpeechProvider.smallest, "fr_FR"), (.reson8, "ja-JP")] {
            do {
                _ = try await transcribe(provider, audio: audio, language: language)
                XCTFail("Expected unsupported language")
            } catch { XCTAssertTrue(error is FileSpeechError) }
        }
        do {
            _ = try await FileSpeechBatchClient(provider: .stepfun).transcribeFile(
                at: audio, apiKey: "synthetic", model: "stepfun/stepaudio-2.5-asr-stream", language: nil
            )
            XCTFail("Expected unsupported model")
        } catch { XCTAssertEqual(error as? FileSpeechError, .unsupportedModel("stepfun/stepaudio-2.5-asr-stream")) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testAutomaticLanguageDefaultsAreProviderSpecific() throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for provider in FileSpeechProvider.allCases {
            let request = try FileSpeechBatchClient(provider: provider).makeRequest(
                audioURL: audio, apiKey: "synthetic", language: "Automatic"
            )
            if provider == .stepfun {
                let body = String(data: request.httpBody!, encoding: .utf8)!
                XCTAssertFalse(body.contains("language"))
            } else {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(items?.first { $0.name == "language" }?.value, provider == .smallest ? "en" : nil)
            }
        }
    }

    func testAuthenticationAndQuotaFailuresRemainErrors() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for provider in FileSpeechProvider.allCases {
            for status in [401, 402, 403, 429] {
                StubURLProtocol.handler = { _ in .status(status, Data("rejected".utf8)) }
                do {
                    _ = try await transcribe(provider, audio: audio)
                    XCTFail("Expected HTTP rejection")
                } catch {
                    XCTAssertEqual(error as? TranscriptionProviderError, .httpError(status, "rejected"))
                }
            }
        }
    }

    func testCancellationCancelsTransportAndPreservesSource() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let started = expectation(description: "Request starts")
        let stopped = expectation(description: "Request cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in started.fulfill(); return .hang }
        let task = Task { try await self.transcribe(.stepfun, audio: audio) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testOversizedResponseAndUploadAreRejected() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            .respond(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Length": "99999999"])!, Data())
        }
        do {
            _ = try await transcribe(.smallest, audio: audio)
            XCTFail("Expected bounded response rejection")
        } catch { XCTAssertEqual(error as? BoundedHTTPExchange.Failure, .responseTooLarge) }
        let handle = try FileHandle(forWritingTo: audio)
        try handle.truncate(atOffset: UInt64(FileSpeechBatchClient.maximumAudioBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try FileSpeechBatchClient(provider: .stepfun).makeRequest(
            audioURL: audio, apiKey: "synthetic", language: nil
        )) { XCTAssertEqual($0 as? FileSpeechError, .fileTooLarge) }
    }

}

extension FileSpeechBatchTests {
    func testBoundedRead_RejectsFileGrowthAndAcceptsExactLimit() throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let reader = try FileHandle(forReadingFrom: audio)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: audio)
        defer { try? writer.close() }
        let initialSize = try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber
        XCTAssertEqual(initialSize?.intValue, 4)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([4, 5, 6, 7, 8]))
        XCTAssertThrowsError(try FileSpeechBatchClient.readAudio(from: reader, limit: 8)) {
            XCTAssertEqual($0 as? FileSpeechError, .fileTooLarge)
        }
        XCTAssertEqual(try reader.offset(), 9, "Read only the allowed bytes plus one overflow probe")
        try writer.truncate(atOffset: 8)
        try reader.seek(toOffset: 0)
        XCTAssertEqual(try FileSpeechBatchClient.readAudio(from: reader, limit: 8), Data(0..<8))
    }

    func testStepAudio3Sentinel_DoesNotDiscardFinalOrReplaceRequiredCompletion() throws {
        let sentinel = "data: [DONE]\n\n"
        XCTAssertEqual(
            try StepAudio3Response.decode(Data((Self.correctedSSE + sentinel).utf8), captureDuration: 1).text,
            "Corrected final."
        )
        let empty = #"data: {"type":"transcript.text.done","text":""}"# + "\n\n" + sentinel
        XCTAssertEqual(try StepAudio3Response.decode(Data(empty.utf8), captureDuration: 1).text, "")
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(sentinel.utf8), captureDuration: 1)) {
            XCTAssertEqual($0 as? FileSpeechError, .missingCompletion("StepFun"))
        }
        let error = Self.correctedSSE + sentinel + #"data: {"type":"error","message":"quota"}"# + "\n\n"
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(error.utf8), captureDuration: 1)) {
            XCTAssertEqual($0 as? FileSpeechError, .service("quota"))
        }
    }

    func testStepAudio3MissingCompletionAndErrorNeverReturnDeltasAsSuccess() throws {
        let delta = #"data: {"type":"transcript.text.delta","delta":"draft","start_time":0,"end_time":1000}"# + "\n\n"
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(delta.utf8), captureDuration: 1)) {
            XCTAssertEqual($0 as? FileSpeechError, .missingCompletion("StepFun"))
        }
        let failed = delta + #"data: {"type":"error","message":"quota"}"# + "\n\n"
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(failed.utf8), captureDuration: 1)) {
            XCTAssertEqual($0 as? FileSpeechError, .service("quota"))
        }
        let malformed = #"data: {"type":"transcript.text.done"}"# + "\n\n"
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(malformed.utf8), captureDuration: 1))
    }

    func testStepAudio3MultilineCRLFCommentsAndMillisecondTiming() throws {
        let sse = ": heartbeat\r\n\r\ndata: {\"type\":\"transcript.text.delta\",\r\n"
            + "data: \"delta\":\"hello\",\"start_time\":500,\"end_time\":1500}\r\n\r\n"
            + "data: {\"type\":\"transcript.text.done\",\"text\":\"hello\"}\r\n\r\n"
        let result = try StepAudio3Response.decode(Data(sse.utf8), captureDuration: 0)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.segments.first?.startTime, 0.5)
        XCTAssertEqual(result.segments.first?.endTime, 1.5)
        XCTAssertEqual(result.duration, 1.5)
    }

    func testSilentSuccessfulResponsesRemainEmpty() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for (provider, body) in [
            (FileSpeechProvider.smallest, #"{"status":"success","transcription":""}"#),
            (.reson8, #"{"text":""}"#)
        ] {
            StubURLProtocol.handler = { _ in .ok(Data(body.utf8)) }
            let result = try await transcribe(provider, audio: audio)
            XCTAssertEqual(result.text, "")
        }
        let empty = #"data: {"type":"transcript.text.done","text":""}"# + "\n\n"
        XCTAssertEqual(try StepAudio3Response.decode(Data(empty.utf8), captureDuration: 1).text, "")
    }

    func testInvalidDurationsFailInsteadOfTrappingCostConversion() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for duration in ["-1", "1e100"] {
            StubURLProtocol.handler = { _ in .ok(Data(
                "{\"status\":\"success\",\"transcription\":\"hello\",\"metadata\":{\"duration\":\(duration)}}".utf8
            )) }
            do {
                _ = try await transcribe(.smallest, audio: audio)
                XCTFail("Expected invalid duration")
            } catch { XCTAssertEqual(error as? TranscriptionProviderError, .invalidResponse) }
        }
        let done = #"data: {"type":"transcript.text.done","text":"hello"}"# + "\n\n"
        XCTAssertThrowsError(try StepAudio3Response.decode(Data(done.utf8), captureDuration: .infinity))
        for provider in FileSpeechProvider.allCases {
            do {
                _ = try await FileSpeechBatchClient(provider: provider).transcribeFile(
                    at: audio, apiKey: " \n", model: provider.modelID, language: nil
                )
                XCTFail("Expected missing credential")
            } catch { XCTAssertEqual(error as? TranscriptionProviderError, .apiKeyMissing) }
        }
    }

}

private extension FileSpeechBatchTests {
    func fixture(extension suffix: String = "wav") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    func transcribe(
        _ provider: FileSpeechProvider, audio: URL, language: String? = nil
    ) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: provider.modelID, apiKey: " synthetic \n", duration: 60,
            language: language, session: StubURLProtocol.makeSession()
        )
    }

    static let correctedSSE = """
        data: {"type":"transcript.text.delta","delta":"Wrong draft","start_time":0,"end_time":1000}

        data: {"type":"transcript.text.done","text":"Corrected final."}


        """
}
