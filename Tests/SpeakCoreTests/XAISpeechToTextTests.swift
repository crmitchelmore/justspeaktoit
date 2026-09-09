import Foundation
import XCTest

@testable import SpeakCore

/// Covers xAI's dedicated speech-to-text service: the batch upload shape, the
/// realtime protocol's `is_final` / `speech_final` semantics and its
/// finalisation, and how each failure reaches the user.
final class XAISpeechToTextTests: XCTestCase {

    // MARK: - Catalogue and routing

    func testCatalogue_exposesOneBatchAndOneStreamingEntryOnBothPlatforms() throws {
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            $0.id == XAISpeechToText.liveCatalogID
        })
        let batch = try XCTUnwrap(ModelCatalog.batchTranscription.first {
            $0.id == XAISpeechToText.batchCatalogID
        })
        XCTAssertTrue(live.displayName.contains("Streaming"))
        XCTAssertFalse(batch.displayName.contains("Streaming"))

        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: XAISpeechToText.liveCatalogID))
        XCTAssertEqual(route.provider, .xai)
        XCTAssertEqual(route.apiKeyIdentifier, "xai.apiKey")
        XCTAssertEqual(route.sampleRate, 24_000)
        XCTAssertTrue(route.isSupportedOnIOS)
    }

    /// The dedicated stream and the Grok Voice session share the `xai/` prefix
    /// but speak different protocols, so the identifier has to pick the client.
    func testFactory_splitsTheDedicatedStreamFromTheGrokVoiceSession() throws {
        let sttRoute = try XCTUnwrap(LiveTranscriptionRouting.route(for: XAISpeechToText.liveCatalogID))
        let voiceRoute = try XCTUnwrap(
            LiveTranscriptionRouting.route(for: XAIVoiceModels.thinkFast2CatalogID)
        )
        XCTAssertTrue(
            LiveTranscriptionClientFactory.makeClient(
                for: sttRoute, apiKey: "k", language: nil
            ) is XAISpeechToTextLiveClient
        )
        XCTAssertTrue(
            LiveTranscriptionClientFactory.makeClient(
                for: voiceRoute, apiKey: "k", language: nil
            ) is XAILiveClient
        )
    }

    func testCredentials_reuseTheExistingXAIKeyForBothOperations() {
        for purpose in [ModelCredentialPurpose.liveTranscription, .batchTranscription] {
            let identifier = purpose == .liveTranscription
                ? XAISpeechToText.liveCatalogID
                : XAISpeechToText.batchCatalogID
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: identifier, purpose: purpose),
                .apiKey(identifier: "xai.apiKey", providerName: "xAI"),
                "\(identifier) must not invent a second credential"
            )
        }
        // A saved key is never read as access; it only decides readiness in the
        // picker.
        XCTAssertEqual(
            ModelCredentialResolver.availability(
                for: XAISpeechToText.batchCatalogID,
                purpose: .batchTranscription,
                storedAPIKeyIdentifiers: []
            ),
            .missing(providerName: "xAI")
        )
        XCTAssertTrue(ModelCredentialResolver.allKnownAPIKeyIdentifiers.contains("xai.apiKey"))
    }

    func testLiveCapabilities_keepTheStreamOutOfTheInstantOnlyFallback() {
        let capabilities = ModelCatalog.liveCapabilities(for: XAISpeechToText.liveCatalogID)
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
        XCTAssertGreaterThan(capabilities.postStopFinalizeBudget, 0)
    }

    // MARK: - Language and keyterm bounds

    func testLanguageResolution_onlySendsCodesTheServiceDocuments() {
        XCTAssertEqual(XAISpeechToText.languageCode(for: "en_GB"), "en")
        XCTAssertEqual(XAISpeechToText.languageCode(for: "pt-BR"), "pt")
        for unsupported in [nil, "", " ", "Automatic", "auto", "cy_GB", "zz"] as [String?] {
            XCTAssertNil(
                XAISpeechToText.languageCode(for: unsupported),
                "\(unsupported ?? "nil") is not a documented code and must be omitted"
            )
        }
    }

    func testKeytermBounds_dropBlanksAndOverlongTermsAndCapTheList() {
        let terms = ["", "  ", String(repeating: "x", count: 51), " Speak "]
            + (0..<150).map { "term\($0)" }
        let bounded = XAISpeechToText.boundedKeyterms(terms)
        XCTAssertEqual(bounded.first, "Speak")
        XCTAssertEqual(bounded.count, XAISpeechToText.maximumKeyterms)
        XCTAssertTrue(bounded.allSatisfy { !$0.isEmpty && $0.count <= 50 })
    }

    // MARK: - Batch upload

    func testUpload_postsOneFilePartAndPairsFormatWithLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let upload = try XAIBatchTranscriptionClient.makeUpload(
            url: url, apiKey: "fixture", language: "en_GB", keywords: ["Speak"]
        )
        defer { try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent()) }

        XCTAssertEqual(upload.request.url, XAISpeechToText.restEndpoint)
        XCTAssertEqual(upload.request.httpMethod, "POST")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        // The recording is streamed from disk, never held in the request.
        XCTAssertNil(upload.request.httpBody)

        let body = try XCTUnwrap(String(bytes: Data(contentsOf: upload.file), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"format\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterm\"\r\n\r\nSpeak\r\n"))
        XCTAssertTrue(body.contains("filename=\"recording.m4a\"\r\nContent-Type: audio/mp4"))
        // There is no model field: the endpoint serves one service.
        XCTAssertFalse(body.contains("name=\"model\""))
    }

    /// Inverse text normalisation is rejected without a language, so neither
    /// field may travel alone.
    func testUpload_omitsInverseTextNormalisationWhenNoLanguageResolves() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let upload = try XAIBatchTranscriptionClient.makeUpload(
            url: url, apiKey: "fixture", language: "Automatic", keywords: []
        )
        defer { try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent()) }
        let body = try XCTUnwrap(String(bytes: Data(contentsOf: upload.file), encoding: .utf8))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertFalse(body.contains("name=\"format\""))
    }

    func testUpload_rejectsAContainerTheServiceCannotRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).caf")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try XAIBatchTranscriptionClient.makeUpload(
                url: url, apiKey: "fixture", language: nil, keywords: []
            )
        ) { error in
            XCTAssertEqual(error as? XAISpeechToTextError, .unsupportedAudioFormat("caf"))
        }
    }

    func testDecode_keepsWordTimingsAndPricesTheReportedDuration() throws {
        let payload = Data("""
        {"text":"Hello there.","language":"en","duration":2.5,
         "words":[{"text":"Hello","start":0.1,"end":0.4},
                  {"text":"there.","start":0.5,"end":0.9}]}
        """.utf8)
        let result = try XAIBatchTranscriptionClient.decode(payload)

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.modelIdentifier, XAISpeechToText.batchCatalogID)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.startTime, 0.1)
        XCTAssertEqual(result.duration, 2.5)
        let cost = try XCTUnwrap(result.cost)
        XCTAssertEqual(cost.currency, "USD")
        XCTAssertEqual(
            cost.totalCost,
            Decimal(2.5 / 3600) * XAISpeechToText.restCostPerHourOfAudio
        )
    }

    func testDecode_readsAMultichannelResponseAndReportsSilenceAsEmpty() throws {
        let multichannel = Data("""
        {"duration":1,"channels":[{"index":0,"text":"Left","words":[]},
                                  {"index":1,"text":"Right","words":[]}]}
        """.utf8)
        XCTAssertEqual(try XAIBatchTranscriptionClient.decode(multichannel).text, "Left\nRight")

        // An empty recording must be reported, not inserted as nothing.
        XCTAssertThrowsError(
            try XAIBatchTranscriptionClient.decode(Data(#"{"text":"","duration":0}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? XAISpeechToTextError, .emptyTranscript)
        }
        XCTAssertThrowsError(
            try XAIBatchTranscriptionClient.decode(Data("not json".utf8))
        ) { error in
            XCTAssertEqual(error as? XAISpeechToTextError, .invalidResponse)
        }
    }

    func testBatchClient_reportsAMissingKeyBeforeItTouchesTheNetwork() async {
        let client = XAIBatchTranscriptionClient()
        do {
            _ = try await client.transcribeFile(
                at: URL(fileURLWithPath: "/dev/null"), apiKey: "  ", language: nil
            )
            XCTFail("expected a missing-credential failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                TranscriptionProviderError.apiKeyMissing.localizedDescription
            )
        }
    }

    func testBatchClient_cancellationRemovesTheSnapshotAndKeepsTheRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = XAIUploadPathRecorder()
        var client = XAIBatchTranscriptionClient()
        client.uploadRecording = { _, file in
            await recorder.record(file)
            throw URLError(.cancelled)
        }
        do {
            _ = try await client.transcribeFile(at: url, apiKey: "fixture", language: nil)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            let recorded = await recorder.file
            let snapshot = try XCTUnwrap(recorded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testBatchClient_classifiesAuthQuotaAndRateLimitFromTheStatusCode() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected: [Int: XAISpeechToTextError] = [
            400: .badRequest(message: "bad"),
            401: .unauthorized(statusCode: 401),
            403: .unauthorized(statusCode: 403),
            402: .quotaExceeded(message: "bad"),
            413: .fileTooLarge,
            429: .rateLimited(message: "bad"),
            503: .httpError(statusCode: 503, message: "bad")
        ]
        for (statusCode, expectation) in expected {
            var client = XAIBatchTranscriptionClient()
            client.uploadRecording = { request, _ in
                (
                    Data(#"{"error":"bad"}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: statusCode,
                        httpVersion: nil, headerFields: nil
                    )!
                )
            }
            do {
                _ = try await client.transcribeFile(at: url, apiKey: "fixture", language: nil)
                XCTFail("expected HTTP \(statusCode) to fail")
            } catch {
                XCTAssertEqual(error as? XAISpeechToTextError, expectation)
            }
        }
    }

    /// xAI answers `error` as a string on some routes and as an object on
    /// others; neither shape may collapse the message.
    func testErrorMessages_readBothDocumentedErrorBodyShapes() {
        XCTAssertEqual(
            XAISpeechToTextError.message(from: Data(#"{"error":"flat"}"#.utf8)),
            "flat"
        )
        XCTAssertEqual(
            XAISpeechToTextError.message(from: Data(#"{"error":{"message":"nested"}}"#.utf8)),
            "nested"
        )
        XCTAssertEqual(
            XAISpeechToTextError.message(from: Data("<html>proxy</html>".utf8)),
            "Unknown xAI speech-to-text error"
        )
    }
}

private actor XAIUploadPathRecorder {
    var file: URL?
    func record(_ file: URL) { self.file = file }
}
